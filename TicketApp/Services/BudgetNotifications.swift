import Foundation
import UserNotifications

@MainActor
final class BudgetNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = BudgetNotifications()
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    private var task: Task<Void, Never>?

    func refresh(receipts: [SavedReceipt], history: [String: [BudgetRevision]]) {
        task?.cancel()
        task = Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard !Task.isCancelled, settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            for (currency, revisions) in history {
                guard let plan = revisions.last?.plan, plan.notifications else { continue }
                let interval = plan.interval(containing: .now)
                let limits = [("Total", Optional<ReceiptCategory>.none, plan.total)]
                    + ReceiptCategory.allCases.map { ($0.rawValue.capitalized, Optional($0), plan.categories[$0.rawValue] ?? BudgetLimit()) }
                for (title, category, limit) in limits where limit.enabled && limit.amount > 0 {
                    let spent = BudgetProgress.spending(receipts, currency: currency, interval: interval, category: category)
                    let progress = BudgetProgress(spent: spent, limit: limit, globalWarning: plan.warningPercent)
                    guard progress.level > 0, !Task.isCancelled else { continue }
                    let key = "budget.\(currency).\(plan.cycle.rawValue).\(interval.start.timeIntervalSince1970).\(title).\(progress.level)"
                    guard !UserDefaults.standard.bool(forKey: key) else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = progress.level == 2 ? "Budget exceeded" : "Budget warning"
                    content.body = "\(title) · \(currency): \(progress.ratio.formatted(.percent.precision(.fractionLength(0)))) of your budget used."
                    content.sound = .default
                    do {
                        try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
                        UserDefaults.standard.set(true, forKey: key)
                    } catch { /* The in-app status remains available when delivery fails. */ }
                }
            }
        }
    }
}
