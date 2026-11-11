import Foundation
import LlamaSwift

/// Serial ownership of llama.cpp weights. Each pass gets a new context and grammar
/// matcher; KV state and accepted tokens never leak into another receipt or retry.
actor ReceiptModel {
    private var weights: NuExtractWeights?
    private var generating = false
    private let modelURL: URL?

    init(modelURL: URL? = nil) { self.modelURL = modelURL }

    func load(_ kind: ReceiptModelKind) async throws {
        guard !generating else { throw ReceiptError.modelBusy }
        try Task.checkCancellation()
        if weights != nil { return }
        let url = modelURL ?? Bundle.main.url(forResource: kind.rawValue, withExtension: "gguf")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { throw ReceiptError.missingTextModel }
        InferenceDiagnostics.current?.phase("model_load")
        let loaded = try NuExtractWeights(url: url)
        try Task.checkCancellation()
        weights = loaded
        InferenceDiagnostics.current?.event("model_loaded=\(kind.rawValue) backend=llama.cpp execution=on_device")
    }

    func unload() {
        guard !generating else { return }
        weights = nil
    }

    func parse(vision: OCRScan, part: ReceiptExtractionPart, update: @escaping @MainActor @Sendable (String?, String) -> Void) async throws -> ModelOutput {
        try await generate(prompt: NuExtractSchema.prompt(vision: vision, part: part), part: part, update: update)
    }

    func retryExtraction(vision: OCRScan, part: ReceiptExtractionPart, previousJSON: String, report: String,
                         update: @escaping @MainActor @Sendable (String?, String) -> Void) async throws -> ModelOutput {
        try await generate(prompt: NuExtractSchema.prompt(vision: vision, part: part, report: report), part: part, update: update)
    }

    private func generate(prompt: String, part: ReceiptExtractionPart,
                          update: @escaping @MainActor @Sendable (String?, String) -> Void) async throws -> ModelOutput {
        guard !generating else { throw ReceiptError.modelBusy }
        guard let weights else { throw ReceiptError.missingTextModel }
        try Task.checkCancellation()
        generating = true
        defer { generating = false }
        let signal = NuExtractCancellation()
        return try await withTaskCancellationHandler {
            let trace = InferenceDiagnostics.current
            trace?.beginGeneration(model: ReceiptModelKind.text.rawValue)
            trace?.phase("input_prepare")
            await update(nil, Strings.preparing)
            let vocab = llama_model_get_vocab(weights.pointer)!
            let tokens = try NuExtractTokens.tokenize(prompt, vocab: vocab)
            // Limit KV memory on phones. Reserve output space explicitly, with no
            // prompt truncation or sliding-window loss of earlier receipt rows.
            let contextLimit = min(8192, Int(llama_model_n_ctx_train(weights.pointer)))
            let outputLimit = min(4096, contextLimit / 2)
            guard tokens.count <= contextLimit - outputLimit else { throw ReceiptError.inputTooLong }
            // Preserve the same input/output budgets without reserving an unused
            // 8192-position KV cache for every short receipt on an iPhone.
            let contextSize = min(contextLimit, ((tokens.count + outputLimit + 255) / 256) * 256)
            var parameters = llama_context_default_params()
            parameters.n_ctx = UInt32(contextSize)
            parameters.n_batch = 128
            parameters.n_ubatch = 128
            parameters.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1)))
            parameters.n_threads_batch = parameters.n_threads
            parameters.abort_callback = { opaque in
                guard let opaque else { return false }
                return Unmanaged<NuExtractCancellation>.fromOpaque(opaque).takeUnretainedValue().isCancelled
            }
            parameters.abort_callback_data = Unmanaged.passUnretained(signal).toOpaque()
            trace?.event("context_create_begin positions=\(contextSize) \(InferenceTrace.memory())")
            guard let context = llama_init_from_model(weights.pointer, parameters) else { throw ReceiptError.modelLoadFailed }
            defer {
                llama_synchronize(context)
                llama_free(context)
            }
            trace?.event("context_create_end \(InferenceTrace.memory())")
            guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw ReceiptError.guidedGenerationFailed }
            defer { llama_sampler_free(sampler) }
            guard let grammar = llama_sampler_init_grammar(vocab, try NuExtractSchema.grammar(for: part), "root") else { throw ReceiptError.guidedGenerationFailed }
            llama_sampler_chain_add(sampler, grammar)
            guard let greedy = llama_sampler_init_greedy() else { throw ReceiptError.guidedGenerationFailed }
            llama_sampler_chain_add(sampler, greedy)
            var batch = llama_batch_init(128, 0, 1)
            defer { llama_batch_free(batch) }
            trace?.event("prompt_tokens=\(tokens.count) context=\(contextSize) output_limit=\(outputLimit) grammar=gbnf sampling=greedy")
            trace?.phase("prefill")
            for start in stride(from: 0, to: tokens.count, by: 128) {
                try Task.checkCancellation()
                let end = min(start + 128, tokens.count)
                NuExtractTokens.fill(&batch, tokens: tokens[start..<end], position: start, finalLogits: end == tokens.count)
                let status = llama_decode(context, batch)
                try Task.checkCancellation()
                guard status == 0 else { throw ReceiptError.modelDecodeFailed }
                await update(nil, Strings.prefilling(end, total: tokens.count))
            }
            trace?.phase("decode")
            var bytes: [UInt8] = []
            var result = ""
            var boundary = JSONObjectBoundary()
            var monitor = ReceiptOutputMonitor()
            var stopped = false
            var repetition = false
            var count = 0
            var lastUpdate = ContinuousClock.now
            while count < outputLimit {
                try Task.checkCancellation()
                let token = llama_sampler_sample(sampler, context, -1)
                guard token >= 0 else { throw ReceiptError.modelDecodeFailed }
                if llama_vocab_is_eog(vocab, token) { stopped = true; break }
                count += 1
                trace?.receivedToken(Int(token))
                bytes.append(contentsOf: try NuExtractTokens.piece(token, vocab: vocab))
                // A UTF-8 code point can span multiple tokens. Never introduce a
                // replacement character merely because the current chunk is short.
                if let text = String(bytes: bytes, encoding: .utf8) {
                    bytes.removeAll(keepingCapacity: true)
                    result += text
                    boundary.append(text)
                    monitor.append(text)
                    trace?.decodedText(text, boundary: boundary)
                    if boundary.complete { stopped = true; break }
                    if monitor.shouldStop { repetition = true; break }
                }
                if count == 1 || lastUpdate.duration(to: .now) >= .milliseconds(250) {
                    await update(result, Strings.generating(count))
                    lastUpdate = .now
                }
                NuExtractTokens.fill(&batch, tokens: [token][...], position: tokens.count + count - 1, finalLogits: true)
                let status = llama_decode(context, batch)
                try Task.checkCancellation()
                guard status == 0 else { throw ReceiptError.modelDecodeFailed }
            }
            try Task.checkCancellation()
            await update(result, Strings.finished)
            guard bytes.isEmpty else { throw ReceiptError.guidedGenerationFailed }
            let raw = ModelOutput(text: result, reachedLimit: !stopped && count >= outputLimit, repetitionDetected: repetition)
            trace?.event("generation_end tokens=\(count) complete=\(boundary.complete) limit=\(raw.reachedLimit) repetition=\(repetition)")
            // On failure the UI retains the raw preview; only a complete, valid
            // extraction is adapted and allowed to enter the amount checks.
            trace?.phase("output_validation")
            let normalized: ModelOutput
            do {
                normalized = try NuExtractSchema.normalize(raw, part: part)
            } catch {
                trace?.event("output_validation_failed part=\(part.rawValue) bytes=\(raw.text.utf8.count)")
                throw error
            }
            try Task.checkCancellation()
            await update(normalized.text, Strings.finished)
            return normalized
        } onCancel: {
            signal.cancel()
        }
    }
}

