import Foundation

/// NuExtract outputs flat totals directly, preserving receipt labels as keys.
/// Duplicate keys are rejected before dictionary decoding can discard amounts.
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
            "date": "",
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
        // Amount extraction must receive Qwen's generated text explicitly.
        guard part == .details else { throw ReceiptError.invalidSettlementText }
        // Details retain full receipt coverage with geometry-only layout hints.
        var rules = "Extract only information printed in the text. Omit absent tax/fee fields. Keep the full product name and specifications, excluding price columns."
        rules += " Extract the purchase date into date as YYYY-MM-DD, preserving the printed year, month and day. Do not substitute today or a default date. Ignore expiry dates. If the purchase date is absent, incomplete or ambiguous, leave date empty."
        rules += " [price-column]...[/price-column] marks a geometrically aligned amount candidate, not part of a product name. It may be a unit price, line amount, discount, tax or receipt total; determine its role from context. Blank lines are soft groups of neighboring rows, not individual items. A product can span multiple rows or groups; preserve name continuations and specifications. Associate each amount only with its supported item; leave uncertain amounts empty. Do not copy markers into the output, remove specification numbers, duplicate items across groups, or calculate amounts."
        return """
        \(rules)
        <|input|>
        ### Template:
        \(try template(for: part))
        ### Text:
        \(vision.itemText)

        <|output|>
        """
    }

    static func amountPrompt(text: String, recheck: Bool = false) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReceiptError.invalidSettlementText }
        var rules = """
        Extract the printed monetary summary into one flat totals object. Always include subtotal and total; leave a missing or unreadable amount empty.
        Add every other printed monetary charge or adjustment using its actual label from the supplied text as the key. There is no category whitelist: do not translate labels, rename them to a standard category, or replace an unfamiliar label with other. Include only entries present in the text, not hypothetical fields.
        Values are the printed final monetary amounts as decimal strings, not tax rates, taxable bases or intermediate calculation values. Read complete tax lines to associate the charged amount with its label. Do not calculate or invent missing amounts.
        Pts, Point and Points are reward points, not money. Exclude points, points-back offers, product entries, counts, payments, change and card metadata.
        Write subtotal and total first, followed by the additional monetary entries. Use distinct keys; for separate entries with the same label, append _2, _3 and so on without summing them. Return only JSON, without explanations.
        """
        if recheck { rules += "\nRecheck the supplied checkout text for omitted entries and incorrect label-to-amount associations. Do not change amounts just to balance totals." }
        return """
        \(rules)
        <|input|>
        ### Template:
        \(try template(for: .amounts))
        ### Text:
        \(text)

        <|output|>
        """
    }

    /// Keep absent and unreadable charges distinct; do not filter null amounts.
    static func normalize(_ output: ModelOutput, part: ReceiptExtractionPart) throws -> ModelOutput {
        guard !output.reachedLimit, !output.repetitionDetected else { throw ReceiptError.guidedGenerationFailed }
        let text = output.text
        guard !ReceiptValidation.hasDuplicateKeys(text),
              let raw = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ReceiptError.guidedGenerationFailed
        }
        if part == .amounts {
            guard Set(raw.keys) == ["totals"], let totals = raw["totals"] as? [String: Any],
                  totals["subtotal"] != nil, totals["total"] != nil else { throw ReceiptError.invalidExtractionShape }
            InferenceDiagnostics.current?.event("amount_extraction charges=\(totals.count - 2)")
        }
        var object = try normalizeScalars(raw) as! [String: Any]
        if part == .amounts, let totals = object["totals"] as? [String: Any] {
            object["totals"] = totals.mapValues(normalizedMoney)
        } else if var items = object["items"] as? [[String: Any]] {
            for index in items.indices {
                if let amount = items[index]["total_price"] { items[index]["total_price"] = normalizedMoney(amount) }
            }
            object["items"] = items
        }
        let normalized = ModelOutput(text: try json(object), reachedLimit: false, rawText: output.text)
        _ = try ReceiptSchema.decodePart(normalized, part: part)
        return normalized
    }

    private static func scalar(_ value: Any) throws -> Any {
        if value is NSNull { return value }
        guard let string = value as? String else { throw ReceiptError.guidedGenerationFailed }
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : string as Any
    }

    /// Accept an unambiguous printed decimal comma without losing cents during
    /// constrained decoding. Grouping/ambiguous comma formats remain invalid.
    private static func normalizedMoney(_ value: Any) -> Any {
        guard let text = value as? String,
              text.range(of: #"^-?[0-9]+,[0-9]{2}$"#, options: .regularExpression) != nil else { return value }
        return text.replacingOccurrences(of: ",", with: ".")
    }

    private static func normalizeScalars(_ value: Any) throws -> Any {
        if let object = value as? [String: Any] { return try object.mapValues(normalizeScalars) }
        if let array = value as? [Any] { return try array.map(normalizeScalars) }
        return try scalar(value)
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    /// GBNF requires subtotal/total and allows additional receipt-named amounts.
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
            // Additional labels are open strings. Post-generation validation
            // rejects empty or duplicate keys instead of discarding their values.
            var totals = "\"{\" ws " + (try property("subtotal", "money"))
                + " \",\" ws " + (try property("total", "money"))
            totals += " (\",\" ws string \":\" ws money)* \"}\" ws"
            extra.append("totals ::= " + totals)
        } else {
            root = try object([("date", "receipt-date"), ("merchant", "nullable-string"), ("items", "items")])
            extra.append(#"receipt-date ::= ("\"" ([0-9]{4} "-" [0-9]{2} "-" [0-9]{2})? "\"" | "null") ws"#)
            extra.append("item ::= " + (try object([("name", "nullable-string"), ("total_price", "money")])))
            extra.append(#"items ::= "[" ws (item ("," ws item)*)? "]" ws"#)
        }
        return (["root ::= " + root] + extra + [
            #"money ::= ("\"" ("-"? [0-9]+ ("." [0-9]+ | "," [0-9]{2})?)? "\"" | "null") ws"#,
            #"nullable-string ::= string | "null" ws"#,
            #"string ::= "\"" ([^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4}))* "\"" ws"#,
            #"ws ::= [ \t\n\r]*"#
        ]).joined(separator: "\n") + "\n"
    }
}
