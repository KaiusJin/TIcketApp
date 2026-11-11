import Foundation

/// Content-free counters; timestamps are monotonic seconds from the run start.
nonisolated struct GenerationProgress {
    private(set) var tokens = 0
    private(set) var outputBytes = 0
    private(set) var firstTokenAt: Double?
    private(set) var lastTokenAt: Double?
    private(set) var lastVisibleTextAt: Double?
    private(set) var maxTokenGap = 0.0
    private(set) var identicalTokenRun = 0
    private(set) var repeatedPatternLength = 0
    private(set) var repeatedPatternCount = 0
    private(set) var jsonState = "waiting_object"
    private(set) var jsonDepth = 0
    private(set) var step = "not_started"
    private(set) var stepStarted = 0.0
    private var stepTotals: [String: Double] = [:]
    private var previousToken: Int?
    private var sampledTokens = 0
    private var sampledAt = 0.0
    private var recentTokens: [Int] = []

    mutating func enter(_ name: String, at now: Double) {
        stepTotals[step, default: 0] += max(0, now - stepStarted)
        step = name
        stepStarted = now
    }

    mutating func receive(_ token: Int, at now: Double) {
        if let lastTokenAt { maxTokenGap = max(maxTokenGap, now - lastTokenAt) }
        if firstTokenAt == nil { firstTokenAt = now }
        lastTokenAt = now
        tokens += 1
        identicalTokenRun = previousToken == token ? identicalTokenRun + 1 : 1
        previousToken = token
        recentTokens.append(token)
        if recentTokens.count > 256 { recentTokens.removeFirst() }
        // Detect repeated phrases as well as repeated single tokens. Never log token IDs.
        if tokens.isMultiple(of: 16) {
            repeatedPatternLength = 0
            repeatedPatternCount = 0
            let count = recentTokens.count
            if count >= 6 {
                for length in 2...min(64, count / 3) {
                    let pattern = recentTokens[(count - length)..<count]
                    var repeats = 1
                    while count >= (repeats + 1) * length,
                          recentTokens[(count - (repeats + 1) * length)..<(count - repeats * length)].elementsEqual(pattern) {
                        repeats += 1
                    }
                    if repeats >= 3 {
                        repeatedPatternLength = length
                        repeatedPatternCount = repeats
                        break
                    }
                }
            }
        }
    }

    mutating func append(_ text: String, state: String, depth: Int, at now: Double) {
        outputBytes += text.utf8.count
        if text.contains(where: { !$0.isWhitespace }) { lastVisibleTextAt = now }
        jsonState = state
        jsonDepth = depth
    }

    mutating func snapshot(at now: Double) -> String {
        let windowRate = Double(tokens - sampledTokens) / max(now - sampledAt, 0.001)
        let averageRate = firstTokenAt.map { Double(max(tokens - 1, 0)) / max(now - $0, 0.001) } ?? 0
        sampledTokens = tokens
        sampledAt = now
        func formatted(_ value: Double) -> String { String(format: "%.2f", value) }
        func age(_ time: Double?) -> String { time.map { formatted(max(0, now - $0)) } ?? "none" }
        func spent(_ name: String) -> String {
            formatted(1000 * (stepTotals[name, default: 0] + (step == name ? max(0, now - stepStarted) : 0)))
        }
        return "tokens_received=\(tokens) output_bytes=\(outputBytes) window_tps=\(formatted(windowRate)) average_tps=\(formatted(averageRate)) last_token_age_s=\(age(lastTokenAt)) last_visible_text_age_s=\(age(lastVisibleTextAt)) max_token_gap_s=\(formatted(maxTokenGap)) identical_token_run=\(identicalTokenRun) repeat_period=\(repeatedPatternLength) repeat_count=\(repeatedPatternCount) json_state=\(jsonState) json_depth=\(jsonDepth) consumer_step=\(step) step_age_s=\(age(stepStarted)) detokenize_ms=\(spent("detokenize")) ui_ms=\(spent("ui_update"))"
    }
}
