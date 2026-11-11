import Foundation

nonisolated enum ReceiptCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case work, shopping, learning, dining, groceries, other
    var id: Self { self }
}

nonisolated enum ReceiptStatus: String, Codable, Sendable {
    case processing, needsReview, completed, failed, cancelled
}

nonisolated struct ReceiptItem: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var amount: Decimal?
    var originalName: String?
}

nonisolated struct ReceiptAmount: Codable, Identifiable, Sendable {
    var id = UUID()
    var label: String
    var value: Decimal?

    var normalizedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":=")))
            .uppercased()
    }
}

nonisolated struct SavedReceipt: Codable, Identifiable, Sendable {
    var id = UUID()
    var merchant: String
    var date: Date?
    var category: ReceiptCategory?
    var currency = "CAD"
    var items: [ReceiptItem] = []
    var amounts: [ReceiptAmount] = []
    var imageFilename: String?
    var originalJSON: String?
    var originalText: String?
    var reviewNotes: [String] = []
    var isFavorite = false
    var createdAt = Date()
    var status: ReceiptStatus = .completed
    var processingError: String?

    // Prefer an unambiguous TOTAL; otherwise use the largest known totals entry.
    var total: Decimal? {
        let candidates = amounts.filter { $0.normalizedLabel == "TOTAL" }
        let hasDuplicateLabel = amounts.contains {
            $0.normalizedLabel.range(of: #"^TOTAL_[2-9][0-9]*$|^TOTAL_1[0-9]+$"#, options: .regularExpression)
                != nil
        }
        if candidates.count == 1, !hasDuplicateLabel, let value = candidates.first?.value {
            return value
        }
        return amounts.compactMap(\.value).max()
    }

    func validateForSaving() throws {
        guard category != nil, !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReceiptError.incompleteReceipt
        }
    }
}

// Records from the previous JSON archive were saved only after confirmation.
extension SavedReceipt {
    private enum CodingKeys: String, CodingKey {
        case id, merchant, date, category, currency, items, amounts, imageFilename
        case originalJSON, originalText, reviewNotes, isFavorite, createdAt
        case status, processingError
    }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(merchant: try values.decode(String.self, forKey: .merchant))
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decodeIfPresent(Date.self, forKey: .date)
        category = try values.decodeIfPresent(ReceiptCategory.self, forKey: .category)
        currency = try values.decode(String.self, forKey: .currency)
        items = try values.decode([ReceiptItem].self, forKey: .items)
        amounts = try values.decode([ReceiptAmount].self, forKey: .amounts)
        imageFilename = try values.decodeIfPresent(String.self, forKey: .imageFilename)
        originalJSON = try values.decodeIfPresent(String.self, forKey: .originalJSON)
        originalText = try values.decodeIfPresent(String.self, forKey: .originalText)
        reviewNotes = try values.decode([String].self, forKey: .reviewNotes)
        isFavorite = try values.decode(Bool.self, forKey: .isFavorite)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        status = try values.decodeIfPresent(ReceiptStatus.self, forKey: .status) ?? .completed
        processingError = try values.decodeIfPresent(String.self, forKey: .processingError)
    }
}
