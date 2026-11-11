import Foundation

nonisolated enum ReceiptModelKind: String, Sendable {
    case text = "NuExtract-1.5-smol-Q4_K_M"
    case amounts = "Qwen_Qwen3-0.6B-Q4_K_M"
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
    case visionOCR, settlementText, initialParse, detailParse
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
    case settlement(ModelOutput)
    case settlementLayout(OCRSettlementLayout)
    case partial(ReceiptExtractionPart, ModelOutput)
    case initial(ReceiptParseResult)
    case final(ReceiptParseResult)
}

/// Qwen selects checkout text; source OCR geometry produces totals directly.
/// Uncertain mappings remain review issues, never a reason to invent amounts.
@MainActor enum ReceiptPipeline {
    static func run(
        vision: () async throws -> OCRScan,
        load: (ReceiptModelKind) async throws -> Void,
        prepareAmounts: (OCRScan) async throws -> ModelOutput,
        parse: (OCRScan, ReceiptExtractionPart) async throws -> ModelOutput,
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
        guard lines.amountText != nil else { throw ReceiptError.missingTotalsAnchor }
        let settlement = try await measure(.settlementText) {
            try await load(.amounts)
            let output = try await prepareAmounts(lines)
            emit(.settlement(output))
            guard !output.reachedLimit, !output.repetitionDetected,
                  !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReceiptError.invalidSettlementText
            }
            return output.text
        }
        let layout = try await measure(.initialParse) {
            let layout = OCRSettlementLayout.reconstruct(scan: lines, selectedText: settlement)
            emit(.settlementLayout(layout))
            let output = try layout.output()
            emit(.partial(.amounts, output))
            _ = try ReceiptSchema.decodePart(output, part: .amounts)
            return layout
        }
        let amounts = try layout.output()
        let details = try await measure(.detailParse) {
            try await load(.text)
            let output = try await parse(lines, .details)
            emit(.partial(.details, output))
            _ = try ReceiptSchema.decodePart(output, part: .details)
            return output
        }
        let first = ReceiptParseResult(try ReceiptSchema.merge(amounts: amounts, details: details),
            evidenceIssues: layout.issues + (hasVisionText ? [] : ["Vision returned no text; manual review is required."]))
        emit(.initial(first))
        emit(.final(first))
        return first
    }
}
