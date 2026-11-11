import Charts
import SwiftUI

struct WalletStatisticsView: View {
    let store: WalletStore
    @Binding var currency: String
    @State private var month = ReceiptDate.monthStart(.now)
    @State private var showBudget = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var spendingSize = 42.0

    private var receipts: [SavedReceipt] {
        store.monthReceipts(month, currency: currency).filter { $0.total != nil }
    }
    private var total: Decimal { store.spending(in: month, currency: currency) }
    private var categories: [(type: ReceiptCategory, amount: Decimal)] {
        ReceiptCategory.allCases.map { type in
            (type, receipts.filter { $0.category == type }.compactMap(\.total).reduce(0, +))
        }
        .filter { $0.amount != 0 }.sorted { $0.amount > $1.amount }
    }
    private var days: [(date: Date, amount: Double)] {
        let calendar = Calendar.current
        return (calendar.range(of: .day, in: .month, for: month) ?? 1..<31).compactMap { day in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: month) else { return nil }
            let value = receipts.filter { $0.date.map { calendar.isDate($0, inSameDayAs: date) } == true }
                .compactMap(\.total).reduce(Decimal.zero, +)
            return (date, NSDecimalNumber(decimal: value).doubleValue)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Insights").font(.system(.largeTitle, weight: .bold)).tracking(-1.2)
                    Spacer()
                }.padding(.top, 4)
                monthPicker
                WalletSectionDivider()
                if receipts.isEmpty {
                    WalletEmptyState(icon: "chart.bar.xaxis", title: "No spending")
                } else {
                    spendingChart
                    WalletSectionDivider()
                    categoryBreakdown
                }
                WalletSectionDivider()
                budgetCard
                let excluded = store.receipts.filter {
                    $0.status == .completed && $0.currency == currency && ($0.date == nil || $0.total == nil)
                }.count
                if excluded > 0 {
                    Label(
                        "\(excluded) \(excluded == 1 ? "receipt needs" : "receipts need") a date or total before appearing in these insights.",
                        systemImage: "info.circle"
                    )
                    .font(.caption).foregroundStyle(Color.walletSecondary)
                }
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
        }.scrollIndicators(.hidden).walletPage()
            .sheet(isPresented: $showBudget) { WalletBudgetView(store: store, currency: currency) }
    }

    private var monthPicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                monthNavigation
                Spacer(minLength: 0)
                currencyMenu
            }
            VStack(alignment: .leading, spacing: 12) {
                monthNavigation
                currencyMenu
            }
        }
    }

    private var monthNavigation: some View {
        HStack(spacing: 16) {
            Button {
                moveMonth(-1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 24, height: 44)
            }
            .accessibilityLabel("Previous month")
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                moveMonth(1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 24, height: 44)
            }
            .disabled(month >= ReceiptDate.monthStart(.now))
            .accessibilityLabel("Next month")
        }
        .font(.caption)
    }

    private var currencyMenu: some View {
        Menu {
            ForEach(store.currencies, id: \.self) { code in
                Button(code) { currency = code }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currency)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(Color.walletHighlight.opacity(0.3), in: .capsule)
        }
        .accessibilityLabel("Currency")
    }

    private func moveMonth(_ offset: Int) {
        month = Calendar.current.date(byAdding: .month, value: offset, to: month) ?? month
    }

    private var spendingChart: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Total spending").font(.subheadline).foregroundStyle(Color.walletSecondary)
                Text(WalletMoney.string(total, currency: currency)).font(
                    .system(size: spendingSize, weight: .medium, design: .rounded)
                )
                .tracking(-1.7).lineLimit(1).minimumScaleFactor(0.6).monospacedDigit()
            }
            Chart(days, id: \.date) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Spending", day.amount))
                    .foregroundStyle(Color.walletAccent.opacity(0.65)).cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.day(), centered: true).foregroundStyle(
                        Color.walletSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(
                        Color.walletSeparator)
                    AxisValueLabel().foregroundStyle(Color.walletSecondary)
                }
            }
            .frame(height: 140).accessibilityLabel("Daily spending")
            WalletSectionDivider()
            AdaptiveValueRow {
                metric("Receipts", value: "\(receipts.count)")
            } value: {
                metric(
                    "Average receipt",
                    value: WalletMoney.string(
                        receipts.isEmpty ? 0 : total / Decimal(receipts.count), currency: currency))
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Color.walletSecondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
    }

    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: 16) {
            WalletSectionHeader(title: "By type")
            ForEach(categories, id: \.type) { category in
                VStack(spacing: 10) {
                    AdaptiveValueRow {
                        HStack(spacing: 12) {
                            Image(systemName: category.type.symbol).font(.system(size: 18, weight: .regular))
                                .foregroundStyle(Color.walletAccent).frame(width: 24)
                            Text(category.type.title).font(.subheadline)
                        }
                    } value: {
                        Text(WalletMoney.string(category.amount, currency: currency)).font(
                            .subheadline.weight(.medium)
                        ).monospacedDigit()
                    }.accessibilityElement(children: .combine)
                    ProgressView(
                        value: total > 0
                            ? min(max(NSDecimalNumber(decimal: category.amount / total).doubleValue, 0), 1)
                            : 0
                    )
                    .tint(Color.walletAccent.opacity(0.55)).accessibilityHidden(true)
                }
            }
        }
    }

    private var budgetCard: some View {
        Button { showBudget = true } label: {
            HStack {
                Label("Budget", systemImage: "chart.pie")
                    .font(.title3.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
            }.padding(20).walletGlass(tint: Color.walletHighlight.opacity(0.3))
        }.buttonStyle(.plain).accessibilityIdentifier("editBudget")
    }
}
