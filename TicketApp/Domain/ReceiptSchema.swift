import Foundation

/// Public receipt shape and strict local validation. NuExtract has a separate extraction template.
nonisolated indirect enum ReceiptField: Sendable {
    case text, date, decimal, totals, object([String: ReceiptField]), array(ReceiptField)

    var template: Any {
        switch self {
        case .text, .date, .decimal: return NSNull()
        case .totals: return [:] as [String: Any]
        case .object(let fields): return fields.mapValues(\.template)
        case .array(let item): return [item.template]
        }
    }

    /// The same field definitions drive prompting, token constraints and post-generation validation.
    var jsonSchema: [String: Any] {
        switch self {
        case .object(let fields):
            return ["type": "object", "properties": fields.mapValues(\.jsonSchema),
                    "required": fields.keys.sorted(), "additionalProperties": false]
        case .array(let item): return ["type": "array", "items": item.jsonSchema]
        case .totals:
            return ["type": "object",
                    "propertyNames": ["type": "string", "pattern": #"\S"#],
                    "additionalProperties": ReceiptField.decimal.jsonSchema]
        case .text: return ["type": ["string", "null"]]
        case .decimal:
            return ["anyOf": [["type": "string", "pattern": #"^-?[0-9]+(\.[0-9]+)?$"#], ["type": "null"]]]
        case .date:
            return ["anyOf": [["type": "string", "pattern": #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#], ["type": "null"]]]
        }
    }

    private func orderedKeys(_ fields: [String: ReceiptField]) -> [String] {
        let order = ["date", "merchant",
                     "items", "name", "total_price",
                     "totals", "SUBTOTAL", "TOTAL"]
        return fields.keys.sorted {
            let left = order.firstIndex(of: $0) ?? order.count
            let right = order.firstIndex(of: $1) ?? order.count
            return left == right ? $0 < $1 : left < right
        }
    }

    /// Retained JSON Schema serialization for local tooling and the backed-up Qwen path.
    func constraintJSON() throws -> String {
        switch self {
        case .object(let fields):
            let keys = orderedKeys(fields)
            let properties = try keys.map { key in
                String(decoding: try JSONEncoder().encode(key), as: UTF8.self) + ":" + (try fields[key]!.constraintJSON())
            }.joined(separator: ",")
            let required = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
            return "{\"type\":\"object\",\"properties\":{\(properties)},\"required\":\(required),\"additionalProperties\":false}"
        case .array(let item): return "{\"type\":\"array\",\"items\":\(try item.constraintJSON())}"
        default: return String(decoding: try JSONSerialization.data(withJSONObject: jsonSchema, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    func promptShape() throws -> String {
        switch self {
        case .object(let fields):
            let keys = orderedKeys(fields)
            return "{" + (try keys.map { key in
                let encoded = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
                return encoded + ":" + (try fields[key]!.promptShape())
            }).joined(separator: ",") + "}"
        case .totals: return "{}"
        case .array(let item): return "[" + (try item.promptShape()) + "]"
        default: return "null"
        }
    }

    func validate(_ value: Any, path: String, issues: inout [String]) {
        switch self {
        case .object(let fields):
            guard let object = value as? [String: Any] else { issues.append("\(path): expected object"); return }
            for key in fields.keys.sorted() {
                guard let child = object[key] else { issues.append("\(path).\(key): missing field"); continue }
                fields[key]!.validate(child, path: "\(path).\(key)", issues: &issues)
            }
            for key in object.keys.sorted() where fields[key] == nil { issues.append("\(path).\(key): unexpected field") }
        case .totals:
            guard let totals = value as? [String: Any] else { issues.append("\(path): expected object"); return }
            for (key, amount) in totals {
                if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append("\(path): empty monetary label")
                } else { ReceiptField.decimal.validate(amount, path: "\(path).\(key)", issues: &issues) }
            }
        case .array(let item):
            guard let array = value as? [Any] else { issues.append("\(path): expected array"); return }
            for (index, child) in array.enumerated() { item.validate(child, path: "\(path)[\(index)]", issues: &issues) }
        default:
            if value is NSNull { return }
            guard let string = value as? String else { issues.append("\(path): expected string or null"); return }
            switch self {
            case .decimal:
                if string.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) == nil || Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) == nil {
                    issues.append("\(path): invalid decimal string")
                }
            case .date:
                if !ReceiptDate.isValidDate(string) { issues.append("\(path): expected a valid YYYY-MM-DD date") }
            default: break
            }
        }
    }
}

nonisolated enum ReceiptExtractionPart: String, Sendable { case amounts, details }

nonisolated enum ReceiptSchema {
    static func constraintJSON() throws -> String {
        try root.constraintJSON()
    }
    static let root: ReceiptField = .object([
        "date": .date,
        "merchant": .text,
        "items": .array(.object([
            "name": .text, "total_price": .decimal
        ])),
        "totals": .totals
    ])

    static func schema(for part: ReceiptExtractionPart) -> ReceiptField {
        guard case .object(let fields) = root else { preconditionFailure() }
        let keys = part == .amounts ? ["totals"] : ["date", "merchant", "items"]
        return .object(fields.filter { keys.contains($0.key) })
    }

    static func extractionPrompt(vision: OCRScan, part: ReceiptExtractionPart) throws -> String {
        try NuExtractSchema.prompt(vision: vision, part: part)
    }

    static func decodePart(_ output: ModelOutput, part: ReceiptExtractionPart) throws -> [String: Any] {
        guard !output.reachedLimit, !output.repetitionDetected,
              !ReceiptValidation.hasDuplicateKeys(output.text),
              let object = try JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any] else {
            throw ReceiptError.guidedGenerationFailed
        }
        var issues: [String] = []
        schema(for: part).validate(object, path: "$", issues: &issues)
        guard issues.isEmpty else { throw ReceiptError.guidedGenerationFailed }
        return object
    }

    static func merge(amounts: ModelOutput, details: ModelOutput) throws -> ModelOutput {
        var object = try decodePart(amounts, part: .amounts)
        object["totals"] = ReceiptValidation.normalizedTotals(object["totals"] as! [String: Any])
        for (key, value) in try decodePart(details, part: .details) { object[key] = value }
        return ModelOutput(text: String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self), reachedLimit: false)
    }

    static func initialPrompt(vision: OCRScan) throws -> String {
        try extractionPrompt(vision: vision, part: .details)
    }

    static func amountRetryPrompt(text: String, report: String) throws -> String {
        try NuExtractSchema.amountPrompt(text: text, recheck: true)
    }
}
