import Foundation

nonisolated enum WalletDate {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = Calendar.current.firstWeekday
        calendar.minimumDaysInFirstWeek = Calendar.current.minimumDaysInFirstWeek
        return calendar
    }

    static func day(_ date: Date) -> String { format(date, pattern: "MMM d, yyyy") }
    static func month(_ date: Date) -> String { format(date, pattern: "MMM yyyy") }

    private static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // The selected end date is inclusive; spending queries use an exclusive upper bound.
    static func interval(from start: Date, through end: Date) -> DateInterval? {
        let lower = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard lower <= last, let upper = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        return DateInterval(start: lower, end: upper)
    }
}
