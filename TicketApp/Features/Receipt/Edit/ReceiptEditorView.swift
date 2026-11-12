import SwiftUI

struct ReceiptEditorView: View {
    @State private var draft: SavedReceipt
    @State private var itemAmounts: [UUID: String]
    @State private var summaryAmounts: [UUID: String]
    @State private var showOriginal = false
    @State private var error: String?
    @State private var collected = false
    let image: UIImage?
    let imageURL: URL?
    let onSave: (SavedReceipt) throws -> Void
    let onDraftChange: ((SavedReceipt) throws -> Void)?
    let onFinished: (() -> Void)?
    private let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var categoryWidth = 96.0

    init(
        receipt: SavedReceipt, image: UIImage? = nil, imageURL: URL? = nil,
        onSave: @escaping (SavedReceipt) throws -> Void,
        onDraftChange: ((SavedReceipt) throws -> Void)? = nil, onFinished: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: receipt)
        _itemAmounts = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: receipt.items.map { ($0.id, WalletMoney.input($0.amount)) }))
        _summaryAmounts = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: receipt.amounts.map { ($0.id, WalletMoney.input($0.value)) }))
        self.image = image
        self.imageURL = imageURL
        self.onSave = onSave
        self.onDraftChange = onDraftChange
        self.onFinished = onFinished
        isNew = receipt.status != .completed
    }

    private var validAmounts: Bool {
        (draft.items.map { itemAmounts[$0.id] ?? "" } + draft.amounts.map { summaryAmounts[$0.id] ?? "" })
            .allSatisfy {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || WalletMoney.parse($0) != nil
            }
    }
    private var canSave: Bool {
        draft.category != nil && !draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validAmounts
            && draft.items.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && draft.amounts.allSatisfy { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if image != nil || imageURL != nil {
                    Button {
                        showOriginal = true
                    } label: {
                        Label("View original", systemImage: "doc.viewfinder").font(
                            .subheadline.weight(.medium))
                    }
                }
                if !draft.reviewNotes.isEmpty {
                    Label("Check the amounts against the photo.", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                receiptFields
                WalletSectionDivider()
                typePicker
                WalletSectionDivider()
                itemFields
                WalletSectionDivider()
                amountFields
                if !validAmounts {
                    Text("Enter a valid amount, or leave it blank if unknown.").font(.caption)
                        .foregroundStyle(.red)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(24)
        }.scrollDismissesKeyboard(.interactively).scrollIndicators(.hidden).walletPage()
            .navigationTitle("Review receipt").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(collected)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !collected {
                    VStack(spacing: 8) {
                        Button(isNew ? "Save receipt" : "Save changes", action: save)
                            .buttonStyle(WalletPrimaryButton()).disabled(!canSave).opacity(canSave ? 1 : 0.45)
                            .accessibilityIdentifier("confirmReceipt")
                    }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12).background(
                        .regularMaterial)
                }
            }
            .sheet(isPresented: $showOriginal) { OriginalReceiptView(imageURL: imageURL, image: image) }
            .overlay {
                if collected {
                    ReceiptCollectionAnimation(receipt: draft) {
                        if let onFinished { onFinished() } else { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(collected)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification))
        { _ in
            persistDraftChanges()
        }
            .onDisappear {
                persistDraftChanges()
            }
    }

    private var receiptFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Store name", text: $draft.merchant).font(.title2.weight(.semibold))
                .accessibilityIdentifier("merchantName")
            WalletSectionDivider()
            let dateLayout =
                dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout())
            dateLayout {
                Text("Purchase date").frame(maxWidth: .infinity, alignment: .leading)
                WalletDateButton(
                    title: "Purchase date",
                    selection: Binding(get: { draft.date ?? .now }, set: { draft.date = $0 }))
            }
            .font(.subheadline)
            HStack {
                Text("Currency")
                Spacer()
                Picker("Currency", selection: $draft.currency) {
                    ForEach(["CAD", "USD", "CNY", "EUR", "GBP", "JPY", "HKD"], id: \.self) {
                        Text($0).tag($0)
                    }
                }.pickerStyle(.menu).labelsHidden()
            }.font(.subheadline)
        }
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Type").font(.headline)
                Text("*").foregroundStyle(Color.walletAccent)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: categoryWidth), spacing: 10)], spacing: 10) {
                ForEach(ReceiptCategory.allCases) { type in
                    Button {
                        draft.category = type
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: type.symbol).font(.system(size: 25, weight: .light))
                            Text(type.title).font(.caption.weight(.medium))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 12)
                        .frame(maxWidth: .infinity).frame(minHeight: 84)
                        .contentShape(.rect(cornerRadius: 18))
                        .foregroundStyle(draft.category == type ? Color.walletAccent : Color.walletSecondary)
                        .background(
                            draft.category == type
                                ? Color.walletHighlight : Color.walletHighlight.opacity(0.2),
                            in: .rect(cornerRadius: 18)
                        )
                        .overlay(alignment: .topTrailing) {
                            if draft.category == type {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                    .padding(9)
                            }
                        }
                    }.buttonStyle(.plain).accessibilityAddTraits(draft.category == type ? [.isSelected] : [])
                        .accessibilityIdentifier("type_\(type.rawValue)")
                }
            }
        }
    }

    private var itemFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            WalletSectionHeader(title: "Items")
            ForEach($draft.items) { $item in
                ReceiptAmountEditor(
                    title: "Item name", name: $item.name,
                    amount: Binding(get: { itemAmounts[item.id] ?? "" }, set: { itemAmounts[item.id] = $0 }),
                    currency: draft.currency
                ) {
                    draft.items.removeAll { $0.id == item.id }
                    itemAmounts[item.id] = nil
                }
                WalletSectionDivider()
            }
            Button {
                draft.items.append(ReceiptItem(name: "", amount: nil))
            } label: {
                Label("Add item", systemImage: "plus").font(.subheadline)
            }
        }
    }

    private var amountFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            WalletSectionHeader(title: "Amounts")
            ForEach($draft.amounts) { $amount in
                ReceiptAmountEditor(
                    title: "Label (e.g. TOTAL)", name: $amount.label,
                    amount: Binding(
                        get: { summaryAmounts[amount.id] ?? "" }, set: { summaryAmounts[amount.id] = $0 }),
                    currency: draft.currency
                ) {
                    draft.amounts.removeAll { $0.id == amount.id }
                    summaryAmounts[amount.id] = nil
                }
            }
            Button {
                draft.amounts.append(ReceiptAmount(label: "", value: nil))
            } label: {
                Label("Add amount", systemImage: "plus").font(.subheadline)
            }
        }
    }

    private func save() {
        guard canSave, !collected else { return }
        draft.date = draft.date ?? .now
        draft.merchant = draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        for index in draft.items.indices {
            draft.items[index].amount = WalletMoney.parse(itemAmounts[draft.items[index].id] ?? "")
        }
        for index in draft.amounts.indices {
            draft.amounts[index].value = WalletMoney.parse(summaryAmounts[draft.amounts[index].id] ?? "")
        }
        do {
            try onSave(draft)
            collected = true
        } catch { self.error = error.localizedDescription }
    }

    private func persistDraftChanges() {
        guard let onDraftChange, isNew, !collected, validAmounts else { return }
        var edited = draft
        for index in edited.items.indices {
            edited.items[index].amount = WalletMoney.parse(itemAmounts[edited.items[index].id] ?? "")
        }
        for index in edited.amounts.indices {
            edited.amounts[index].value = WalletMoney.parse(summaryAmounts[edited.amounts[index].id] ?? "")
        }
        do { try onDraftChange(edited) } catch { self.error = error.localizedDescription }
    }
}

