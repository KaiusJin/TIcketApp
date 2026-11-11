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
    @State private var expandedReceiptID: UUID?
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
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private var visible: [SavedReceipt] {
        showAll || !search.isEmpty || selectedType != nil || favoritesOnly || sortByType
            ? filtered : Array(filtered.prefix(5))
    }

    private var animation: Animation? { reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.9) }

    var body: some View {
        ScrollViewReader { proxy in
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
            .onChange(of: expandedReceiptID) { _, id in
                if let id {
                    withAnimation(animation) { proxy.scrollTo(id, anchor: .center) }
                }
            }
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
                Text("Recently added").tag(false)
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
        WalletReceiptStack(
            receipts: receipts, expandedReceiptID: expandedReceiptID,
            expand: { id in
                searchFocused = false
                withAnimation(animation) { expandedReceiptID = id }
            },
            select: { receipt in
                searchFocused = false
                selectedReceipt = receipt
            })
    }
}

private struct WalletReceiptStack: View {
    let receipts: [SavedReceipt]
    let expandedReceiptID: UUID?
    let expand: (UUID?) -> Void
    let select: (SavedReceipt) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var cardHeight = 248.0
    @ScaledMetric(relativeTo: .body) private var exposedHeight = 176.0
    @ScaledMetric(relativeTo: .body) private var expandedHeight = 280.0

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(receipts.enumerated()), id: \.element.id) { index, receipt in
                let isExpanded = expandedReceiptID == receipt.id
                Button {
                    if isExpanded {
                        select(receipt)
                    } else {
                        expand(receipt.id)
                    }
                } label: {
                    WalletReceiptPass(
                        receipt: receipt, isExpanded: isExpanded,
                        height: isExpanded || dynamicTypeSize >= .xxLarge ? nil : cardHeight,
                        minimumHeight: isExpanded ? expandedHeight : nil)
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "View receipt details" : "Expand receipt")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .background(Color.receiptPass(at: index))
                .overlay(alignment: .topTrailing) {
                    if isExpanded {
                        Button { expand(nil) } label: {
                            Image(systemName: "chevron.up")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.walletAccent)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10).padding(.trailing, 48)
                        .accessibilityLabel("Collapse receipt")
                        .transition(.opacity)
                    }
                }
                .clipShape(
                    ReceiptPaper(cornerRadius: 28, holeInset: 32), style: FillStyle(eoFill: true))
                .offset(y: isExpanded && !reduceMotion ? -8 : 0)
                .padding(.top, spacing(before: index))
                .zIndex(isExpanded ? Double(receipts.count) : Double(index))
                .id(receipt.id)
            }
        }
    }

    private func spacing(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        if dynamicTypeSize >= .xxLarge || receipts[index - 1].id == expandedReceiptID { return 16 }
        return -(cardHeight - exposedHeight)
    }
}

private struct WalletReceiptPass: View {
    let receipt: SavedReceipt
    let isExpanded: Bool
    let height: CGFloat?
    let minimumHeight: CGFloat?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var previewItems: [ReceiptItem] { Array(receipt.items.prefix(2)) }
    private var remainingItems: Int { max(receipt.items.count - 2, 0) }
    private var wrapsText: Bool { isExpanded || dynamicTypeSize >= .xxLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep the summary and two-item preview above the next overlapping card.
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 12) {
                    Text(receipt.merchant).font(.system(.headline, weight: .semibold))
                        .lineLimit(wrapsText ? nil : 1)
                    Spacer(minLength: 0)
                    Color.clear.frame(width: isExpanded ? 68 : 16, height: 16)
                        .accessibilityHidden(true)
                }
                let layout =
                    dynamicTypeSize >= .xxLarge
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
                layout {
                    Text(
                        receipt.date?.formatted(.dateTime.month(.abbreviated).day().year())
                            ?? "Date needs review"
                    )
                    .font(.caption).foregroundStyle(Color.walletSecondary)
                    .lineLimit(dynamicTypeSize >= .xxLarge ? nil : 1)
                    .minimumScaleFactor(0.8)
                    if dynamicTypeSize < .xxLarge { Spacer(minLength: 0) }
                    Text(WalletMoney.string(receipt.total, currency: receipt.currency))
                        .font(.system(.title3, weight: .medium)).monospacedDigit().lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                }
            }
            itemPreview.padding(.top, 12)
            Spacer(minLength: 18)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(
                    (receipt.category ?? .other).title,
                    systemImage: (receipt.category ?? .other).symbol)
                Spacer(minLength: 0)
                Text(isExpanded ? "View receipt" : "Tap to expand")
                if isExpanded { Image(systemName: "chevron.right") }
            }
            .font(.caption).foregroundStyle(Color.walletAccent)
        }
        .padding(24).frame(height: height, alignment: .top)
        .frame(minHeight: minimumHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(ReceiptPaper(cornerRadius: 28, holeInset: 32), eoFill: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([
                receipt.merchant,
                receipt.date?.formatted(date: .abbreviated, time: .omitted) ?? "Date needs review",
                WalletMoney.string(receipt.total, currency: receipt.currency),
            ] + previewItems.map(\.name) + (remainingItems > 0 ? ["\(remainingItems) more items"] : []))
                .joined(separator: ", "))
    }

    private var itemPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if previewItems.isEmpty {
                Text("No items added").font(.subheadline)
            } else {
                ForEach(previewItems) { item in
                    Text(item.name.isEmpty ? "Needs review" : item.name)
                        .font(.subheadline)
                        .lineLimit(wrapsText ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if remainingItems > 0 {
                    Text("+\(remainingItems) more").font(.caption.weight(.medium))
                        .foregroundStyle(Color.walletAccent)
                }
            }
        }
        .foregroundStyle(Color.walletSecondary)
    }
}
