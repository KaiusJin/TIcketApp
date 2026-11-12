import Foundation

let calendar = WalletDate.calendar
func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}
assert(WalletDate.day(date(2026, 11, 11)) == "Nov 11, 2026")
assert(WalletDate.month(date(2026, 11, 11)) == "Nov 2026")
assert(WalletDate.day(date(2024, 2, 29)) == "Feb 29, 2024")
assert(calendar.shortMonthSymbols[10] == "Nov")
assert(WalletDate.interval(from: date(2026, 11, 12), through: date(2026, 11, 11)) == nil)
let oneDay = WalletDate.interval(from: date(2026, 11, 11, 18), through: date(2026, 11, 11, 9))!
assert(oneDay.start == date(2026, 11, 11) && oneDay.end == date(2026, 11, 12))
let range = WalletDate.interval(from: date(2024, 2, 28), through: date(2024, 2, 29))!
assert(range.end == date(2024, 3, 1))
var receipt = SavedReceipt(merchant: "Boundary", date: date(2024, 2, 29, 23), category: .other,
                           amounts: [ReceiptAmount(label: "TOTAL", value: 10)])
var outside = receipt
outside.date = range.end
assert(BudgetProgress.spending([receipt, outside], currency: "CAD", interval: range) == 10)
var plan = BudgetPlan()
plan.cycle = .quarterly
let quarter = plan.interval(containing: date(2026, 11, 11), calendar: calendar)
assert(quarter.start == date(2026, 10, 1) && quarter.end == date(2027, 1, 1))
plan.cycle = .yearly
assert(plan.interval(containing: date(2026, 11, 11), calendar: calendar).end == date(2027, 1, 1))
print("PASS: fixed English date formats, month labels, inclusive custom ranges, invalid ranges, leap day, spending boundaries and calendar periods")
