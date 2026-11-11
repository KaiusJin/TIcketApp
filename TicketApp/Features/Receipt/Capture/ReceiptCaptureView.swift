import AVFoundation
import PhotosUI
import SwiftUI

struct ReceiptCaptureView: View {
    let store: WalletStore
    let processor: ReceiptCaptureModel
    @State private var selection: PhotosPickerItem?
    @State private var showCamera = false
    @State private var cameraError: String?
    @State private var cameraDenied = false
    @State private var receiptID: UUID?
    @State private var showingReview = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var preview: UIImage?
    @State private var pendingImageData: Data?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var draft: SavedReceipt? { receiptID.flatMap { store.receipt(id: $0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 280)
                            .frame(maxWidth: .infinity).accessibilityLabel("Original receipt")
                    } else {
                        Image(systemName: "doc.viewfinder").font(.system(size: 64, weight: .ultraLight))
                            .foregroundStyle(Color.walletAccent).frame(maxWidth: .infinity).frame(height: 200)
                            .accessibilityHidden(true)
                    }
                    if isImporting { ProgressView("Opening your photo…") }
                    if let pendingImageData, let preview {
                        Button("Retry saving draft") { persistPhoto(pendingImageData, preview: preview) }
                            .buttonStyle(WalletPrimaryButton())
                    }
                    if let draft, draft.status != .completed {
                        Button("Open draft") { showingReview = true }.buttonStyle(WalletPrimaryButton())
                    }
                    inputOptions.disabled(isImporting)
                }.padding(26)
            }
            .scrollIndicators(.hidden).walletPage()
            .navigationTitle("Add receipt").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(isImporting)
                }
            }
            .navigationDestination(isPresented: $showingReview) {
                if let draft {
                    Group {
                        if draft.status == .processing {
                            ReceiptLoadingView(
                                status: processor.activeReceiptID == draft.id
                                    ? processor.status : "Waiting to read…",
                                progress: processor.activeReceiptID == draft.id
                                    ? Double(processor.completedStages) / 5 : nil,
                                cancel: { processor.cancel(draft.id) }, close: { dismiss() })
                        } else if draft.status == .needsReview || draft.status == .completed {
                            ReceiptEditorView(
                                receipt: draft, imageURL: store.imageURL(for: draft),
                                onSave: { try store.save($0) },
                                onDraftChange: { try store.saveDraftEdits($0) }, onFinished: { dismiss() })
                        } else {
                            ReceiptDetailView(store: store, processor: processor, receipt: draft)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: draft.status)
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            ReceiptCamera { image in
                showCamera = false
                guard let image else { return }
                guard let data = image.jpegData(compressionQuality: 0.95) else {
                    importError = ReceiptError.invalidImage.localizedDescription
                    return
                }
                persistPhoto(data, preview: image)
            }.ignoresSafeArea()
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            isImporting = true
            Task { await importPhoto(item) }
        }
        .interactiveDismissDisabled(isImporting)
        .alert(
            "Add receipt",
            isPresented: Binding(get: { cameraError != nil }, set: { if !$0 { cameraError = nil } })
        ) {
            if cameraDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) { cameraError = nil }
        } message: {
            Text(cameraError ?? "")
        }
        .alert(
            "Couldn't save this draft",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var inputOptions: some View {
        VStack(spacing: 14) {
            Button {
                Task { await openCamera() }
            } label: {
                Label("Take photo", systemImage: "camera")
            }.buttonStyle(WalletPrimaryButton()).accessibilityIdentifier("takeReceiptPhoto")
            PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                Label("Photo library", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 18)
                    .walletGlass(radius: 28)
            }.accessibilityIdentifier("importReceiptPhoto")
            Button("Enter manually") {
                do {
                    let draft = try store.createDraft()
                    receiptID = draft.id
                    preview = nil
                    pendingImageData = nil
                    showingReview = true
                } catch { importError = error.localizedDescription }
            }.font(.subheadline).padding(.top, 7).accessibilityIdentifier("manualReceipt")
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { isImporting = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data)
            else {
                throw ReceiptError.invalidImage
            }
            persistPhoto(data, preview: image)
        } catch { importError = error.localizedDescription }
    }

    private func persistPhoto(_ data: Data, preview: UIImage) {
        self.preview = preview
        receiptID = nil
        pendingImageData = data
        do {
            let draft = try store.createDraft(imageData: data)
            pendingImageData = nil
            receiptID = draft.id
            showingReview = true
            processor.enqueue(draft.id)
        } catch { importError = error.localizedDescription }
    }

    private func openCamera() async {
        cameraDenied = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraError = "The camera isn't available. You can choose a photo or enter a receipt manually."
            return
        }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        if allowed {
            showCamera = true
        } else {
            cameraDenied = true
            cameraError = "Allow camera access in Settings to photograph a receipt."
        }
    }
}

