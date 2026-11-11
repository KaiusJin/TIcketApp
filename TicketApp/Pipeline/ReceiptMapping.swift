import Foundation

extension SavedReceipt {
    nonisolated static func fromExtraction(_ json: String, notes: [String], originalText: String) throws
        -> SavedReceipt
    {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ReceiptError.guidedGenerationFailed
        }
        var receipt = SavedReceipt(merchant: object["merchant"] as? String ?? "")
        receipt.date = (object["date"] as? String).flatMap { ReceiptDate.parse($0) }
        receipt.items = (object["items"] as? [[String: Any]] ?? []).map {
            ReceiptItem(
                name: $0["name"] as? String ?? "", amount: ReceiptValidation.number($0["total_price"]),
                originalName: $0["name"] as? String)
        }
        receipt.amounts = (object["totals"] as? [String: Any] ?? [:]).map {
            ReceiptAmount(label: $0.key, value: ReceiptValidation.number($0.value))
        }.sorted { left, right in
            func rank(_ label: String) -> Int { label == "SUBTOTAL" ? 0 : label == "TOTAL" ? 2 : 1 }
            let l = rank(left.normalizedLabel)
            let r = rank(right.normalizedLabel)
            return l == r ? left.label < right.label : l < r
        }
        receipt.originalJSON = json
        receipt.originalText = originalText
        receipt.reviewNotes = notes
        return receipt
    }
}
