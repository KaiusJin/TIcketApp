import SwiftUI
import PhotosUI

@MainActor @Observable
final class ReceiptViewModel {
    var isBusy = false
    var status = Strings.ready
    var imageData: Data?
    var preview: UIImage?
    var result = ""
    var elapsed: Double?
    var recognitionStarted: ContinuousClock.Instant?
    var activeStageStarted: ContinuousClock.Instant?
    var error: String?
    var diagnostics = ""
    var stage: ReceiptStage?
    var timings: [ReceiptStageTiming] = []
    var amountJSON = ""
    var settlementText = ""
    var settlementLayoutJSON = ""
    var detailJSON = ""
    var visionText = ""
    var visionScan: OCRScan?
    var visionCoordinates = ""
    var firstParse: ReceiptParseResult?
    var finalParse: ReceiptParseResult?
    private let model = ReceiptModel()
    private let ocr = ReceiptOCR()
    private var task: Task<Void, Never>?
    private var trace: InferenceTrace?

    var canRun: Bool { !isBusy && imageData != nil }

    func timeText(for stage: ReceiptStage) -> String {
        if let timing = timings.first(where: { $0.stage == stage }) {
            return Strings.seconds(timing.seconds) + (timing.completed ? "" : " · \(Strings.interruptedStage)")
        }
        if self.stage == stage, let start = activeStageStarted, recognitionStarted != nil {
            return Strings.seconds(seconds(since: start))
        }
        return elapsed == nil ? "—" : Strings.notRun
    }