nonisolated private final class NuExtractWeights {
    let pointer: OpaquePointer
    private static let backend: Void = {
        // Native diagnostics may include token strings. Use our content-free log.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    init(url: URL) throws {
        _ = Self.backend
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = -1
        guard let pointer = llama_model_load_from_file(url.path, parameters) else { throw ReceiptError.modelLoadFailed }
        self.pointer = pointer
    }

    deinit { llama_model_free(pointer) }
}

nonisolated private final class NuExtractCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

nonisolated enum NuExtractTokens {
    static func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        // Tokenize the literal NuExtract markers using the model vocabulary and
        // model-defined BOS convention. No chat template is applied.
        var tokens = [llama_token](repeating: 0, count: text.utf8.count + 8)
        var count = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, Int32(tokens.count), true, true)
        }
        guard count > 0 else { throw ReceiptError.invalidModelInput }
        return Array(tokens.prefix(Int(count)))
    }

    static func piece(_ token: llama_token, vocab: OpaquePointer) throws -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 128)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard count >= 0 else { throw ReceiptError.modelDecodeFailed }
        return buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }

    static func fill(_ batch: inout llama_batch, tokens: ArraySlice<llama_token>, position: Int, finalLogits: Bool) {
        batch.n_tokens = Int32(tokens.count)
        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = Int32(position + index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index]![0] = 0
            batch.logits[index] = finalLogits && index == tokens.count - 1 ? 1 : 0
        }
    }
}
