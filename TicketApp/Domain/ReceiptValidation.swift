import Foundation

nonisolated struct ReceiptValidation: Sendable {
    let formattedJSON: String?
    let issues: [String]
    let checkedAmounts: Int
    let skippedAmounts: Int
    var passed: Bool { formattedJSON != nil && issues.isEmpty }

    static func number(_ value: Any?) -> Decimal? {
        guard let text = value as? String else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Missing or ambiguous geometric assignments remain unknown. Copying total
    /// into subtotal would conceal the absence of a matched source amount.
    static func normalizedTotals(_ original: [String: Any]) -> [String: Any] {
        original
    }

    private struct SummaryAmount {
        let keys: [String]
        let value: Decimal?
    }

    /// Read summary roles without rewriting the user's visible keys or amounts.
    /// Match the whole label, not a substring: SUBTOTAL is never a TOTAL match.
    /// A trailing separator is accepted because OCR labels retain punctuation.
    private static func summary(_ name: String, in totals: [String: Any]) -> SummaryAmount {
        func bareLabel(_ key: String) -> String {
            key.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":="))).uppercased()
        }
        let keys = totals.keys.filter { key in
            if bareLabel(key) == name { return true }
            // The serializer preserves duplicate labels with _2, _3, ... .
            // Treat these as ambiguous summary candidates, not extra charges.
            guard let suffix = key.range(of: #"_[0-9]+$"#, options: .regularExpression),
                  let number = Int(key[key.index(after: suffix.lowerBound)...]), number >= 2 else { return false }
            return bareLabel(String(key[..<suffix.lowerBound])) == name
        }.sorted()
        return .init(keys: keys, value: keys.count == 1 ? number(totals[keys[0]]) : nil)
    }

    static func money(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 8
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }

    static func totalsReport(_ original: [String: Any]) -> String? {
        let totals = normalizedTotals(original)
        guard !totals.isEmpty else {
            return "Validation results: No checkout amounts were paired. Review the OCR block assignments."
        }
        let subtotalEntry = summary("SUBTOTAL", in: totals)
        let totalEntry = summary("TOTAL", in: totals)
        for (name, entry) in [("TOTAL", totalEntry), ("SUBTOTAL", subtotalEntry)] {
            if entry.keys.count > 1 {
                return "Validation results: Multiple \(name) labels were found. Their amounts are preserved; select the intended summary entry."
            }
            if !entry.keys.isEmpty, entry.value == nil {
                return "Validation results: \(name) has no readable amount. Review its OCR block assignment."
            }
        }
        guard let total = totalEntry.value else {
            return "Validation results: No standalone TOTAL label was matched. Existing amounts are preserved; review the checkout labels."
        }
        let summaryKeys = Set(subtotalEntry.keys + totalEntry.keys)
        var extras = Decimal.zero
        for key in totals.keys.sorted() where !summaryKeys.contains(key) {
            guard let amount = number(totals[key]) else {
                return "Validation results: \(key) has an unknown amount; the totals equation cannot be checked. Re-read this entry."
            }
            extras += amount
        }
        // A subtotal is not printed on every receipt. Without one, skip the
        // totals equation; item checking can still use the known TOTAL amount.
        guard let subtotal = subtotalEntry.value else { return nil }
        guard subtotal + extras != total else { return nil }
        return """
        Validation results:
        - Subtotal: \(money(subtotal))
        - Sum of additional amounts: \(money(extras))
        - Total: \(money(total))
        - Difference (total minus subtotal and additional amounts): \(money(total - subtotal - extras))
        Re-read the amounts stage; do not alter amounts simply to balance them.
        """
    }

    static func itemsReport(_ items: [[String: Any]], totals original: [String: Any]) -> String? {
        let totals = normalizedTotals(original)
        let subtotal = summary("SUBTOTAL", in: totals).value
        let total = summary("TOTAL", in: totals).value
        guard subtotal != nil || total != nil else { return nil }
        guard !items.isEmpty else { return "Validation results: No purchased items were extracted. Re-read the item lines." }
        let prices = items.compactMap { number($0["total_price"]) }
        guard prices.count == items.count else { return "Validation results: Some item amounts are unknown. Re-read those lines; do not calculate prices." }
        let sum = prices.reduce(Decimal.zero, +)
        // Either target is acceptable, as receipts may list tax-inclusive item prices.
        if subtotal == sum || total == sum { return nil }
        var lines = ["Validation results:", "- Sum of extracted item prices: \(money(sum))"]
        if let subtotal {
            lines += ["- Receipt subtotal: \(money(subtotal))", "- Difference from subtotal: \(money(subtotal - sum))"]
        }
        if let total {
            lines += ["- Receipt total: \(money(total))", "- Difference from total: \(money(total - sum))"]
        }
        lines.append("Re-read omitted or duplicated item lines. Do not add an invented balancing item.")
        return lines.joined(separator: "\n")
    }

    static func check(_ text: String) -> Self {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), let newline = text.firstIndex(of: "\n") {
            let fence = text[..<newline].lowercased()
            if fence == "```json" || fence == "```" {
                text = String(text[text.index(after: newline)..<text.index(text.endIndex, offsetBy: -3)])
            }
        }
        guard var receipt = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return .init(formattedJSON: nil, issues: ["Invalid JSON object; raw output is preserved."], checkedAmounts: 0, skippedAmounts: 0)
        }
        var issues: [String] = []
        let duplicates = hasDuplicateKeys(text)
        if duplicates { issues.append("Duplicate JSON fields; review the raw output.") }
        ReceiptSchema.root.validate(receipt, path: "$", issues: &issues)
        guard issues.isEmpty else { return .init(formattedJSON: nil, issues: issues, checkedAmounts: 0, skippedAmounts: 0) }
        if receipt["date"] is NSNull { issues.append("Purchase date is unknown; check the receipt and enter YYYY-MM-DD.") }
        let totals = normalizedTotals(receipt["totals"] as! [String: Any])
        receipt["totals"] = totals
        let items = receipt["items"] as! [[String: Any]]
        if let report = totalsReport(totals) { issues.append(report) }
        if let report = itemsReport(items, totals: totals) { issues.append(report) }
        if items.isEmpty { issues.append("No items extracted; check the image.") }
        if items.contains(where: { number($0["total_price"]) == nil }) { issues.append("An item has an unknown amount.") }
        let subtotal = summary("SUBTOTAL", in: totals).value
        let total = summary("TOTAL", in: totals).value
        let totalsKnown = subtotal != nil && total != nil && totals.values.allSatisfy { number($0) != nil }
        let itemsKnown = (subtotal != nil || total != nil) && !items.isEmpty && items.allSatisfy { number($0["total_price"]) != nil }
        let checked = (totalsKnown ? 1 : 0) + (itemsKnown ? 1 : 0)
        let pretty = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        return .init(formattedJSON: pretty.map { String(decoding: $0, as: UTF8.self) }, issues: issues, checkedAmounts: checked, skippedAmounts: 2 - checked)
    }

    // Called only after JSONSerialization has verified syntax. Keep separate key sets per object;
    // dictionaries otherwise silently discard the repeated fields seen in degenerate model output.
    static func hasDuplicateKeys(_ text: String) -> Bool {
        var objects: [Set<String>?] = []
        var literal = ""
        var quoted = false
        var escaped = false
        for character in text {
            if quoted {
                literal.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                continue
            }
            switch character {
            case "\"": literal = "\""; quoted = true
            case "{": objects.append([])
            case "[": objects.append(nil)
            case "}", "]": _ = objects.popLast()
            case ":":
                if let data = literal.data(using: .utf8),
                   let key = try? JSONDecoder().decode(String.self, from: data),
                   let keys = objects.last, let keys {
                    if keys.contains(key) { return true }
                    objects[objects.count - 1]?.insert(key)
                }
            default: break
            }
        }
        return false
    }
}