    var totalTimeText: String {
        if let start = recognitionStarted { return Strings.seconds(seconds(since: start)) }
        return elapsed.map(Strings.seconds) ?? "—"
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private func resetResult() {
        result = ""
        elapsed = nil
        stage = nil
        timings = []
        activeStageStarted = nil
        amountJSON = ""
        settlementText = ""
        settlementLayoutJSON = ""
        detailJSON = ""
        visionText = ""
        visionScan = nil
        visionCoordinates = ""
        firstParse = nil
        finalParse = nil
    }

    func select(_ item: PhotosPickerItem) {
        guard !isBusy else { return }
        imageData = nil
        preview = nil
        resetResult()
        start(status: Strings.readingImage) {
            InferenceDiagnostics.current?.phase("photo_read")
            guard let data = try await item.loadTransferable(type: Data.self), let preview = UIImage(data: data) else {
                throw ReceiptError.invalidImage
            }
            try Task.checkCancellation()
            self.imageData = data
            self.preview = preview
            InferenceDiagnostics.current?.event("photo_ready bytes=\(data.count) model_data=original")
            self.status = Strings.ready
        }
    }

    func run() {
        guard canRun, let imageData else { return }
        resetResult()
        start(status: Strings.running) {
            InferenceDiagnostics.current?.event("configuration=qwen_selection_ocr_totals max_parse_rounds=2 unknown_amounts=preserve_null money_format=string date_model=nuextract date_input=full_ocr amount_window=last_total_before50_after50 settlement_model=\(ReceiptModelKind.amounts.rawValue) item_model=\(ReceiptModelKind.text.rawValue)")
            let start = ContinuousClock.now
            self.recognitionStarted = start
            defer {
                let duration = start.duration(to: .now).components
                self.elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                self.recognitionStarted = nil
                self.activeStageStarted = nil
                InferenceDiagnostics.current?.event("pipeline_end elapsed_seconds=\(self.elapsed ?? 0)")
            }
            _ = try await ReceiptPipeline.run(
                vision: { try await self.ocr.recognize(imageData) },
                load: { try await self.model.load($0) },
                prepareAmounts: { vision in
                    try await self.model.prepareAmounts(vision: vision) { [weak self] text, detail in
                        self?.receive(text: text, detail: detail)
                    }
                },
                parse: { vision, part in
                    try await self.model.parse(vision: vision, part: part) { [weak self] text, detail in
                        self?.receive(text: text, detail: detail)
                    }
                },
                emit: { self.handle($0) })
            self.status = Strings.completed
        }
    }

    private func receive(text: String?, detail: String) {
        if let text {
            result = text
            if stage == .settlementText { settlementText = text }
        }
        if status != Strings.cancelling {
            status = "\(stage.map(Strings.title) ?? Strings.running) · \(detail)"
        }
    }

    private func handle(_ event: ReceiptPipelineEvent) {
        switch event {
        case .stage(let stage):
            self.stage = stage
            activeStageStarted = .now
            status = Strings.title(stage)
            InferenceDiagnostics.current?.phase(stage.rawValue)
            if stage != .visionOCR { result = "" }
        case .timing(let timing):
            timings.append(timing)
            activeStageStarted = nil
            InferenceDiagnostics.current?.event("stage_end name=\(timing.stage.rawValue) seconds=\(timing.seconds) completed=\(timing.completed)")
        case .vision(let scan):
            visionScan = scan
            visionText = scan.text
            visionCoordinates = (try? scan.evidenceJSON()) ?? ""
        case .settlement(let output):
            settlementText = output.text
        case .settlementLayout(let layout):
            settlementLayoutJSON = (try? layout.evidenceJSON()) ?? ""
            InferenceDiagnostics.current?.event("settlement_layout mapped_rows=\(layout.selectedRowIndices.count) columns=\(layout.columns.count) blocks=\(layout.blocks.count) unresolved=\(layout.unresolved.count)")
        case .partial(let part, let output):
            if part == .amounts {
                amountJSON = output.rawText ?? output.text
            } else {
                detailJSON = output.rawText ?? output.text
            }
        case .initial(let parsed):
            firstParse = parsed
            InferenceDiagnostics.current?.event("first_validation passed=\(parsed.passed) issues=\(parsed.issues.count)")
        case .final(let parsed):
            finalParse = parsed
            result = parsed.validation.formattedJSON ?? parsed.output.text
            InferenceDiagnostics.current?.event("final_validation passed=\(parsed.passed) issues=\(parsed.issues.count)")
        }
    }

    func cancel() {
        guard isBusy else { return }
        trace?.event("cancel_requested")
        task?.cancel()
        status = Strings.cancelling
    }

    func applicationWillResignActive() {
        guard isBusy else { return }
        trace?.event("app_will_resign_active cancel_before_background=true")
        cancel()
    }

    func recordMemoryWarning() { trace?.event("system_memory_warning \(InferenceTrace.memory())") }

    func copyDiagnostics() {
        if let trace { diagnostics = trace.report() }
        UIPasteboard.general.string = diagnostics
    }

    private func start(status: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        self.status = status
        diagnostics = ""
        let trace = InferenceTrace(operation: status)
        self.trace = trace
        task = Task {
            defer { isBusy = false; task = nil; self.trace = nil; diagnostics = trace.report() }
            await InferenceDiagnostics.$current.withValue(trace) {
                do {
                    try await operation()
                    await model.unload()
                    trace.finish("success")
                } catch is CancellationError {
                    await model.unload()
                    trace.finish("cancelled")
                    self.status = Strings.cancelled
                } catch {
                    await model.unload()
                    trace.failure(error)
                    trace.finish("error")
                    self.error = error.localizedDescription
                    self.status = Strings.failed
                }
            }
        }
    }
}

enum Strings {
    static let title = "Receipt Reader"
    static let workflow = "Vision → Checkout text → Totals → Receipt details → Merge"
    static let workflowDetail = "Qwen selects checkout text. Receipt layout pairs totals; NuExtract reads the date, merchant and items. All processing stays on-device."
    static let ready = "Ready"
    static let readingImage = "Reading selected image…"
    static let running = "Recognizing receipt…"
    static let preparing = "Preparing input…"
    static func prefilling(_ count: Int, total: Int) -> String { "Reading evidence · \(count)/\(total) tokens" }
    static func generating(_ count: Int) -> String { "Extracting · \(count) tokens" }
    static let finished = "Stage finished"
    static let completed = "Recognition finished"
    static let select = "Select Image"
    static let run = "Recognize Receipt"
    static let result = "Receipt JSON"
    static let cancel = "Cancel"
    static let cancelling = "Cancelling…"
    static let cancelled = "Cancelled"
    static let failed = "Unable to complete recognition"
    static let placeholder = "Select a receipt to extract its details."
    static let selectedReceipt = "Selected receipt"
    static let totalTime = "Total time"
    static let stageTimes = "Stage timings"
    static let timing = "Each stage includes its model loading and checks."
    static let skipped = "Skipped"
    static let notRun = "Not run"
    static func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }
    static let outputLimit = "The image OCR reached its output limit and may be incomplete."
    static let diagnostics = "Diagnostic log"
    static let copyDiagnostics = "Copy diagnostic log"
    static let evidence = "Recognition evidence"
    static let visionEvidence = "Vision OCR · Reconstructed rows"
    static let visionCoordinates = "OCR coordinates and candidates"
    static let coordinateDescription = "Coordinates are normalized from the bottom-left of the final OCR image. Original observations and the rotation transform are retained below."
    static let retrySeparator = "\n\n--- Retry ---\n"
    static let amountEvidence = "Totals and charges JSON"
    static let settlementEvidence = "Selected checkout text"
    static let settlementLayoutEvidence = "Checkout blocks and amount assignments"
    static let detailEvidence = "Date, merchant and items JSON"
    static let initialJSON = "Initial receipt JSON"
    static let rawJSON = "Merged receipt JSON"
    static let interruptedStage = "Interrupted"
    static func title(_ stage: ReceiptStage) -> String {
        switch stage {
        case .visionOCR: "1. VISION"
        case .settlementText: "2. Checkout text"
        case .initialParse: "3. Totals from layout"
        case .detailParse: "4. Date, merchant and items"
        }
    }
}
