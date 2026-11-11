import SwiftUI

struct ReceiptDetailView: View {
    let store: WalletStore
    let processor: ReceiptCaptureModel
    let receipt: SavedReceipt
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SavedReceipt?
    @State private var showOriginal = false
    @State private var confirmDelete = false
    @State private var error: String?
    private var current: SavedReceipt { store.receipts.first(where: { $0.id == receipt.id }) ?? receipt }

    var body: some View {
        Group {
            if let onClose {
                VStack(spacing: 16) {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "chevron.up").frame(width: 44, height: 44)
                        }.buttonStyle(.plain).walletGlass(radius: 22, interactive: true)
                            .accessibilityLabel("Close")
                        Spacer()
                        receiptActions
                    }
                    detailContents
                }.foregroundStyle(Color.walletInk)
            } else {
                ScrollView { detailContents.padding(24) }
                    .scrollIndicators(.hidden).walletPage()
                    .navigationTitle("Receipt").navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) { receiptActions }
                    }
            }
        }
        .sheet(item: $editing) { draft in
            NavigationStack {
                ReceiptEditorView(
                    receipt: draft, imageURL: store.imageURL(for: draft),
                    onSave: { try store.save($0) }, onDraftChange: { try store.saveDraftEdits($0) })
            }
        }
        .sheet(isPresented: $showOriginal) { OriginalReceiptView(imageURL: store.imageURL(for: current)) }
        .confirmationDialog("Delete this receipt?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete receipt", role: .destructive) {
                do {
                    processor.cancel(current.id)
                    try store.delete(current)
                    if let onClose { onClose() } else { dismiss() }
                } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("The receipt and its original photo will be removed from this iPhone.")
        }
        .alert(
            "Couldn't update your wallet",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var receiptActions: some View {
        HStack(spacing: 4) {
            Button {
                store.toggleFavorite(current)
            } label: {
                Image(systemName: current.isFavorite ? "bookmark.fill" : "bookmark").frame(
                    width: 44, height: 44)
            }.accessibilityLabel(current.isFavorite ? "Remove from favorites" : "Save to favorites")
            if current.imageFilename != nil {
                Button {
                    showOriginal = true
                } label: {
                    Image(systemName: "doc.viewfinder").frame(width: 44, height: 44)
                }.accessibilityLabel("Original receipt")
                    .accessibilityIdentifier("originalReceipt")
            }
            Button {
                openEditor()
            } label: {
                Image(systemName: "pencil").frame(width: 44, height: 44)
            }.accessibilityLabel("Edit").accessibilityIdentifier("editReceipt")
                .disabled(current.status == .processing)
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash").foregroundStyle(.red).frame(width: 44, height: 44)
            }.accessibilityLabel("Delete receipt").accessibilityIdentifier("deleteReceipt")
        }.font(.subheadline)
    }

    private var detailContents: some View {
        VStack(spacing: 16) {
            if current.status != .completed { draftActions }
            ReceiptPaperContent(receipt: current)
            if current.total == nil {
                Label(
                    "Confirm the total to include this receipt in Insights.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption).foregroundStyle(Color.walletSecondary)
            } else if !current.reviewNotes.isEmpty {
                Label("Check the amounts against the photo.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Color.walletSecondary)
            }
        }
    }

    private var draftActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.status.title).font(.headline)
            if current.status == .processing {
                if processor.activeReceiptID == current.id {
                    ProgressView(value: Double(processor.completedStages), total: 5)
                    Text(processor.status).font(.subheadline).foregroundStyle(Color.walletSecondary)
                } else {
                    ProgressView("Waiting to read…")
                }
                Button("Cancel reading") { processor.cancel(current.id) }
            } else {
                if let message = current.processingError {
                    Text(message).font(.subheadline).foregroundStyle(Color.walletSecondary)
                }
                Button("Review and save", action: openEditor).buttonStyle(WalletPrimaryButton())
                if current.imageFilename != nil, current.status == .failed || current.status == .cancelled {
                    Button("Read again") { processor.retry(current.id) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openEditor() {
        do { editing = try store.prepareForReview(id: current.id) } catch {
            self.error = error.localizedDescription
        }
    }
}
