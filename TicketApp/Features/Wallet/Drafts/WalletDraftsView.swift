import SwiftUI

struct WalletDraftsView: View {
    let store: WalletStore
    let processor: ReceiptCaptureModel
    @Environment(\.dismiss) private var dismiss

    private var drafts: [SavedReceipt] {
        store.receipts.filter { $0.status != .completed }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if drafts.isEmpty {
                        WalletEmptyState(icon: "tray", title: "No drafts")
                    } else {
                        ForEach(drafts) { draft in
                            NavigationLink(value: draft.id) {
                                VStack(alignment: .leading, spacing: 10) {
                                    AdaptiveValueRow {
                                        Text(draft.displayMerchant).font(.headline)
                                    } value: {
                                        Text(draft.status.title).font(.caption).foregroundStyle(
                                            Color.walletAccent)
                                    }
                                    Text(draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(Color.walletSecondary)
                                    if draft.status == .processing {
                                        if processor.activeReceiptID == draft.id {
                                            ProgressView(value: Double(processor.completedStages), total: 5)
                                            Text(processor.status).font(.caption).foregroundStyle(
                                                Color.walletSecondary)
                                        } else {
                                            Text("Waiting to read…").font(.caption).foregroundStyle(
                                                Color.walletSecondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18).walletGlass(radius: 22)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("draft_\(draft.id.uuidString)")
                        }
                    }
                }.padding(24)
            }
            .scrollIndicators(.hidden).walletPage()
            .navigationTitle("Drafts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: UUID.self) { id in
                if let draft = store.receipt(id: id) {
                    ReceiptDetailView(store: store, processor: processor, receipt: draft)
                }
            }
        }
    }
}