private struct ReceiptAmountEditor: View {
    let title: LocalizedStringKey
    @Binding var name: String
    @Binding var amount: String
    let currency: String
    let remove: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var amountWidth = 110.0

    private var stacksFields: Bool { dynamicTypeSize >= .xxLarge }

    var body: some View {
        HStack(spacing: 10) {
            // AnyLayout preserves the text fields and keyboard focus when the layout changes.
            let layout =
                stacksFields
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 10))
            layout {
                TextField(title, text: $name, axis: .vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text(WalletMoney.symbol(for: currency))
                        .foregroundStyle(Color.walletSecondary)
                        .fixedSize()
                        .accessibilityHidden(true)
                    TextField("Amount", text: $amount)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Amount, \(currency)")
                }
                .monospacedDigit()
                .frame(width: stacksFields ? nil : amountWidth)
                .padding(.vertical, 8)
            }
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Remove \(name)")
        }
        .font(.subheadline)
    }
}

private struct ReceiptCollectionAnimation: View {
    let receipt: SavedReceipt
    let completion: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hole: CGFloat = 0
    @State private var pressed = false
    @State private var tucked = false
    @State private var finished = false

    var body: some View {
        ZStack {
            WalletBackground()
            VStack(spacing: 30) {
                Spacer(minLength: 0)
                ReceiptPaperContent(receipt: receipt, hole: hole, condensed: true, showsPaper: true)
                    .overlay(alignment: .topTrailing) {
                        Circle().stroke(Color.walletAccent.opacity(pressed ? 0 : 0.5), lineWidth: 1.5)
                            .frame(width: pressed ? 54 : 20, height: pressed ? 54 : 20)
                            .position(x: 0, y: 0)
                            .frame(width: 0, height: 0).offset(x: -28, y: 28)
                    }
                    .scaleEffect(tucked ? 0.82 : pressed && !finished ? 0.97 : 1)
                    .rotationEffect(.degrees(tucked && !reduceMotion ? -3 : 0))
                    .opacity(tucked ? 0 : 1).offset(y: tucked && !reduceMotion ? 150 : 0)
                VStack(spacing: 9) {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.title2.weight(.semibold)).foregroundStyle(Color.walletAccent)
                }.opacity(finished ? 1 : 0)
                Spacer(minLength: 0)
            }.padding(30)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Saved")
            .task {
                do {
                    try await Task.sleep(for: .milliseconds(reduceMotion ? 100 : 350))
                    withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.65)) {
                        pressed = true
                        hole = 1
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    try await Task.sleep(for: .milliseconds(250))
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { finished = true }
                    try await Task.sleep(for: .milliseconds(reduceMotion ? 500 : 850))
                    if !reduceMotion {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { tucked = true }
                        try await Task.sleep(for: .milliseconds(400))
                    }
                    completion()
                } catch {}
            }
    }
}
