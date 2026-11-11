import Foundation

nonisolated enum ReceiptModelKind: String, Sendable {
    case text = "NuExtract-1.5-smol-Q4_K_M"
}

nonisolated struct ModelOutput: Sendable {
    let text: String
    let reachedLimit: Bool
    let repetitionDetected: Bool
    let rawText: String?

    init(text: String, reachedLimit: Bool, repetitionDetected: Bool = false, rawText: String? = nil) {
        self.text = text
        self.reachedLimit = reachedLimit
        self.repetitionDetected = repetitionDetected
        self.rawText = rawText
    }
}

nonisolated enum ReceiptStage: String, Sendable, Identifiable, CaseIterable {
    case visionOCR, initialParse, amountRetry, detailParse, detailRetry
    var id: Self { self }
}

nonisolated struct ReceiptStageTiming: Identifiable, Sendable {
    let stage: ReceiptStage
    let seconds: Double
    let completed: Bool
    var id: ReceiptStage { stage }
}

nonisolated struct ReceiptParseResult: Sendable {
    let output: ModelOutput
    let validation: ReceiptValidation
    let evidenceIssues: [String]

    init(_ output: ModelOutput, evidenceIssues: [String] = []) {
        self.output = output
        self.validation = ReceiptValidation.check(output.text)
        self.evidenceIssues = evidenceIssues
    }

    var passed: Bool { validation.passed && issues.isEmpty }
    var issues: [String] {
        validation.issues + evidenceIssues + (output.reachedLimit ? ["Model output reached the token limit."] : [])
            + (output.repetitionDetected ? ["Generation stopped after four consecutive identical items. Verify repeated purchases against the OCR; no items were deduplicated."] : [])
    }
}

nonisolated enum ReceiptPipelineEvent: Sendable {
    case stage(ReceiptStage)
    case timing(ReceiptStageTiming)
    case vision(OCRScan)
    case partial(ReceiptExtractionPart, ModelOutput)
    case initial(ReceiptParseResult)
    case final(ReceiptParseResult)
}

/// Validate each extraction stage and retry that stage at most once. Closures keep routing testable without loading models or using a camera.
@MainActor enum ReceiptPipeline {
    static func run(
        vision: () async throws -> OCRScan,
        load: (ReceiptModelKind) async throws -> Void,
        parse: (OCRScan, ReceiptExtractionPart) async throws -> ModelOutput,
        retry: (OCRScan, ReceiptExtractionPart, String, String) async throws -> ModelOutput,
        emit: (ReceiptPipelineEvent) -> Void
    ) async throws -> ReceiptParseResult {
        func measure<T>(_ stage: ReceiptStage, _ operation: () async throws -> T) async throws -> T {
            try Task.checkCancellation()
            emit(.stage(stage))
            let start = ContinuousClock.now
            var completed = false
            defer {
                let duration = start.duration(to: .now).components
                emit(.timing(.init(stage: stage, seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18, completed: completed)))
            }
            let value = try await operation()
            try Task.checkCancellation()
            completed = true
            return value
        }

        let lines = try await measure(.visionOCR) { try await vision() }
        let hasVisionText = !lines.rows.isEmpty
        emit(.vision(lines))
        var amounts = try await measure(.initialParse) {
            try await load(.text)
            let output = try await parse(lines, .amounts)
            emit(.partial(.amounts, output))
            _ = try ReceiptSchema.decodePart(output, part: .amounts)
            return output
        }
        let firstTotals = try ReceiptSchema.decodePart(amounts, part: .amounts)["totals"] as! [String: Any]
        if let report = ReceiptValidation.totalsReport(firstTotals) {
            amounts = try await measure(.amountRetry) {
                let output = try await retry(lines, .amounts, amounts.text, report)
                emit(.partial(.amounts, output))
                _ = try ReceiptSchema.decodePart(output, part: .amounts)
                return output
            }
        }
        let details = try await measure(.detailParse) {
            let output = try await parse(lines, .details)
            emit(.partial(.details, output))
            _ = try ReceiptSchema.decodePart(output, part: .details)
            return output
        }
        let first = ReceiptParseResult(try ReceiptSchema.merge(amounts: amounts, details: details),
            evidenceIssues: hasVisionText ? [] : ["Vision returned no text; manual review is required."])
        emit(.initial(first))
        let totals = try ReceiptSchema.decodePart(amounts, part: .amounts)["totals"] as! [String: Any]
        let items = try ReceiptSchema.decodePart(details, part: .details)["items"] as! [[String: Any]]
        guard let report = ReceiptValidation.itemsReport(items, totals: totals) else {
            emit(.final(first))
            return first
        }
        let corrected = try await measure(.detailRetry) {
            let output = try await retry(lines, .details, details.text, report)
            emit(.partial(.details, output))
            return ReceiptParseResult(try ReceiptSchema.merge(amounts: amounts, details: output),
                evidenceIssues: hasVisionText ? [] : ["Vision returned no text; manual review is required."])
        }
        emit(.final(corrected))
        return corrected
    }
}
