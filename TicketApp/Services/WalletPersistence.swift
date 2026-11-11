import Foundation
import SwiftData

@Model
final class ReceiptRecord {
    @Attribute(.unique) var id: UUID
    var merchant: String
    var date: Date?
    var category: String?
    var currency: String
    var items: [ReceiptItem]
    var amounts: [ReceiptAmount]
    var imageFilename: String?
    var originalJSON: String?
    var originalText: String?
    var reviewNotes: [String]
    var isFavorite: Bool
    var createdAt: Date
    var status: String
    var processingError: String?

    init(_ receipt: SavedReceipt) {
        id = receipt.id
        merchant = receipt.merchant
        date = receipt.date
        category = receipt.category?.rawValue
        currency = receipt.currency
        items = receipt.items
        amounts = receipt.amounts
        imageFilename = receipt.imageFilename
        originalJSON = receipt.originalJSON
        originalText = receipt.originalText
        reviewNotes = receipt.reviewNotes
        isFavorite = receipt.isFavorite
        createdAt = receipt.createdAt
        status = receipt.status.rawValue
        processingError = receipt.processingError
    }

    func update(from receipt: SavedReceipt) {
        merchant = receipt.merchant
        date = receipt.date
        category = receipt.category?.rawValue
        currency = receipt.currency
        items = receipt.items
        amounts = receipt.amounts
        imageFilename = receipt.imageFilename
        originalJSON = receipt.originalJSON
        originalText = receipt.originalText
        reviewNotes = receipt.reviewNotes
        isFavorite = receipt.isFavorite
        createdAt = receipt.createdAt
        status = receipt.status.rawValue
        processingError = receipt.processingError
    }

    var receipt: SavedReceipt {
        var value = SavedReceipt(merchant: merchant)
        value.id = id
        value.date = date
        value.category = category.flatMap(ReceiptCategory.init(rawValue:))
        value.currency = currency
        value.items = items
        value.amounts = amounts
        value.imageFilename = imageFilename
        value.originalJSON = originalJSON
        value.originalText = originalText
        value.reviewNotes = reviewNotes
        value.isFavorite = isFavorite
        value.createdAt = createdAt
        value.status = ReceiptStatus(rawValue: status) ?? .needsReview
        value.processingError = processingError
        return value
    }
}

@Model
final class WalletPreferencesRecord {
    @Attribute(.unique) var id: String
    // Preserve decimal precision without converting money to floating point.
    var budgets: [String: String]
    var importedLegacyArchive: Bool

    init() {
        id = "wallet"
        budgets = [:]
        importedLegacyArchive = false
    }
}
