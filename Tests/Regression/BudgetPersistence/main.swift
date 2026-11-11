import Foundation

try MainActor.assumeIsolated {

let directory = FileManager.default.temporaryDirectory.appending(path: "BudgetPersistence-\(UUID())")
defer { try? FileManager.default.removeItem(at: directory) }
let repository = LocalWalletRepository(directory: directory)
_ = try repository.load()
try repository.setBudget(Decimal(string: "123.45"), currency: "CAD")
var plan = BudgetPlan()
plan.total = BudgetLimit(enabled: true, amount: Decimal(string: "250.75")!)
plan.categories["groceries"] = BudgetLimit(enabled: true, amount: 80, warningPercent: 70)
let older = BudgetRevision(effective: Date(timeIntervalSince1970: 100), plan: plan)
plan.total.amount = 300
let newer = BudgetRevision(effective: Date(timeIntervalSince1970: 200), plan: plan)
try repository.saveBudgetHistory(["CAD": [older, newer]])
let reopened = LocalWalletRepository(directory: directory)
let archive = try reopened.load()
assert(archive.budgets["CAD"] == Decimal(string: "123.45")!)
let history = try reopened.loadBudgetHistory()
assert(history["CAD"]?.count == 2)
assert(history["CAD"]?.first?.plan.total.amount == Decimal(string: "250.75")!)
assert(history["CAD"]?.last?.plan.categories["groceries"]?.warningPercent == 70)
assert(history["CAD"]?.last(where: { $0.effective <= Date(timeIntervalSince1970: 150) })?.plan.total.amount == Decimal(string: "250.75")!)
print("PASS: SwiftData reload, legacy budget preservation, category overrides and historical revisions")
}
