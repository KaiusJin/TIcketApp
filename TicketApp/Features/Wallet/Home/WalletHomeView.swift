import SwiftUI

struct WalletHomeView: View {
    let store: WalletStore
    let processor: ReceiptCaptureModel
    let openSettings: () -> Void
    let openDrafts: () -> Void
    let scan: () -> Void
    @AppStorage("wallet.sortByType") private var sortByType = false
    @State private var search = ""
    @State private var selectedType: ReceiptCategory?
    @State private var favoritesOnly = false
    @State private var showAll = false
    @State private var showsSearch = false
    @State private var selectedReceipt: SavedReceipt?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var completedReceipts: [SavedReceipt] { store.receipts.filter { $0.status == .completed } }
    private var draftCount: Int { store.receipts.filter { $0.status != .completed }.count }

    private var filtered: [SavedReceipt] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return completedReceipts.filter { receipt in
            let text =
                ([
                    receipt.merchant, receipt.date?.formatted(date: .abbreviated, time: .omitted) ?? "",
                    receipt.date?.formatted(.iso8601.year().month().day().dateSeparator(.dash)) ?? "",
                ] + receipt.items.map(\.name)).joined(separator: " ")
            return (query.isEmpty || text.localizedCaseInsensitiveContains(query))
                && (selectedType == nil || receipt.category == selectedType)
                && (!favoritesOnly || receipt.isFavorite)
        }.sorted {
            let left = $0.date ?? $0.createdAt
            let right = $1.date ?? $1.createdAt
            return left == right ? $0.createdAt > $1.createdAt : left > right
        }
    }

    private var visible: [SavedReceipt] {
        showAll || !search.isEmpty || selectedType != nil || favoritesOnly || sortByType
            ? filtered : Array(filtered.prefix(5))
    }

    private var animation: Animation? { reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.9) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !completedReceipts.isEmpty {
                    collectionControls
                    if showsSearch { searchField.transition(.opacity.combined(with: .move(edge: .top))) }
                }
                receiptCollection
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 32)
        }
        .scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
        .walletPage()
        .navigationDestination(
            isPresented: Binding(
                get: { selectedReceipt != nil },
                set: { if !$0 { selectedReceipt = nil } }
            )
        ) {
            if let receipt = selectedReceipt {
                ReceiptDetailView(store: store, processor: processor, receipt: receipt)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Receipt Wallet").font(.system(.largeTitle, weight: .bold)).tracking(-1.2)
                .minimumScaleFactor(0.8).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            Spacer(minLength: 12)
            Button(action: openDrafts) {
                Image(systemName: "tray").font(.system(size: 18, weight: .regular))
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if draftCount > 0 {
                            Text(draftCount > 99 ? "99+" : "\(draftCount)")
                                .font(.caption2.weight(.semibold)).padding(4)
                                .foregroundStyle(Color.walletSurface)
                                .background(Color.walletAccent, in: .capsule)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(.plain).walletGlass(radius: 22, interactive: true)
            .accessibilityLabel("Drafts, \(draftCount) receipts").accessibilityIdentifier("walletDrafts")
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .regular))
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).walletGlass(radius: 22, interactive: true)
                .accessibilityLabel("Settings").accessibilityIdentifier("walletSettings")
        }
    }

    private var collectionControls: some View {
        HStack(spacing: 12) {
            if let type = selectedType {
                Text(type.title).font(.subheadline).foregroundStyle(Color.walletSecondary)
            } else if favoritesOnly {
                Text("Favorites").font(.subheadline).foregroundStyle(Color.walletSecondary)
            }
            Spacer(minLength: 0)
            if filtered.count > 5 && !sortByType && search.isEmpty && selectedType == nil && !favoritesOnly {
                Button(showAll ? "Recent" : "See all") {
                    withAnimation(animation) { showAll.toggle() }
                }.font(.subheadline).accessibilityIdentifier("seeAllReceipts")
            }
            Button {
                withAnimation(animation) { showsSearch.toggle() }
                if showsSearch {
                    searchFocused = true
                } else {
                    search = ""
                    searchFocused = false
                }
            } label: {
                Image(systemName: showsSearch ? "xmark" : "magnifyingglass").font(.system(size: 17))
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(showsSearch ? "Close" : "Search receipts")
            filterMenu
        }.padding(.top, -12).padding(.bottom, -8)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Sort receipts", selection: $sortByType) {
                Text("By date").tag(false)
                Text("By type").tag(true)
            }
            Menu("Type") {
                Button("All") {
                    selectedType = nil
                    favoritesOnly = false
                }
                ForEach(ReceiptCategory.allCases) { type in
                    Button {
                        selectedType = type
                        favoritesOnly = false
                    } label: {
                        Label(type.title, systemImage: selectedType == type ? "checkmark" : type.symbol)
                    }
                }
            }
            Toggle("Favorites", isOn: $favoritesOnly)
        } label: {
            Image(
                systemName: selectedType != nil || favoritesOnly
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
            )
            .font(.system(size: 18)).frame(width: 44, height: 44)
        }.accessibilityLabel("Sort receipts").accessibilityIdentifier("sortReceipts")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.walletSecondary)
            TextField("Search receipts", text: $search).font(.subheadline).autocorrectionDisabled()
                .focused($searchFocused).accessibilityIdentifier("receiptSearch")
        }.padding(.horizontal, 16).frame(minHeight: 48).walletGlass(radius: 24)
    }

    @ViewBuilder private var receiptCollection: some View {
        if completedReceipts.isEmpty {
            VStack(spacing: 4) {
                WalletEmptyState(icon: "wallet.bifold", title: "No receipts")
                Button("Add receipt", action: scan).font(.subheadline.weight(.medium))
            }.frame(maxWidth: .infinity).padding(.vertical, 60)
        } else if visible.isEmpty {
            WalletEmptyState(
                icon: favoritesOnly ? "bookmark" : "magnifyingglass",
                title: favoritesOnly ? "No favorites" : "No receipts found")
        } else if sortByType {
            VStack(alignment: .leading, spacing: 30) {
                ForEach(ReceiptCategory.allCases) { type in
                    let group = visible.filter { $0.category == type }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Label(type.title, systemImage: type.symbol)
                                .font(.subheadline).foregroundStyle(Color.walletSecondary).padding(
                                    .leading, 4)
                            receiptStack(group)
                        }
                    }
                }
            }
        } else {
            receiptStack(visible)
        }
    }

    private func receiptStack(_ receipts: [SavedReceipt]) -> some View {
        WalletReceiptStack(receipts: receipts) { receipt in
            searchFocused = false
            selectedReceipt = receipt
        }
    }
}

