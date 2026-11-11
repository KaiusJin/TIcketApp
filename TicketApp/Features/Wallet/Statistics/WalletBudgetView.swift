import Combine
import SwiftUI
import UserNotifications

struct WalletBudgetView: View {
    let store: WalletStore
    let currency: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var date = Date()
    @State private var editing = false
    @State private var followingCurrent = true

    private var plan: BudgetPlan {
        store.budgetPlan(for: currency, at: min(intervalEnd, .now)) ?? BudgetPlan()
    }
    private var currentPlan: BudgetPlan { store.budgetPlan(for: currency) ?? BudgetPlan() }
    private var intervalEnd: Date { currentPlan.interval(containing: date).end.addingTimeInterval(-1) }
    private var interval: DateInterval { plan.interval(containing: date) }
    private var isCurrent: Bool { interval.start <= Date() && Date() < interval.end }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                            .accessibilityLabel("Previous period")
                        VStack(spacing: 4) {
                            Text(plan.cycle.rawValue.capitalized).font(.headline)
                            Text("\(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity)
                        Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                            .disabled(isCurrent).accessibilityLabel("Next period")
                    }
                    Text(isCurrent ? "Your budget · \(currency)" : "Budget history · \(currency)")
                        .font(.title2.weight(.semibold))
                    Text("Actual spending: \(WalletMoney.string(spending(), currency: currency))")
                        .font(.headline).monospacedDigit()
                    if !isCurrent {
                        Button("Back to current period") { followingCurrent = true; date = .now }
                    }
                    if store.budgetPlan(for: currency, at: min(interval.end.addingTimeInterval(-1), .now)) == nil {
                        Text("No budget was set for this period. Actual spending is still available.")
                            .font(.subheadline).foregroundStyle(Color.walletSecondary)
                    }
                    progressCard("Total budget", symbol: "chart.pie", limit: plan.total, spent: spending())
                    Text("Category budgets").font(.title3.weight(.semibold))
                    ForEach(ReceiptCategory.allCases) { category in
                        progressCard(category.title, symbol: category.symbol,
                                     limit: plan.categories[category.rawValue] ?? BudgetLimit(), spent: spending(category))
                    }
                    Text("Total and category budgets are independent limits on the same receipts; they are never added together. Only completed receipts with a date and total are included. Currencies are kept separate.")
                        .font(.caption).foregroundStyle(Color.walletSecondary)
                }.padding(24)
            }.walletPage().navigationTitle("Budget").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("Budget settings")
                    }
                }
                .sheet(isPresented: $editing) {
                    BudgetSettingsView(store: store, currency: currency, plan: currentPlan)
                }
                .task { store.refreshBudgetNotifications() }
                .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
                    if followingCurrent { date = now }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        if followingCurrent { date = .now }
                        store.refreshBudgetNotifications()
                    }
                }
        }
    }

    private func spending(_ category: ReceiptCategory? = nil) -> Decimal {
        BudgetProgress.spending(store.receipts, currency: currency, interval: interval, category: category)
    }

    private func move(_ direction: Int) {
        followingCurrent = false
        date = direction < 0 ? interval.start.addingTimeInterval(-1) : min(interval.end, .now)
        if currentPlan.interval(containing: .now).contains(date) { followingCurrent = true; date = .now }
    }

    private func progressCard(_ title: String, symbol: String, limit: BudgetLimit, spent: Decimal) -> some View {
        let progress = BudgetProgress(spent: spent, limit: limit, globalWarning: plan.warningPercent)
        let color: Color = progress.level == 2 ? .red : progress.level == 1 ? .orange : .walletAccent
        return VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            Text("Used \(WalletMoney.string(spent, currency: currency))").font(.title3).monospacedDigit()
            if limit.enabled && limit.amount > 0 {
                Text("of \(WalletMoney.string(limit.amount, currency: currency)) · \(progress.ratio * 100, specifier: "%.0f")%")
                    .font(.subheadline).foregroundStyle(Color.walletSecondary)
                ProgressView(value: min(max(progress.ratio, 0), 1)).tint(color)
                    .accessibilityLabel("Budget used").accessibilityValue("\(progress.ratio.formatted(.percent.precision(.fractionLength(0))))")
                Text("\(WalletMoney.string(abs(progress.remaining), currency: currency)) \(progress.remaining < 0 ? "over budget" : "remaining")")
                    .font(.subheadline.weight(.medium)).foregroundStyle(color)
                if progress.level > 0 {
                    Label(progress.level == 2 ? "Budget exceeded" : "Warning threshold reached", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(color)
                }
                Text("Warning at \(limit.warningPercent ?? plan.warningPercent)%").font(.caption).foregroundStyle(Color.walletSecondary)
            } else {
                Text("Budget off").font(.caption).foregroundStyle(Color.walletSecondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .walletGlass(tint: Color.walletHighlight.opacity(0.25))
    }
}

private struct BudgetSettingsView: View {
    let store: WalletStore
    let currency: String
    @State var plan: BudgetPlan
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Period · \(currency)") {
                    Picker("Budget period", selection: $plan.cycle) {
                        ForEach(BudgetCycle.allCases) { cycle in
                            Text(cycle.rawValue.capitalized).tag(cycle)
                        }
                    }
                    Text("Limits apply to each calendar period. Weeks follow your device calendar. Quarters begin in January, April, July and October.")
                        .font(.caption).foregroundStyle(Color.walletSecondary)
                }
                Section("Global warning") {
                    Stepper("Warn at \(plan.warningPercent)%", value: $plan.warningPercent, in: 1...100)
                }
                Section("Total budget") { limitEditor($plan.total, customWarning: false) }
                ForEach(ReceiptCategory.allCases) { category in
                    Section(category.title) {
                        limitEditor(Binding(get: { plan.categories[category.rawValue] ?? BudgetLimit() },
                                            set: { plan.categories[category.rawValue] = $0 }), customWarning: true)
                    }
                }
                Section {
                    Toggle("Budget notifications", isOn: $plan.notifications)
                    Text("Receive a warning and an overspending notification once per limit per period when saved receipts update spending. Past periods are not notified.")
                        .font(.caption).foregroundStyle(Color.walletSecondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.scrollContentBackground(.hidden).walletPage().navigationTitle("Budget settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }.disabled(!plan.isValid || saving)
                    }
                }
                .interactiveDismissDisabled(saving)
        }
    }

    private func limitEditor(_ limit: Binding<BudgetLimit>, customWarning: Bool) -> some View {
        Group {
            Toggle("Enabled", isOn: limit.enabled)
            if limit.wrappedValue.enabled {
                BudgetAmountField(amount: limit.amount, currency: currency)
                if limit.wrappedValue.amount <= 0 { Text("Enter an amount greater than zero.").font(.caption).foregroundStyle(.red) }
                if customWarning {
                    Toggle("Use global warning", isOn: Binding(
                        get: { limit.wrappedValue.warningPercent == nil },
                        set: { limit.wrappedValue.warningPercent = $0 ? nil : plan.warningPercent }))
                    if let percent = limit.wrappedValue.warningPercent {
                        Stepper("Warn at \(percent)%", value: Binding(
                            get: { limit.wrappedValue.warningPercent ?? plan.warningPercent },
                            set: { limit.wrappedValue.warningPercent = $0 }), in: 1...100)
                    }
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if plan.notifications {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                if !allowed {
                    error = "Notifications are disabled in iOS Settings. Enable them there, or turn off Budget notifications to save."
                    return
                }
            }
            try store.saveBudgetPlan(plan, currency: currency)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct BudgetAmountField: View {
    @Binding var amount: Decimal
    let currency: String
    @State private var text = ""

    var body: some View {
        TextField("Amount in \(currency)", text: $text)
            .keyboardType(.decimalPad).accessibilityLabel("Budget amount in \(currency)")
            .onAppear { text = WalletMoney.input(amount) }
            .onChange(of: text) { _, value in amount = WalletMoney.parse(value) ?? 0 }
    }
}
