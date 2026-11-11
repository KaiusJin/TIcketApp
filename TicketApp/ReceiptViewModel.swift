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
    var notices: [String] = []
    var diagnostics = ""
    var stage: ReceiptStage?
    var timings: [ReceiptStageTiming] = []
    var amountJSON = ""
    var detailJSON = ""
    var visionText = ""
    var visionScan: OCRScan?
    var visionCoordinates = ""
    var firstParse: ReceiptParseResult?
    var finalParse: ReceiptParseResult?
    var manualDraft = "" {
        didSet { manualValidation = nil }
    }
    var manualValidation: ReceiptValidation?
    private let model = ReceiptModel()
    private let ocr = ReceiptOCR()
    private var task: Task<Void, Never>?
    private var trace: InferenceTrace?

    var canRun: Bool { !isBusy && imageData != nil }
    var needsManualReview: Bool {
        !isBusy && (finalParse.map { !$0.passed } ?? (error != nil && visionScan != nil))
    }

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

    func validateManualDraft() {
        guard needsManualReview else { return }
        manualValidation = ReceiptValidation.check(manualDraft)
    }

    private func resetResult() {
        result = ""
        elapsed = nil
        stage = nil
        timings = []
        activeStageStarted = nil
        amountJSON = ""
        detailJSON = ""
        visionText = ""
        visionScan = nil
        visionCoordinates = ""
        firstParse = nil
        finalParse = nil
        manualDraft = ""
        manualValidation = nil
        notices = []
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
            InferenceDiagnostics.current?.event("configuration=vision_text_amount_retry max_parse_rounds=4 unknown_amounts=review money_format=string text_model=\(ReceiptModelKind.text.rawValue)")
            let start = ContinuousClock.now
            self.recognitionStarted = start
            defer {
                let duration = start.duration(to: .now).components
                self.elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                self.recognitionStarted = nil
                self.activeStageStarted = nil
                InferenceDiagnostics.current?.event("pipeline_end elapsed_seconds=\(self.elapsed ?? 0)")
            }
            let final = try await ReceiptPipeline.run(
                vision: { try await self.ocr.recognize(imageData) },
                load: { try await self.model.load($0) },
                parse: { vision, part in
                    try await self.model.parse(vision: vision, part: part) { [weak self] text, detail in
                        self?.receive(text: text, detail: detail)
                    }
                },
                retry: { scan, part, previousJSON, report in
                    try await self.model.retryExtraction(vision: scan, part: part, previousJSON: previousJSON, report: report) { [weak self] text, detail in
                        self?.receive(text: text, detail: detail)
                    }
                },
                emit: { self.handle($0) })
            self.status = final.passed ? Strings.passed : Strings.manualReview
        }
    }

    private func receive(text: String?, detail: String) {
        if let text { result = text }
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
            if scan.rows.isEmpty { notices.append(Strings.emptyVision) }
            if let geometry = scan.geometry {
                switch geometry.status {
                case .insufficientEvidence: notices.append(Strings.uncertainDirection)
                case .recognitionFallback: notices.append(Strings.deskewFallback)
                case .corrected, .alreadyAligned: break
                }
            }
        case .partial(let part, let output):
            if part == .amounts {
                amountJSON += (amountJSON.isEmpty ? "" : Strings.retrySeparator) + (output.rawText ?? output.text)
            } else {
                detailJSON += (detailJSON.isEmpty ? "" : Strings.retrySeparator) + (output.rawText ?? output.text)
            }
        case .initial(let parsed):
            firstParse = parsed
            manualDraft = parsed.validation.formattedJSON ?? parsed.output.text
            InferenceDiagnostics.current?.event("first_validation passed=\(parsed.passed) issues=\(parsed.issues.count)")
        case .final(let parsed):
            finalParse = parsed
            result = parsed.validation.formattedJSON ?? parsed.output.text
            manualDraft = result
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
                    if self.visionScan != nil { self.notices.append(Strings.manualReview) }
                    if self.manualDraft.isEmpty { self.manualDraft = self.result }
                }
            }
        }
    }
}

enum Strings {
    static let title = "Receipt Reader"
    static let workflow = "Vision → Totals → Items → Merge"
    static let workflowDetail = "On-device NuExtract extracts totals and items. Each step can retry once before merging."
    static let ready = "Ready"
    static let readingImage = "Reading selected image…"
    static let running = "Recognizing receipt…"
    static let preparing = "Preparing input…"
    static func prefilling(_ count: Int, total: Int) -> String { "Reading evidence · \(count)/\(total) tokens" }
    static func generating(_ count: Int) -> String { "Extracting · \(count) tokens" }
    static let finished = "Stage finished"
    static let passed = "Amount checks passed"
    static let manualReview = "Manual review required"
    static let manualDraft = "Manual corrections"
    static let manualInstructions = "Compare with the receipt, edit this JSON and check it again. Original model outputs remain below. Corrections are kept on this page only."
    static let checkCorrections = "Check corrections"
    static let correctionPassed = "Corrected JSON passes amount checks"
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
    static let emptyVision = "Vision returned no text. Please retry or review manually."
    static let outputLimit = "The image OCR reached its output limit and may be incomplete."
    static let diagnostics = "Diagnostic log"
    static let copyDiagnostics = "Copy diagnostic log"
    static let evidence = "Recognition evidence"
    static let visionEvidence = "Vision OCR · Reconstructed rows"
    static let visionCoordinates = "OCR coordinates and candidates"
    static let coordinateDescription = "Coordinates are normalized from the bottom-left of the final OCR image. Original observations and the rotation transform are retained below."
    static let uncertainDirection = "Not enough consistent text to straighten the receipt. Original image used; check row alignment."
    static let deskewFallback = "OCR returned no text after straightening. Original scan retained for review."
    static let retrySeparator = "\n\n--- Retry ---\n"
    static let amountEvidence = "Totals and charges JSON"
    static let detailEvidence = "Merchant and items JSON"
    static let initialJSON = "First JSON and checks"
    static let rawJSON = "Merged receipt JSON"
    static let checks = "Validation issues"
    static let arithmeticNotice = "Balanced amounts do not guarantee that every receipt detail was recognized correctly."
    static let interruptedStage = "Interrupted"
    static func title(_ stage: ReceiptStage) -> String {
        switch stage {
        case .visionOCR: "1. VISION"
        case .initialParse: "2. Totals and charges"
        case .detailParse: "3. Merchant and items"
        case .amountRetry: "Totals correction"
        case .detailRetry: "Item correction"
        }
    }
}
