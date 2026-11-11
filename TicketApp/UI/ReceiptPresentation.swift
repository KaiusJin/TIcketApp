import SwiftUI

struct ReceiptPaperContent: View {
    let receipt: SavedReceipt
    var hole: CGFloat = 1
    var condensed = false
    var showsPaper = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 13) {
                MerchantMark(receipt: receipt, size: 62)
                Text(receipt.displayMerchant).font(.title2.weight(.semibold)).tracking(-0.7)
                    .multilineTextAlignment(
                        .center)
                Text(receipt.date?.formatted(.dateTime.month(.wide).day().year()) ?? "Date needs review")
                    .font(.caption).foregroundStyle(Color.walletSecondary)
                if let type = receipt.category {
                    Label(type.title, systemImage: type.symbol)
                        .font(.caption).foregroundStyle(Color.walletAccent)
                        .padding(.horizontal, 12).padding(.vertical, 7).background(
                            Color.walletHighlight.opacity(0.6), in: .capsule)
                }
            }.padding(.top, 8)
            WalletSectionDivider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\(receipt.items.count) \(receipt.items.count == 1 ? "item" : "items")")
                    Spacer()
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(Color.walletSecondary)
                ForEach(condensed ? Array(receipt.items.prefix(3)) : receipt.items) { item in
                    AdaptiveValueRow(spacing: 18) {
                        Text(item.name.isEmpty ? "Needs review" : item.name).font(.subheadline)
                    } value: {
                        Text(WalletMoney.string(item.amount, currency: receipt.currency)).font(.subheadline)
                            .monospacedDigit()
                    }
                }
            }
            WalletSectionDivider()
            VStack(spacing: 16) {
                ForEach(receipt.amounts.filter { $0.normalizedLabel != "TOTAL" || receipt.total == nil }) {
                    amount in
                    AdaptiveValueRow {
                        Text(amount.label).font(.caption)
                    } value: {
                        Text(WalletMoney.string(amount.value, currency: receipt.currency)).font(.subheadline)
                            .monospacedDigit()
                    }.foregroundStyle(Color.walletSecondary)
                }
                AdaptiveValueRow {
                    Text("Total").font(.headline)
                } value: {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(WalletMoney.string(receipt.total, currency: receipt.currency))
                            .font(.system(.title, design: .rounded, weight: .semibold)).tracking(-0.8)
                            .monospacedDigit()
                        Text(receipt.currency).font(.system(size: 9, weight: .medium)).tracking(2)
                            .foregroundStyle(Color.walletSecondary)
                    }
                }.padding(.top, 7)
            }
        }.padding(showsPaper ? 26 : 8)
            .background {
                if showsPaper {
                    ReceiptPaper(hole: hole).fill(Color.walletSurface, style: FillStyle(eoFill: true))
                }
            }
    }

}

private struct MerchantMark: View {
    let receipt: SavedReceipt
    var size: CGFloat = 48
    var body: some View {
        Group {
            if receipt.merchant.localizedCaseInsensitiveContains("T&T") {
                Text("T&T").font(.system(size: size * 0.28, weight: .heavy, design: .serif))
            } else if receipt.merchant.localizedCaseInsensitiveContains("Walmart") {
                Image(systemName: "sparkle").font(.system(size: size * 0.5, weight: .medium))
            } else {
                Image(systemName: (receipt.category ?? .other).symbol).font(
                    .system(size: size * 0.41, weight: .regular))
            }
        }
        .foregroundStyle(Color.walletAccent)
        .frame(width: size, height: size)
        .background(Color.walletAccent.opacity(0.12), in: .rect(cornerRadius: size * 0.32))
        .accessibilityHidden(true)
    }
}

struct ReceiptPaper: Shape {
    var hole: CGFloat = 1
    var cornerRadius: CGFloat = 26
    var holeInset: CGFloat = 28
    var animatableData: CGFloat {
        get { hole }
        set { hole = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius)
        if hole > 0 {
            let diameter = 16 * hole
            path.addEllipse(
                in: CGRect(
                    x: rect.maxX - holeInset - diameter / 2, y: rect.minY + holeInset - diameter / 2,
                    width: diameter, height: diameter))
        }
        return path
    }
}

struct OriginalReceiptView: View {
    var imageURL: URL? = nil
    var image: UIImage? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var loadedImage: UIImage?
    @State private var zoomed = false
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if let original = image ?? loadedImage {
                        Image(uiImage: original).resizable().scaledToFit()
                            .frame(width: (geometry.size.width - 32) * (zoomed ? 2 : 1))
                            .padding(16).onTapGesture(count: 2) { zoomed.toggle() }
                            .accessibilityLabel("Original receipt")
                            .accessibilityAction(named: "Toggle zoom") { zoomed.toggle() }
                    } else {
                        ContentUnavailableView("No photo attached", systemImage: "photo")
                    }
                }
            }.walletPage().navigationTitle("Original receipt").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task(id: imageURL) {
                    if let imageURL { loadedImage = UIImage(contentsOfFile: imageURL.path) }
                }
        }
    }
}

extension ReceiptCategory {
    var title: String {
        switch self {
        case .groceries: "Groceries"
        case .dining: "Dining"
        case .shopping: "Shopping"
        case .work: "Work"
        case .learning: "Learning"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .work: "briefcase"
        case .shopping: "bag"
        case .learning: "book.closed"
        case .dining: "fork.knife"
        case .groceries: "carrot"
        case .other: "square.grid.2x2"
        }
    }
}

nonisolated enum WalletMoney {
    static func symbol(for currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_CA")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.currencySymbol ?? currency
    }

    static func string(_ value: Decimal?, currency: String = "CAD") -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_CA")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    static func input(_ value: Decimal?) -> String {
        value.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }

    static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^-?[0-9]+([.,][0-9]{1,8})?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Decimal(
            string: trimmed.replacingOccurrences(of: ",", with: "."),
            locale: Locale(identifier: "en_US_POSIX"))
    }
}

extension ReceiptStatus {
    var title: String {
        switch self {
        case .processing: "Processing"
        case .needsReview: "Needs review"
        case .completed: "Completed"
        case .failed: "Reading failed"
        case .cancelled: "Cancelled"
        }
    }
}

extension SavedReceipt {
    var displayMerchant: String {
        merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Receipt draft" : merchant
    }
}
