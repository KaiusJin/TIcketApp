import Foundation

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Toronto")!
func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}
var plan = BudgetPlan()
assert(plan.warningPercent == 80 && plan.cycle == .monthly)
let feb = plan.interval(containing: date(2024, 2, 15), calendar: calendar)
assert(feb.start == date(2024, 2, 1) && feb.end == date(2024, 3, 1))
plan.cycle = .quarterly
let quarter = plan.interval(containing: date(2026, 12, 31), calendar: calendar)
assert(quarter.start == date(2026, 10, 1) && quarter.end == date(2027, 1, 1))
plan.cycle = .yearly
assert(plan.interval(containing: date(2024, 2, 29), calendar: calendar).end == date(2025, 1, 1))
plan.cycle = .daily
let dst = plan.interval(containing: date(2026, 3, 8), calendar: calendar)
assert(dst.duration == 23 * 3600)
plan.cycle = .weekly
assert(calendar.dateComponents([.day], from: plan.interval(containing: date(2026, 3, 8), calendar: calendar).start,
                               to: plan.interval(containing: date(2026, 3, 8), calendar: calendar).end).day == 7)
let limit = BudgetLimit(enabled: true, amount: 100)
assert(BudgetProgress(spent: 80, limit: limit, globalWarning: 80).level == 1)
assert(BudgetProgress(spent: 100, limit: limit, globalWarning: 80).level == 1)
assert(BudgetProgress(spent: Decimal(string: "100.01")!, limit: limit, globalWarning: 80).level == 2)
assert(BudgetProgress(spent: 80, limit: BudgetLimit(enabled: true, amount: 100, warningPercent: 90), globalWarning: 80).level == 0)
var receipt = SavedReceipt(merchant: "Test", date: feb.start, category: .groceries,
                           amounts: [ReceiptAmount(label: "TOTAL", value: Decimal(string: "10.25"))])
var excluded = receipt
excluded.date = feb.end
var draft = receipt
draft.status = .needsReview
var foreign = receipt
foreign.currency = "USD"
let receipts = [receipt, excluded, draft, foreign]
assert(BudgetProgress.spending(receipts, currency: "CAD", interval: feb) == Decimal(string: "10.25")!)
assert(BudgetProgress.spending(receipts, currency: "CAD", interval: feb, category: .dining) == 0)
plan.total = limit
let revision = BudgetRevision(effective: feb.start, plan: plan)
let decoded = try JSONDecoder().decode(BudgetRevision.self, from: JSONEncoder().encode(revision))
assert(decoded.plan == plan)
plan.total.amount = 0
assert(!plan.isValid)
print("PASS: calendar boundaries, DST, thresholds, currency/category/draft filtering, precision and history coding")
