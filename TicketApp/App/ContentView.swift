import SwiftUI

struct ContentView: View {
    let store: WalletStore
    let processor: ReceiptCaptureModel
    @State private var tab: WalletNavigationBar.Tab = .wallet
    @State private var sheet: Sheet?
    @State private var currency = "CAD"
    @State private var isSearching = false
    @AppStorage("wallet.appearance") private var appearance = "system"

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if tab == .wallet {
                    WalletHomeView(
                        store: store, processor: processor,
                        openSettings: { sheet = .settings }, openDrafts: { sheet = .drafts },
                        scan: { sheet = .scan }, showsSearch: $isSearching)
                } else {
                    WalletStatisticsView(store: store, currency: $currency)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if tab != .wallet || !isSearching {
                    WalletNavigationBar(tab: $tab, scan: { sheet = .scan })
                }
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .tint(Color.walletAccent)
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .scan: ReceiptCaptureView(store: store, processor: processor)
                case .drafts: WalletDraftsView(store: store, processor: processor)
                case .settings: WalletSettingsView(appearance: $appearance)
                }
            }
            // Sheets have their own presentation boundary; keep their preference in sync with the root.
            .preferredColorScheme(preferredColorScheme)
        }
        .alert(
            "Couldn't update your wallet",
            isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
        ) {
            Button("OK") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .task { processor.setActive(UIApplication.shared.applicationState == .active) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) {
            _ in
            processor.setActive(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) {
            _ in
            processor.setActive(true)
        }
    }

    private enum Sheet: String, Identifiable {
        case scan, drafts, settings
        var id: String { rawValue }
    }
}

#Preview {
    let store = WalletStore(
        repository: LocalWalletRepository(
            directory: FileManager.default.temporaryDirectory.appending(path: "ReceiptWalletPreview")))
    ContentView(store: store, processor: ReceiptCaptureModel(store: store))
}

private struct WalletNavigationBar: View {
    enum Tab { case wallet, insights }

    @Binding var tab: Tab
    let scan: () -> Void
    @GestureState private var tabDrag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    tabButton(.wallet, icon: "wallet.bifold", title: "Wallet")
                    tabButton(.insights, icon: "chart.bar.xaxis", title: "Insights")
                }
                .background {
                    GeometryReader { geometry in
                        let width = (geometry.size.width - 4) / 2
                        let travel = width + 4
                        let offset = min(max((tab == .wallet ? 0 : travel) + tabDrag, 0), travel)
                        Capsule()
                            .fill(reduceTransparency ? Color.walletHighlight : Color.white.opacity(0.16))
                            .background {
                                if !reduceTransparency { Capsule().fill(.ultraThinMaterial) }
                            }
                            .overlay {
                                Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.75)
                            }
                            .shadow(color: Color.walletAccent.opacity(0.12), radius: 6, x: 0, y: 3)
                            .frame(width: width, height: geometry.size.height)
                            .offset(x: offset)
                    }.allowsHitTesting(false)
                }
                .coordinateSpace(name: "walletTabs")
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .named("walletTabs"))
                        .updating($tabDrag) { value, state, _ in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            state = value.translation.width
                        }
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height),
                                abs(value.translation.width) > 24
                            else { return }
                            selectTab(value.translation.width > 0 ? .insights : .wallet)
                        }
                )
                .animation(
                    reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: tabDrag == 0
                )
                .padding(6).walletGlass(radius: 34, interactive: true)
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.65), .white.opacity(0.08), .white.opacity(0.3)],
                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75
                    ).allowsHitTesting(false)
                }
                .shadow(color: Color.walletAccent.opacity(0.12), radius: 16, x: 0, y: 6)
                Button(action: scan) {
                    Image(systemName: "plus").font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Color.walletAccent).frame(width: 62, height: 62)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .walletGlass(radius: 31, tint: Color.walletHighlight.opacity(0.6), interactive: true)
                .accessibilityLabel("Scan receipt").accessibilityIdentifier("scanReceipt")
            }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 9)
        }
    }

    private func tabButton(_ selection: Tab, icon: String, title: String) -> some View {
        Button {
            selectTab(selection)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Image(systemName: tab == selection && selection == .wallet ? "wallet.bifold.fill" : icon)
                        .font(.system(size: 19))
                    Text(title).font(.caption.weight(.semibold))
                }
                VStack(spacing: 4) {
                    Image(systemName: tab == selection && selection == .wallet ? "wallet.bifold.fill" : icon)
                        .font(.system(size: 19))
                    Text(title).font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(tab == selection ? Color.walletInk : Color.walletSecondary)
            .frame(maxWidth: .infinity).frame(minHeight: 52)
            .contentShape(.capsule)
        }.buttonStyle(.plain).accessibilityAddTraits(tab == selection ? [.isSelected] : [])
            .accessibilityIdentifier(selection == .wallet ? "walletTab" : "insightsTab")
    }

    private func selectTab(_ selection: Tab) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) { tab = selection }
    }
}
