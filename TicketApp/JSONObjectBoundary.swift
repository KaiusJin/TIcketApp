import Foundation

/// Track JSON structure across chunks without mistaking braces inside strings for boundaries.
nonisolated struct JSONObjectBoundary {
    private var started = false
    private var rejected = false
    private var inString = false
    private var escaped = false
    private var depth = 0
    private var prefix = ""
    private(set) var hasMarkdownFence = false
    private(set) var objectText = ""
    private(set) var complete = false

    var diagnosticState: String {
        if rejected { return "invalid_prefix" }
        if complete { return "closed" }
        if !started { return "waiting_object" }
        return inString ? "inside_string" : "object_open"
    }

    var nestingDepth: Int { depth }

    mutating func append(_ chunk: String) {
        for character in chunk {
            if complete || rejected { return }
            if !started {
                if prefix.isEmpty && character.isWhitespace { continue }
                if !prefix.isEmpty || character != "{" {
                    if !hasMarkdownFence {
                        if character.isNewline, prefix == "```json" || prefix == "```" {
                            hasMarkdownFence = true
                            prefix = ""
                            continue
                        }
                        prefix.append(contentsOf: character.lowercased())
                        if "```json".hasPrefix(prefix) || "```".hasPrefix(prefix) { continue }
                    }
                    rejected = true
                    return
                }
                started = true
                depth = 1
                objectText.append(character)
                continue
            }
            objectText.append(character)
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                if character == "\"" { inString = true }
                else if character == "{" || character == "[" { depth += 1 }
                else if character == "}" || character == "]" {
                    depth -= 1
                    if depth == 0 { complete = true }
                }
            }
        }
    }
}
