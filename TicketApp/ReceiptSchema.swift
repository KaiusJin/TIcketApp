import Foundation

/// Public receipt shape and strict local validation. NuExtract has a separate extraction template.
nonisolated indirect enum ReceiptField: Sendable {
    case text, decimal, totals, choice([String]), object([String: ReceiptField]), array(ReceiptField)

    var template: Any {
        switch self {
        case .text, .decimal, .choice: return NSNull()
        case .totals: return ["subtotal": NSNull(), "total": NSNull()]
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
            return ["type": "object", "properties": [:] as [String: Any],
                    "patternProperties": [ReceiptSchema.totalKeyPattern: ReceiptField.decimal.jsonSchema],
                    "additionalProperties": false]
        case .text: return ["type": ["string", "null"]]
        case .decimal:
            return ["anyOf": [["type": "string", "pattern": #"^-?[0-9]+(\.[0-9]+)?$"#], ["type": "null"]]]
        case .choice(let values):
            return ["anyOf": [["type": "string", "enum": values], ["type": "null"]]]
        }
    }

    private func orderedKeys(_ fields: [String: ReceiptField]) -> [String] {
        let order = ["receipt_type", "merchant",
                     "items", "name", "total_price",
                     "totals", "subtotal", "total"]
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
        case .totals: return #"{"subtotal":null,"total":null}"#
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
                if key.range(of: ReceiptSchema.totalKeyPattern, options: .regularExpression) == nil {
                    issues.append("\(path).\(key): unexpected field")
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
            case .choice(let choices):
                if !choices.contains(string) { issues.append("\(path): unsupported value") }
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
    // One allowlist drives constrained labels, output keys and public validation.
    // Only other entries are numbered by the adapter, never by the model.
    static let chargeLabels = [
        "HST", "GST", "PST", "QST", "VAT", "tax", "tip",
        "service_fee", "processing_fee", "handling_fee", "delivery_fee",
        "convenience_fee", "surcharge", "discount", "rounding", "other"
    ]
    static let totalKeyPattern: String = {
        let labels = chargeLabels.filter { $0 != "other" }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return "^(?:subtotal|total|" + labels + "|other(?:_(?:[2-9]|[1-9][0-9]+))?)$"
    }()
    static let root: ReceiptField = .object([
        "receipt_type": .choice(["restaurant", "grocery", "other"]),
        "merchant": .text,
        "items": .array(.object([
            "name": .text, "total_price": .decimal
        ])),
        "totals": .totals
    ])

    static func schema(for part: ReceiptExtractionPart) -> ReceiptField {
        guard case .object(let fields) = root else { preconditionFailure() }
        let keys = part == .amounts ? ["totals"] : ["receipt_type", "merchant", "items"]
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

    static func retryPrompt(vision: OCRScan, part: ReceiptExtractionPart, previousJSON: String, report: String) throws -> String {
        try NuExtractSchema.prompt(vision: vision, part: part, report: report)
    }
}
