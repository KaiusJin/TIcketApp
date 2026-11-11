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

    /// Copy the existing amount verbatim. Raw model outputs remain separate evidence.
    static func normalizedTotals(_ original: [String: Any]) -> [String: Any] {
        var totals = original
        if number(totals["subtotal"]) == nil, number(totals["total"]) != nil { totals["subtotal"] = totals["total"] }
        if number(totals["total"]) == nil, number(totals["subtotal"]) != nil { totals["total"] = totals["subtotal"] }
        return totals
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
        guard let subtotal = number(totals["subtotal"]), let total = number(totals["total"]) else {
            return "Validation results: Both subtotal and total are missing. Re-read the printed totals."
        }
        var extras = Decimal.zero
        for key in totals.keys.sorted() where key != "subtotal" && key != "total" {
            guard let amount = number(totals[key]) else {
                return "Validation results: \(key) has an unknown amount; the totals equation cannot be checked. Re-read this entry."
            }
            extras += amount
        }
        guard subtotal + extras != total else { return nil }
        return """
        Validation results:
        - Subtotal (after missing-total fallback): \(money(subtotal))
        - Sum of additional amounts: \(money(extras))
        - Total (after missing-total fallback): \(money(total))
        - Difference (total minus subtotal and additional amounts): \(money(total - subtotal - extras))
        Re-read the amounts stage; do not alter amounts simply to balance them.
        """
    }

    static func itemsReport(_ items: [[String: Any]], totals original: [String: Any]) -> String? {
        let totals = normalizedTotals(original)
        guard let subtotal = number(totals["subtotal"]), let total = number(totals["total"]) else { return nil }
        guard !items.isEmpty else { return "Validation results: No purchased items were extracted. Re-read the item lines." }
        let prices = items.compactMap { number($0["total_price"]) }
        guard prices.count == items.count else { return "Validation results: Some item amounts are unknown. Re-read those lines; do not calculate prices." }
        let sum = prices.reduce(Decimal.zero, +)
        // Either target is acceptable, as receipts may list tax-inclusive item prices.
        guard sum != subtotal && sum != total else { return nil }
        return """
        Validation results:
        - Receipt subtotal: \(money(subtotal))
        - Receipt total: \(money(total))
        - Sum of extracted item prices: \(money(sum))
        - Difference from subtotal: \(money(subtotal - sum))
        - Difference from total: \(money(total - sum))
        Re-read omitted or duplicated item lines. Do not add an invented balancing item.
        """
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
        let totals = normalizedTotals(receipt["totals"] as! [String: Any])
        receipt["totals"] = totals
        let items = receipt["items"] as! [[String: Any]]
        if let report = totalsReport(totals) { issues.append(report) }
        if let report = itemsReport(items, totals: totals) { issues.append(report) }
        if items.isEmpty { issues.append("No items extracted; check the image.") }
        if items.contains(where: { number($0["total_price"]) == nil }) { issues.append("An item has an unknown amount.") }
        let hasTargets = number(totals["subtotal"]) != nil && number(totals["total"]) != nil
        let totalsKnown = hasTargets && totals.values.allSatisfy { number($0) != nil }
        let itemsKnown = hasTargets && !items.isEmpty && items.allSatisfy { number($0["total_price"]) != nil }
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
