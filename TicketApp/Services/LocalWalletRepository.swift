import Foundation
import SwiftData

@MainActor
final class LocalWalletRepository {
    private let directory: URL
    private var container: ModelContainer?
    private var context: ModelContext?

    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? URL.applicationSupportDirectory.appending(
                path: "ReceiptWallet", directoryHint: .isDirectory)
    }

    func load() throws -> (receipts: [SavedReceipt], budgets: [String: Decimal]) {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        let schema = Schema([ReceiptRecord.self, WalletPreferencesRecord.self])
        let configuration = ModelConfiguration(
            "ReceiptWallet", schema: schema, url: directory.appending(path: "wallet.store"),
            cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false

        do {
            let preferences =
                try context.fetch(FetchDescriptor<WalletPreferencesRecord>()).first
                ?? WalletPreferencesRecord()
            if preferences.modelContext == nil { context.insert(preferences) }
            try migrateLegacyArchive(into: context, preferences: preferences)
            let records = try context.fetch(FetchDescriptor<ReceiptRecord>())
            var budgets: [String: Decimal] = [:]
            for (currency, text) in preferences.budgets {
                guard let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw WalletPersistenceError.invalidBudget
                }
                budgets[currency] = amount
            }
            try context.save()
            self.container = container
            self.context = context
            // The migration flag and imported records committed in the same transaction.
            let legacyFile = directory.appending(path: "wallet.json")
            if preferences.importedLegacyArchive, FileManager.default.fileExists(atPath: legacyFile.path) {
                try? FileManager.default.removeItem(at: legacyFile)
            }
            return (records.map(\.receipt), budgets)
        } catch {
            context.rollback()
            throw error
        }
    }

    func save(_ receipt: SavedReceipt, imageData: Data? = nil) throws -> SavedReceipt {
        let context = try writableContext()
        var saved = receipt
        var newImage: URL?
        let existing = try record(for: receipt.id, in: context)
        let oldImage = existing?.imageFilename
        if let imageData {
            let filename = "\(receipt.id.uuidString)-\(UUID().uuidString).image"
            let file = directory.appending(path: filename)
            try imageData.write(to: file, options: [.atomic, .completeFileProtection])
            saved.imageFilename = filename
            newImage = file
        }
        do {
            if let existing { existing.update(from: saved) } else { context.insert(ReceiptRecord(saved)) }
            try context.save()
        } catch {
            context.rollback()
            if let newImage { try? FileManager.default.removeItem(at: newImage) }
            throw error
        }
        if let oldImage, oldImage != saved.imageFilename {
            try? FileManager.default.removeItem(at: directory.appending(path: oldImage))
        }
        return saved
    }

    func setBudget(_ value: Decimal?, currency: String) throws {
        let context = try writableContext()
        guard let preferences = try context.fetch(FetchDescriptor<WalletPreferencesRecord>()).first else {
            throw WalletPersistenceError.unavailable
        }
        preferences.budgets[currency] = value.map { NSDecimalNumber(decimal: $0).stringValue }
        do { try context.save() } catch {
            context.rollback()
            throw error
        }
    }

    func loadBudgetHistory() throws -> [String: [BudgetRevision]] {
        let context = try writableContext()
        guard let data = try context.fetch(FetchDescriptor<WalletPreferencesRecord>()).first?.budgetHistoryData else { return [:] }
        return try JSONDecoder().decode([String: [BudgetRevision]].self, from: data)
    }

    func saveBudgetHistory(_ history: [String: [BudgetRevision]]) throws {
        let context = try writableContext()
        guard let preferences = try context.fetch(FetchDescriptor<WalletPreferencesRecord>()).first else {
            throw WalletPersistenceError.unavailable
        }
        preferences.budgetHistoryData = try JSONEncoder().encode(history)
        do { try context.save() } catch { context.rollback(); throw error }
    }

    func delete(_ receipt: SavedReceipt) throws {
        let context = try writableContext()
        guard let record = try record(for: receipt.id, in: context) else { return }
        let image = record.imageFilename.map { directory.appending(path: $0) }
        context.delete(record)
        do { try context.save() } catch {
            context.rollback()
            throw error
        }
        if let image { try? FileManager.default.removeItem(at: image) }
    }

    func imageURL(for receipt: SavedReceipt) -> URL? {
        receipt.imageFilename.map { directory.appending(path: $0) }
    }

    private func writableContext() throws -> ModelContext {
        guard let context else { throw WalletPersistenceError.unavailable }
        return context
    }

    private func record(for id: UUID, in context: ModelContext) throws -> ReceiptRecord? {
        var descriptor = FetchDescriptor<ReceiptRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func migrateLegacyArchive(
        into context: ModelContext, preferences: WalletPreferencesRecord
    ) throws {
        guard !preferences.importedLegacyArchive else { return }
        let file = directory.appending(path: "wallet.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let archive = try JSONDecoder().decode(LegacyArchive.self, from: Data(contentsOf: file))
            for receipt in archive.receipts {
                if try record(for: receipt.id, in: context) == nil { context.insert(ReceiptRecord(receipt)) }
            }
            for (currency, amount) in archive.budgets where preferences.budgets[currency] == nil {
                preferences.budgets[currency] = NSDecimalNumber(decimal: amount).stringValue
            }
        }
        preferences.importedLegacyArchive = true
    }

    private struct LegacyArchive: Decodable {
        var receipts: [SavedReceipt]
        var budgets: [String: Decimal]
    }
}

private enum WalletPersistenceError: LocalizedError {
    case unavailable, invalidBudget

    var errorDescription: String? {
        switch self {
        case .unavailable: "The saved wallet couldn't be opened. Restart the app and try again."
        case .invalidBudget: "A saved budget couldn't be read. Your existing data has been preserved."
        }
    }
}