private struct ReceiptLoadingView: View {
    let status: String
    let progress: Double?
    let cancel: () -> Void
    let close: () -> Void
    @ScaledMetric(relativeTo: .caption) private var categoryWidth = 96.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(status).font(.subheadline).foregroundStyle(Color.walletSecondary)
                if let progress { ProgressView(value: progress) } else { ProgressView() }
                receiptFields
                WalletSectionDivider()
                categoryFields
                WalletSectionDivider()
                itemFields
                WalletSectionDivider()
                amountFields
            }
            .padding(24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status)
        }
        .scrollIndicators(.hidden).walletPage()
        .navigationTitle("Review receipt").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            ToolbarItem(placement: .confirmationAction) { Button("Close", action: close) }
        }
        .safeAreaInset(edge: .bottom) {
            ReceiptSkeletonBlock(height: 56, radius: 28)
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12)
                .background(.regularMaterial)
                .accessibilityHidden(true)
        }
    }

    private var receiptFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReceiptSkeletonBlock(width: 180, height: 28)
            WalletSectionDivider()
            HStack {
                ReceiptSkeletonBlock(width: 100, height: 18)
                Spacer()
                ReceiptSkeletonBlock(width: 120, height: 34)
            }
            HStack {
                ReceiptSkeletonBlock(width: 72, height: 18)
                Spacer()
                ReceiptSkeletonBlock(width: 64, height: 28)
            }
        }
    }

    private var categoryFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReceiptSkeletonBlock(width: 60, height: 22)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: categoryWidth), spacing: 10)], spacing: 10) {
                ForEach(ReceiptCategory.allCases) { _ in
                    ReceiptSkeletonBlock(height: 84, radius: 18)
                }
            }
        }
    }

    private var itemFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReceiptSkeletonBlock(width: 70, height: 23)
            ForEach(0..<3) { _ in
                amountRow
                WalletSectionDivider()
            }
            ReceiptSkeletonBlock(width: 100, height: 20)
        }
    }

    private var amountFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReceiptSkeletonBlock(width: 100, height: 23)
            ForEach(0..<2) { _ in amountRow }
            ReceiptSkeletonBlock(width: 120, height: 20)
        }
    }

    private var amountRow: some View {
        HStack(spacing: 10) {
            ReceiptSkeletonBlock(height: 18)
            Spacer(minLength: 12)
            ReceiptSkeletonBlock(width: 110, height: 34)
            ReceiptSkeletonBlock(width: 24, height: 24, radius: 12)
        }.frame(minHeight: 44)
    }
}

private struct ReceiptSkeletonBlock: View {
    var width: CGFloat? = nil
    let height: CGFloat
    var radius: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var shimmering = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Color(uiColor: .systemGray5))
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, .white.opacity(colorScheme == .dark ? 0.12 : 0.6), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.65)
                        .offset(x: shimmering ? geometry.size.width : -geometry.size.width * 0.65)
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(.rect(cornerRadius: radius))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: reduceMotion) {
                shimmering = false
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmering = true
                }
            }
    }
}

private struct ReceiptCamera: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            completion(info[.originalImage] as? UIImage)
        }
    }
}
