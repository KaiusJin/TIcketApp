import Foundation
import Observation

/// App-owned recognition queue. Leaving a capture screen does not discard its work.
@MainActor @Observable
final class ReceiptCaptureModel {
    private(set) var activeReceiptID: UUID?
    private(set) var status = "Waiting to read…"
    private(set) var completedStages = 0
    private let store: WalletStore
    private let model = ReceiptModel()
    private let ocr = ReceiptOCR()
    private var queue: [UUID] = []
    private var task: Task<Void, Never>?
    private var isActive = false
    private var visionText = ""

    init(store: WalletStore) { self.store = store }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            // Retry each unfinished draft at most once per foreground session.
            let pending = store.receipts.filter {
                ($0.status == .processing || $0.status == .failed) && $0.imageFilename != nil
            }
            for draft in pending where !queue.contains(draft.id) {
                queue.append(draft.id)
            }
            runNext()
        } else {
            task?.cancel()
            if let id = activeReceiptID, store.receipt(id: id)?.status == .processing {
                do {
                    try store.changeProcessingState(
                        id: id, status: .processing,
                        message: "Reading paused. It will resume when you return to the app.")
                } catch { store.error = error.localizedDescription }
            }
        }
    }

    func enqueue(_ receiptID: UUID) {
        guard !queue.contains(receiptID), activeReceiptID != receiptID else { return }
        queue.append(receiptID)
        runNext()
    }

    func retry(_ receiptID: UUID) {
        guard activeReceiptID != receiptID else { return }
        do {
            try store.changeProcessingState(id: receiptID, status: .processing, message: nil)
            enqueue(receiptID)
        } catch { store.error = error.localizedDescription }
    }

    func cancel(_ receiptID: UUID) {
        queue.removeAll { $0 == receiptID }
        if activeReceiptID == receiptID { task?.cancel() }
        do {
            try store.changeProcessingState(
                id: receiptID, status: .cancelled,
                message: "Reading cancelled. You can retry or edit this draft.")
        } catch { store.error = error.localizedDescription }
    }

    private func runNext() {
        guard isActive, task == nil else { return }
        queue = queue.filter { id in
            guard let draft = store.receipt(id: id) else { return false }
            return (draft.status == .processing || draft.status == .failed) && draft.imageFilename != nil
        }.sorted {
            (store.receipt(id: $0)?.createdAt ?? .distantFuture)
                < (store.receipt(id: $1)?.createdAt ?? .distantFuture)
        }
        while let id = queue.first {
            queue.removeFirst()
            do {
                let draft = try store.beginProcessing(id: id)
                guard let imageURL = store.imageURL(for: draft) else { throw ReceiptError.invalidImage }
                activeReceiptID = id
                completedStages = 0
                status = "Reading receipt…"
                visionText = ""
                task = Task { await process(id: id, imageURL: imageURL) }
                return
            } catch {
                store.error = error.localizedDescription
                do {
                    try store.changeProcessingState(
                        id: id, status: .failed, message: error.localizedDescription)
                } catch { store.error = error.localizedDescription }
            }
        }
    }

    private func process(id: UUID, imageURL: URL) async {
        let trace = InferenceTrace(operation: "Read saved receipt draft")
        defer {
            task = nil
            activeReceiptID = nil
            if isActive { runNext() }
        }
        await InferenceDiagnostics.$current.withValue(trace) {
            do {
                let imageData = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: imageURL)
                }.value
                try Task.checkCancellation()
                let result = try await ReceiptPipeline.run(
                    vision: { try await self.ocr.recognize(imageData) },
                    load: { try await self.model.load($0) },
                    prepareAmounts: { scan in
                        try await self.model.prepareAmounts(vision: scan) { [weak self] _, detail in
                            self?.status = detail
                        }
                    },
                    parse: { scan, part in
                        try await self.model.parse(vision: scan, part: part) { [weak self] _, detail in
                            self?.status = detail
                        }
                    },
                    emit: { self.receive($0) })
                await model.unload()
                try Task.checkCancellation()
                guard isActive else { throw CancellationError() }
                try store.finishProcessing(id: id, result: result, originalText: visionText)
                completedStages = 5
                trace.finish("success")
            } catch is CancellationError {
                await model.unload()
                trace.finish("cancelled")
            } catch {
                await model.unload()
                trace.failure(error)
                trace.finish("error")
                guard !Task.isCancelled else { return }
                do {
                    try store.changeProcessingState(
                        id: id, status: .failed, message: error.localizedDescription)
                } catch { store.error = error.localizedDescription }
            }
        }
    }

    private func receive(_ event: ReceiptPipelineEvent) {
        switch event {
        case .stage(let stage):
            switch stage {
            case .visionOCR: status = "Reading receipt text…"
            case .settlementText: status = "Finding checkout amounts…"
            case .initialParse: status = "Checking amounts…"
            case .detailParse: status = "Reading store and items…"
            }
            InferenceDiagnostics.current?.phase(stage.rawValue)
        case .timing(let timing):
            if timing.completed { completedStages += 1 }
            InferenceDiagnostics.current?.event(
                "stage_end name=\(timing.stage.rawValue) seconds=\(timing.seconds) completed=\(timing.completed)"
            )
        case .vision(let scan): visionText = scan.text
        case .settlement, .settlementLayout, .partial, .initial, .final: break
        }
    }
}
