import Foundation
import Observation

@MainActor @Observable
final class WalletStore {
    private(set) var receipts: [SavedReceipt] = []
    private(set) var budgets: [String: Decimal] = [:]
    private(set) var budgetHistory: [String: [BudgetRevision]] = [:]
    var error: String?
    private let repository: LocalWalletRepository

    init(repository: LocalWalletRepository) {
        self.repository = repository
        do {
            let archive = try repository.load()
            receipts = archive.receipts
            budgets = archive.budgets
            budgetHistory = try repository.loadBudgetHistory()
            for (currency, amount) in budgets where budgetHistory[currency] == nil {
                var plan = BudgetPlan()
                plan.total = BudgetLimit(enabled: true, amount: amount)
                budgetHistory[currency] = [BudgetRevision(effective: plan.interval(containing: .now).start, plan: plan)]
            }
            try repository.saveBudgetHistory(budgetHistory)
        } catch { self.error = error.localizedDescription }
    }

    var currencies: [String] {
        Array(Set(receipts.filter { $0.status == .completed }.map(\.currency)).union(budgetHistory.keys).union(["CAD"])).sorted()
    }

    func receipt(id: UUID) -> SavedReceipt? { receipts.first { $0.id == id } }

    func monthReceipts(_ month: Date, currency: String) -> [SavedReceipt] {
        receipts.filter {
            $0.status == .completed && $0.currency == currency
                && $0.date.map { Calendar.current.isDate($0, equalTo: month, toGranularity: .month) } == true
        }
    }

    func spending(in month: Date, currency: String) -> Decimal {
        monthReceipts(month, currency: currency).compactMap(\.total).reduce(0, +)
    }

    func budget(for currency: String) -> Decimal? { budgets[currency] }

    func setBudget(_ value: Decimal?, currency: String) throws {
        try repository.setBudget(value, currency: currency)
        budgets[currency] = value
    }

    func budgetPlan(for currency: String, at date: Date = .now) -> BudgetPlan? {
        budgetHistory[currency]?.last(where: { $0.effective <= date })?.plan
    }

    func saveBudgetPlan(_ plan: BudgetPlan, currency: String) throws {
        guard plan.isValid else { throw BudgetValidationError.invalidLimit }
        var history = budgetHistory
        let now = Date()
        let effective = history[currency] == nil ? plan.interval(containing: now).start : now
        history[currency, default: []].append(BudgetRevision(effective: effective, plan: plan))
        try repository.saveBudgetHistory(history)
        budgetHistory = history
        refreshBudgetNotifications()
    }

    func refreshBudgetNotifications() {
        BudgetNotifications.shared.refresh(receipts: receipts, history: budgetHistory)
    }

    func createDraft(imageData: Data? = nil) throws -> SavedReceipt {
        var draft = SavedReceipt(merchant: "", amounts: [ReceiptAmount(label: "TOTAL", value: nil)])
        draft.status = imageData == nil ? .needsReview : .processing
        let saved = try repository.save(draft, imageData: imageData)
        publish(saved)
        return saved
    }

    func beginProcessing(id: UUID) throws -> SavedReceipt {
        guard var draft = receipt(id: id), draft.status != .completed else {
            throw ReceiptError.receiptNotFound
        }
        draft.status = .processing
        draft.processingError = nil
        return try persist(draft)
    }

    func finishProcessing(id: UUID, result: ReceiptParseResult, originalText: String) throws {
        guard var draft = receipt(id: id), draft.status == .processing else { return }
        let extracted = try SavedReceipt.fromExtraction(
            result.validation.formattedJSON ?? result.output.text, notes: result.issues,
            originalText: originalText)
        draft.merchant = extracted.merchant
        draft.date = extracted.date
        draft.items = extracted.items
        draft.amounts = extracted.amounts
        draft.originalJSON = extracted.originalJSON
        draft.originalText = extracted.originalText
        draft.reviewNotes = extracted.reviewNotes
        draft.status = .needsReview
        draft.processingError = nil
        try persist(draft)
    }

    func changeProcessingState(id: UUID, status: ReceiptStatus, message: String?) throws {
        guard var draft = receipt(id: id), draft.status != .completed else { return }
        draft.status = status
        draft.processingError = message
        try persist(draft)
    }

    func save(_ receipt: SavedReceipt) throws {
        try receipt.validateForSaving()
        guard let current = self.receipt(id: receipt.id) else { throw ReceiptError.receiptNotFound }
        guard current.status != .processing else { throw ReceiptError.receiptStillProcessing }
        var completed = receipt
        completed.status = .completed
        completed.processingError = nil
        completed.imageFilename = current.imageFilename
        completed.isFavorite = current.isFavorite
        try persist(completed)
    }

    func prepareForReview(id: UUID) throws -> SavedReceipt {
        guard var draft = receipt(id: id) else { throw ReceiptError.receiptNotFound }
        guard draft.status != .processing else { throw ReceiptError.receiptStillProcessing }
        if draft.status == .completed { return draft }
        draft.status = .needsReview
        return try persist(draft)
    }

    func saveDraftEdits(_ edited: SavedReceipt) throws {
        guard let current = receipt(id: edited.id), current.status == .needsReview else { return }
        var draft = edited
        draft.status = .needsReview
        draft.imageFilename = current.imageFilename
        draft.isFavorite = current.isFavorite
        try persist(draft)
    }

    func delete(_ receipt: SavedReceipt) throws {
        try repository.delete(receipt)
        receipts.removeAll { $0.id == receipt.id }
        refreshBudgetNotifications()
    }

    func toggleFavorite(_ receipt: SavedReceipt) {
        guard var updated = self.receipt(id: receipt.id) else { return }
        updated.isFavorite.toggle()
        do { try persist(updated) } catch { self.error = error.localizedDescription }
    }

    func imageURL(for receipt: SavedReceipt) -> URL? { repository.imageURL(for: receipt) }

    @discardableResult
    private func persist(_ receipt: SavedReceipt) throws -> SavedReceipt {
        let saved = try repository.save(receipt)
        publish(saved)
        return saved
    }

    private func publish(_ receipt: SavedReceipt) {
        if let index = receipts.firstIndex(where: { $0.id == receipt.id }) {
            receipts[index] = receipt
        } else {
            receipts.append(receipt)
        }
        refreshBudgetNotifications()
    }
}