private struct WalletReceiptStack: View {
    let receipts: [SavedReceipt]
    let select: (SavedReceipt) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var cardHeight = 214.0
    @ScaledMetric(relativeTo: .body) private var exposedHeight = 84.0

    var body: some View {
        VStack(spacing: dynamicTypeSize >= .xxLarge ? 16 : 0) {
            ForEach(Array(receipts.enumerated()), id: \.element.id) { index, receipt in
                Button {
                    select(receipt)
                } label: {
                    WalletReceiptPass(
                        receipt: receipt, height: dynamicTypeSize >= .xxLarge ? nil : cardHeight)
                }
                .buttonStyle(.plain)
                .accessibilityHint("View receipt details")
                .background {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.receiptPass(at: index).gradient)
                        .opacity(reduceTransparency ? 1 : 0.88)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 28))
                }
                .clipShape(.rect(cornerRadius: 28))
                .shadow(color: Color.walletAccent.opacity(0.035), radius: 5, x: 0, y: 2)
                .padding(.top, index == 0 || dynamicTypeSize >= .xxLarge ? 0 : -(cardHeight - exposedHeight))
                // The upper pass covers the next pass, leaving its merchant and amount exposed below.
                .zIndex(Double(receipts.count - index))
                .id(receipt.id)
            }
        }
    }
}

private struct WalletReceiptPass: View {
    let receipt: SavedReceipt
    let height: CGFloat?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: (receipt.category ?? .other).symbol).font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.walletAccent.opacity(0.8))
                Spacer()
                Circle().fill(Color.walletBackground.opacity(0.9)).frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 18)
            let layout =
                dynamicTypeSize >= .xxLarge
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                VStack(alignment: .leading, spacing: 7) {
                    Text(receipt.merchant).font(.system(.headline, weight: .semibold))
                        .lineLimit(dynamicTypeSize >= .xxLarge ? nil : 1)
                    Text(
                        receipt.date?.formatted(.dateTime.month(.abbreviated).day().year())
                            ?? "Date needs review"
                    )
                    .font(.caption).foregroundStyle(Color.walletSecondary)
                }
                if dynamicTypeSize < .xxLarge { Spacer(minLength: 0) }
                Text(WalletMoney.string(receipt.total, currency: receipt.currency))
                    .font(.system(.title3, weight: .medium)).monospacedDigit().lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
        }
        .padding(24).frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect(cornerRadius: 28))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [
                receipt.merchant,
                receipt.date?.formatted(date: .abbreviated, time: .omitted) ?? "Date needs review",
                WalletMoney.string(receipt.total, currency: receipt.currency),
            ].joined(separator: ", "))
    }
}
