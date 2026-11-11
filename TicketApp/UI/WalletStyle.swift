import SwiftUI

extension Color {
    static let walletBackground = adaptive(light: (243.0 / 255, 248.0 / 255, 1), dark: (0.055, 0.075, 0.105))
    static let walletSurface = adaptive(light: (1, 1, 1), dark: (0.10, 0.135, 0.18))
    static let walletInk = adaptive(light: (0.12, 0.17, 0.23), dark: (0.95, 0.95, 0.95))
    static let walletSecondary = adaptive(light: (0.39, 0.46, 0.54), dark: (0.61, 0.68, 0.76))
    static let walletAccent = adaptive(light: (0.22, 0.43, 0.65), dark: (0.61, 0.78, 0.94))
    static let walletHighlight = adaptive(light: (0.81, 0.89, 0.98), dark: (0.15, 0.23, 0.33))
    static let walletSeparator = Color.primary.opacity(0.06)

    static func receiptPass(at position: Int) -> Color {
        receiptPassColors[position % receiptPassColors.count]
    }

    private static let receiptPassColors: [Color] = {
        let shades: [(CGFloat, CGFloat, CGFloat)] = [
            (0.90, 0.95, 1.00), (0.93, 0.97, 1.00), (0.87, 0.93, 0.99),
            (0.91, 0.95, 0.99), (0.85, 0.92, 0.98),
        ]
        return shades.map { shade in
            adaptive(light: shade, dark: (shade.0 * 0.22, shade.1 * 0.28, shade.2 * 0.36))
        }
    }()

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(
            uiColor: UIColor { traits in
                let rgb = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            })
    }
}

struct WalletBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color.walletBackground, Color.walletSurface.opacity(0.55), Color.walletBackground],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .background(Color.walletBackground).ignoresSafeArea()
    }
}

private struct WalletGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = 28
    var tint: Color? = nil
    var interactive = false
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(tint ?? Color.walletSurface, in: .rect(cornerRadius: radius))
                .background(Color.walletSurface, in: .rect(cornerRadius: radius))
        } else {
            content.glassEffect(
                .regular.tint(tint ?? .clear).interactive(interactive), in: .rect(cornerRadius: radius))
        }
    }
}

extension View {
    func walletGlass(radius: CGFloat = 28, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(WalletGlassModifier(radius: radius, tint: tint, interactive: interactive))
    }
    func walletPage() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity).background { WalletBackground() }
            .foregroundStyle(Color.walletInk).tint(Color.walletAccent)
    }
}

struct WalletPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body, design: .rounded, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .foregroundStyle(Color.walletInk).walletGlass(
                tint: Color.walletHighlight.opacity(0.65), interactive: true
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
