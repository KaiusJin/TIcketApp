import Foundation

/// NuExtract outputs flat totals directly. Only repeated other properties are
/// numbered before dictionary decoding, preserving every amount and raw output.
nonisolated enum NuExtractSchema {
    static func template(for part: ReceiptExtractionPart) throws -> String {
        // Match the model card's json.dumps(..., indent=4) layout. Compact
        // templates made this checkpoint echo empty values on real OCR input.
        if part == .amounts {
            return """
            {
                "totals": {
                    "subtotal": "",
                    "total": ""
                }
            }
            """
        }
        return """
        {
            "receipt_type": "",
            "merchant": "",
            "items": [
                {
                    "name": "",
                    "total_price": ""
                }
            ]
        }
        """
    }

    static func prompt(vision: OCRScan, part: ReceiptExtractionPart, report: String? = nil) throws -> String {
        // NuExtract's source is exactly the reconstructed receipt text. Geometry,
        // instructions, prior outputs and computed validation amounts stay out
        // of ### Text. Extraction rules are a separate prompt section.
        // The pipeline still uses its report to decide whether to retry once.
        let instructions = part == .amounts ? """
        ### Instructions:
        Extract only monetary entries actually printed in the receipt text below. The template describes structure, not facts; do not fill every possible category.
        Output one flat totals object. Put actual receipt-level taxes, fees, tips, discounts and rounding adjustments directly beside subtotal and total as scalar amounts. Never output arrays, label/amount objects or a taxes_fees_and_discounts field. If no additional charges are printed, output only subtotal and total. The minimal template does not prohibit the optional keys listed below.
        Never create an entry for an absent charge, even with an empty or null amount. Do not assume GST, PST, HST or any tax based on the merchant or location.
        Tax registration numbers, tax rates, product tax markers, suggested tips, tendered amounts and change are not charged amounts. Do not extract them as fees or taxes.
        Allowed optional keys in output order: \(ReceiptSchema.chargeLabels.joined(separator: ", ")). Keep HST, GST, PST, QST and VAT distinct. Use the matching fee/tip/discount category only when supported by a printed entry; otherwise use other for an actual additional charge.
        Write subtotal and total first, then only present optional keys in the listed order. Each fixed key may occur at most once. Only the literal key other may occur multiple times at the end, each with its own scalar amount. Put an additional printed entry of an already-used category under other; never invent numbered keys or sum entries.
        Copy amounts from the receipt; do not calculate, balance or invent them. Preserve a printed zero amount; zero is not missing. An empty or null amount is allowed only when an entry is visibly present but its amount is unreadable, not when the entry is absent.
        Leave subtotal or total empty if not printed; do not infer them. Return only the template-shaped JSON, without commentary.
        """ + "\n" : ""
        return """
        <|input|>
        \(instructions)### Template:
        \(try template(for: part))
        ### Text:
        \(vision.text)

        <|output|>
        """
    }

    /// Keep absent and unreadable charges distinct; do not filter null amounts.
    static func normalize(_ output: ModelOutput, part: ReceiptExtractionPart) throws -> ModelOutput {
        guard !output.reachedLimit, !output.repetitionDetected else { throw ReceiptError.guidedGenerationFailed }
        let text = part == .amounts ? try numberOtherKeys(output.text) : output.text
        guard !ReceiptValidation.hasDuplicateKeys(text),
              let raw = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ReceiptError.guidedGenerationFailed
        }
        if part == .amounts {
            guard Set(raw.keys) == ["totals"], let totals = raw["totals"] as? [String: Any],
                  totals["subtotal"] != nil, totals["total"] != nil else { throw ReceiptError.invalidExtractionShape }
            InferenceDiagnostics.current?.event("amount_extraction charges=\(totals.count - 2)")
        }
        let object = try normalizeScalars(raw)
        let normalized = ModelOutput(text: try json(object), reachedLimit: false, rawText: output.text)
        _ = try ReceiptSchema.decodePart(normalized, part: part)
        return normalized
    }

    /// JSON dictionaries discard duplicate properties. Rename only totals.other
    /// in the token stream first; all other duplicates are rejected afterwards.
    /// Decode quoted keys so escaped spellings cannot bypass the allowlist.
    private static func numberOtherKeys(_ text: String) throws -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        var depth = 0
        var rootKey = ""
        var otherCount = 0
        let allowed = Set(["subtotal", "total"] + ReceiptSchema.chargeLabels)
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                let start = index
                index += 1
                var escaped = false
                var closed = false
                while index < characters.count {
                    let next = characters[index]
                    index += 1
                    if escaped { escaped = false }
                    else if next == "\\" { escaped = true }
                    else if next == "\"" { closed = true; break }
                }
                guard closed else { throw ReceiptError.guidedGenerationFailed }
                var token = String(characters[start..<index])
                var lookahead = index
                while lookahead < characters.count && characters[lookahead].isWhitespace { lookahead += 1 }
                if lookahead < characters.count && characters[lookahead] == ":" {
                    let key = try JSONDecoder().decode(String.self, from: Data(token.utf8))
                    if depth == 1 { rootKey = key }
                    if depth == 2 && rootKey == "totals" {
                        guard allowed.contains(key) else { throw ReceiptError.invalidExtractionShape }
                        if key == "other" {
                            otherCount += 1
                            if otherCount > 1 { token = "\"other_\(otherCount)\"" }
                        }
                    }
                }
                result += token
                continue
            }
            if character == "{" || character == "[" { depth += 1 }
            if character == "}" || character == "]" { depth -= 1 }
            result.append(character)
            index += 1
        }
        return result
    }

    private static func scalar(_ value: Any) throws -> Any {
        if value is NSNull { return value }
        guard let string = value as? String else { throw ReceiptError.guidedGenerationFailed }
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : string as Any
    }

    private static func normalizeScalars(_ value: Any) throws -> Any {
        if let object = value as? [String: Any] { return try object.mapValues(normalizeScalars) }
        if let array = value as? [Any] { return try array.map(normalizeScalars) }
        return try scalar(value)
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    /// GBNF permits optional fixed keys once, and repeated literal other only.
    /// Empty strings remain legal because this is NuExtract's missing-value convention.
    static func grammar(for part: ReceiptExtractionPart) throws -> String {
        func literal(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        func property(_ key: String, _ rule: String) throws -> String { try literal("\"\(key)\"") + " ws \":\" ws " + rule }
        func object(_ fields: [(String, String)]) throws -> String {
            "\"{\" ws " + (try fields.map { try property($0.0, $0.1) }).joined(separator: " \",\" ws ") + " \"}\" ws"
        }
        let root: String
        var extra: [String] = []
        if part == .amounts {
            root = try object([("totals", "totals")])
            // Ordered optional properties enforce uniqueness of every fixed key.
            // Only literal other may repeat; suffixes are assigned after generation.
            var totals = "\"{\" ws " + (try property("subtotal", "money"))
                + " \",\" ws " + (try property("total", "money"))
            for key in ReceiptSchema.chargeLabels where key != "other" {
                totals += " (\",\" ws " + (try property(key, "money")) + ")?"
            }
            totals += " (\",\" ws " + (try property("other", "money")) + ")* \"}\" ws"
            extra.append("totals ::= " + totals)
        } else {
            root = try object([("receipt_type", "receipt-kind"), ("merchant", "nullable-string"), ("items", "items")])
            extra.append("item ::= " + (try object([("name", "nullable-string"), ("total_price", "money")])))
            extra.append(#"items ::= "[" ws (item ("," ws item)*)? "]" ws"#)
            extra.append(#"receipt-kind ::= ("\"restaurant\"" | "\"grocery\"" | "\"other\"" | "\"\"" | "null") ws"#)
        }
        return (["root ::= " + root] + extra + [
            #"money ::= ("\"" ("-"? [0-9]+ ("." [0-9]+)?)? "\"" | "null") ws"#,
            #"nullable-string ::= string | "null" ws"#,
            #"string ::= "\"" ([^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4}))* "\"" ws"#,
            #"ws ::= [ \t\n\r]*"#
        ]).joined(separator: "\n") + "\n"
    }
}
