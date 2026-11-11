import SwiftUI

struct WalletSectionDivider: View {
    var body: some View {
        Rectangle().fill(Color.walletSecondary.opacity(0.18))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

struct WalletSectionHeader: View {
    let title: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold)).tracking(-0.5)
            Spacer()
        }
    }
}

struct WalletEmptyState: View {
    let icon: String
    let title: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.walletAccent).frame(width: 76, height: 76)
                .background(Color.walletHighlight.opacity(0.6), in: .rect(cornerRadius: 26))
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 32)
    }
}

/// Keep amounts beside their labels when they fit, and below them at larger text sizes.
struct AdaptiveValueRow<Label: View, Value: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let spacing: CGFloat
    let label: Label
    let value: Value

    init(spacing: CGFloat = 12, @ViewBuilder label: () -> Label, @ViewBuilder value: () -> Value) {
        self.spacing = spacing
        self.label = label()
        self.value = value()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            verticalContent
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: spacing) {
                    label
                    Spacer(minLength: 0)
                    value
                }
                verticalContent
            }
        }
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            value
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
