import Foundation

nonisolated enum BudgetCycle: String, Codable, CaseIterable, Identifiable {
    case monthly, weekly, daily, yearly, quarterly
    var id: Self { self }
}

nonisolated struct BudgetLimit: Codable, Equatable {
    var enabled = false
    var amount: Decimal = 0
    var warningPercent: Int?
}

nonisolated struct BudgetPlan: Codable, Equatable {
    var total = BudgetLimit()
    var categories: [String: BudgetLimit] = [:]
    var warningPercent = 80
    var cycle: BudgetCycle = .monthly
    var notifications = false

    func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        switch cycle {
        case .monthly: return calendar.dateInterval(of: .month, for: date)!
        case .weekly: return calendar.dateInterval(of: .weekOfYear, for: date)!
        case .daily: return calendar.dateInterval(of: .day, for: date)!
        case .yearly: return calendar.dateInterval(of: .year, for: date)!
        case .quarterly:
            let components = calendar.dateComponents([.year, .month], from: date)
            let month = ((components.month! - 1) / 3) * 3 + 1
            let start = calendar.date(from: DateComponents(year: components.year, month: month, day: 1))!
            return DateInterval(start: start, end: calendar.date(byAdding: .month, value: 3, to: start)!)
        }
    }

    var isValid: Bool {
        (1...100).contains(warningPercent)
            && ([total] + Array(categories.values)).allSatisfy {
                (!$0.enabled || $0.amount > 0) && ($0.warningPercent.map { (1...100).contains($0) } ?? true)
            }
    }
}

nonisolated struct BudgetRevision: Codable, Identifiable {
    var id = UUID()
    var effective: Date
    var plan: BudgetPlan
}

nonisolated struct BudgetProgress {
    var spent: Decimal
    var limit: BudgetLimit
    var globalWarning: Int
    var remaining: Decimal { limit.amount - spent }
    var ratio: Double { limit.amount > 0 ? NSDecimalNumber(decimal: spent / limit.amount).doubleValue : 0 }
    var level: Int { ratio > 1 ? 2 : ratio >= Double(limit.warningPercent ?? globalWarning) / 100 ? 1 : 0 }

    static func spending(_ receipts: [SavedReceipt], currency: String, interval: DateInterval,
                         category: ReceiptCategory? = nil) -> Decimal {
        receipts.filter {
            $0.status == .completed && $0.currency == currency
                && (category == nil || $0.category == category)
                && $0.date.map { $0 >= interval.start && $0 < interval.end } == true
        }.compactMap(\.total).reduce(0, +)
    }
}

nonisolated enum BudgetValidationError: LocalizedError {
    case invalidLimit
    var errorDescription: String? { "Enter positive budget amounts and warning percentages between 1 and 100." }
}
