import Foundation

/// Qwen selects text; this layer recovers source rows and pairs geometric blocks.
/// It never estimates coordinates from character counts or uses a row's last number.
nonisolated struct OCRSettlementLayout: Codable, Sendable {
    struct Selection: Codable, Sendable {
        let generatedText: String
        let rowIndices: [Int]
        let issue: String?
    }
    struct Block: Codable, Sendable {
        var rowIndices: [Int]
        var leftText: String
        let amount: OCRPriceLayout.Anchor
        let amountText: String
        var issue: String?
    }
    struct Unresolved: Codable, Sendable {
        let rowIndices: [Int]
        let text: String
        let reason: String
    }
    let selections: [Selection]
    let selectedRowIndices: [Int]
    let columns: [OCRPriceLayout.Column]
    let blocks: [Block]
    let unresolved: [Unresolved]
    let issues: [String]

    private struct Parts {
        let rowIndex: Int
        let left: String
        let leftX: Double?
        let anchor: OCRPriceLayout.Anchor?
        let amountText: String
        let issue: String?
    }

    private static func compact(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    static func reconstruct(scan: OCRScan, selectedText: String) -> Self {
        guard let window = scan.amountWindow else {
            return .init(selections: [], selectedRowIndices: [], columns: [], blocks: [], unresolved: [],
                         issues: ["The checkout OCR window is unavailable."])
        }
        // Character-to-row provenance survives Qwen's whitespace/newline changes.
        // Only exact non-whitespace text is accepted: changed digits are not fuzzy-matched.
        var source = ""
        var owners: [Int] = []
        for slice in window.slices {
            let value = compact(slice.text)
            source += value
            owners += Array(repeating: slice.rowIndex, count: value.count)
        }
        var covered: Set<Int> = []
        var selections: [Selection] = []
        var unresolved: [Unresolved] = []
        var issues: [String] = []
        var lastEnd = 0
        for line in selectedText.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            let needle = compact(text)
            guard !needle.isEmpty else { continue }
            var matches: [Range<String.Index>] = []
            var cursor = source.startIndex
            while cursor < source.endIndex,
                  let range = source.range(of: needle, options: .literal, range: cursor..<source.endIndex) {
                matches.append(range)
                cursor = source.index(after: range.lowerBound)
            }
            guard matches.count == 1 else {
                let reason = matches.isEmpty ? "Selected text does not match the original OCR window." : "Selected text matches multiple OCR locations."
                selections.append(.init(generatedText: text, rowIndices: [], issue: reason))
                unresolved.append(.init(rowIndices: [], text: text, reason: reason))
                continue
            }
            let range = matches[0]
            let start = source.distance(from: source.startIndex, to: range.lowerBound)
            let end = source.distance(from: source.startIndex, to: range.upperBound)
            let rows = Set(owners[start..<end]).sorted()
            guard start >= lastEnd, covered.isDisjoint(with: start..<end) else {
                let reason = "Selected text overlaps or reorders previously selected OCR."
                selections.append(.init(generatedText: text, rowIndices: rows, issue: reason))
                unresolved.append(.init(rowIndices: rows, text: text, reason: reason))
                continue
            }
            covered.formUnion(start..<end)
            lastEnd = end
            selections.append(.init(generatedText: text, rowIndices: rows, issue: nil))
        }
        let mapped = Set(covered.map { owners[$0] })
        // A selected substring must not silently authorize the rest of its row.
        let complete = Set(window.slices.compactMap { slice -> Int? in
            guard mapped.contains(slice.rowIndex) else { return nil }
            let positions = owners.indices.filter { owners[$0] == slice.rowIndex }
            guard slice.isComplete, positions.allSatisfy(covered.contains) else {
                unresolved.append(.init(rowIndices: [slice.rowIndex], text: scan.rows[slice.rowIndex].text,
                                        reason: "Only part of this OCR row was selected or visible in the window."))
                return nil
            }
            return slice.rowIndex
        })
        let selected = complete.sorted()
        guard let first = mapped.min(), let last = mapped.max() else {
            return .init(selections: selections, selectedRowIndices: [], columns: [], blocks: [], unresolved: unresolved,
                         issues: ["Qwen's checkout selection could not be mapped to original OCR rows."])
        }
        // Keep omitted rows inside the selected area as visible barriers/evidence.
        // They are not silently included in totals or crossed during attachment.
        for row in first...last where !mapped.contains(row) {
            unresolved.append(.init(rowIndices: [row], text: scan.rows[row].text,
                                    reason: "This intervening OCR row was not selected by Qwen."))
        }
        let local = OCRPriceLayout.analyze(rows: selected.map { scan.rows[$0] }, observations: scan.observations, minimumRows: 2)
        var columns = local.columns.map { column in
            OCRPriceLayout.Column(rightEdge: column.rightEdge, anchors: column.anchors.map {
                .init(rowIndex: selected[$0.rowIndex], observationIndex: $0.observationIndex, region: $0.region)
            })
        }
        if columns.isEmpty {
            columns = scan.priceLayout.columns.compactMap { column in
                let anchors = column.anchors.filter { complete.contains($0.rowIndex) }
                guard Set(anchors.map(\.rowIndex)).count >= 2 else { return nil }
                return .init(rightEdge: column.rightEdge, anchors: anchors)
            }
        }
        guard let column = columns.last else {
            for row in selected {
                unresolved.append(.init(rowIndices: [row], text: scan.rows[row].text,
                                        reason: "No supported monetary column could be located from OCR coordinates."))
            }
            return .init(selections: selections, selectedRowIndices: selected, columns: columns, blocks: [], unresolved: unresolved,
                         issues: ["Checkout amounts need review: monetary-column geometry is insufficient."])
        }
        let leftEdge = column.anchors.map { $0.region.x }.min()!
        let glyphs = column.anchors.map { $0.region.width / Double(max(1, $0.region.length)) }.sorted()
        let xTolerance = glyphs[glyphs.count / 2] * 1.5
        let anchors = Dictionary(grouping: column.anchors, by: \.rowIndex)
        var parts: [Int: Parts] = [:]
        for rowIndex in selected {
            let rowAnchors = anchors[rowIndex] ?? []
            let anchor = rowAnchors.count == 1 ? rowAnchors[0] : nil
            var issue: String? = rowAnchors.count > 1 ? "More than one amount occupies this row in the monetary column." : nil
            var left: [String] = []
            var leftX: Double?
            var amountText = ""
            for index in scan.rows[rowIndex].observationIndices {
                let observation = scan.observations[index]
                if let anchor, index == anchor.observationIndex {
                    let region = anchor.region
                    let text = observation.text as NSString
                    amountText = text.substring(with: NSRange(location: region.location, length: region.length))
                    let prefix = text.substring(to: region.location).trimmingCharacters(in: .whitespaces)
                    let suffix = text.substring(from: region.location + region.length).trimmingCharacters(in: .whitespaces)
                    if !prefix.isEmpty {
                        left.append(prefix)
                        leftX = min(leftX ?? observation.x, observation.x)
                    }
                    if !suffix.isEmpty { issue = "Text after the amount is not assigned to the left label." }
                } else if observation.x + observation.width <= (anchor?.region.x ?? leftEdge) + xTolerance * 0.25 {
                    left.append(observation.text)
                    leftX = min(leftX ?? observation.x, observation.x)
                } else {
                    issue = "An OCR fragment overlaps or lies beyond the monetary column without a reliable assignment."
                }
            }
            parts[rowIndex] = .init(rowIndex: rowIndex, left: left.joined(separator: " "), leftX: leftX,
                                    anchor: anchor, amountText: amountText, issue: issue)
        }
        var blocks: [Block] = selected.compactMap { row in
            guard let part = parts[row], let anchor = part.anchor else { return nil }
            return .init(rowIndices: [row], leftText: part.left, amount: anchor, amountText: part.amountText, issue: part.issue)
        }
        let blockForRow = Dictionary(uniqueKeysWithValues: blocks.indices.map { (blocks[$0].amount.rowIndex, $0) })

        func gap(_ upper: Int, _ lower: Int) -> Double {
            max(0, scan.rows[upper].y - (scan.rows[lower].y + scan.rows[lower].height))
        }
        func nearby(_ upper: Int, _ lower: Int) -> Bool {
            gap(upper, lower) <= max(scan.rows[upper].height, scan.rows[lower].height) * 1.25
        }
        // Consecutive unpriced rows form a possible multiline label. Only attach
        // the group when spacing/alignment gives a unique nearby non-total owner.
        var runs: [[Int]] = []
        for row in selected where parts[row]?.anchor == nil {
            guard let part = parts[row], part.issue == nil, !part.left.isEmpty else {
                unresolved.append(.init(rowIndices: [row], text: scan.rows[row].text,
                                        reason: parts[row]?.issue ?? "This row has no attributable left-side text."))
                continue
            }
            if let previous = runs.last?.last, row == previous + 1, nearby(previous, row),
               abs((part.leftX ?? 0) - (parts[previous]?.leftX ?? 0)) <= xTolerance {
                runs[runs.count - 1].append(row)
            } else { runs.append([row]) }
        }
        for run in runs {
            let start = run.first!, end = run.last!
            var candidates: [(index: Int, distance: Double)] = []
            for neighbor in [start - 1, end + 1] {
                guard let index = blockForRow[neighbor], blocks[index].issue == nil,
                      !isSummaryBoundary(blocks[index].leftText) else { continue }
                let adjacent = neighbor < start ? start : end
                let upper = min(neighbor, adjacent), lower = max(neighbor, adjacent)
                guard nearby(upper, lower) else { continue }
                if let labelX = parts[neighbor]?.leftX, let runX = parts[adjacent]?.leftX,
                   abs(labelX - runX) > xTolerance { continue }
                candidates.append((index, gap(upper, lower) / max(scan.rows[upper].height, scan.rows[lower].height)))
            }
            candidates.sort { $0.distance < $1.distance }
            let winner: Int?
            if candidates.count == 1 { winner = candidates[0].index }
            else if candidates.count == 2, candidates[1].distance - candidates[0].distance > 0.5 {
                winner = candidates[0].index
            } else { winner = nil }
            guard let winner else {
                let reason = "Multiline text has no unique neighboring amount block."
                unresolved.append(.init(rowIndices: run, text: run.map { scan.rows[$0].text }.joined(separator: "\n"), reason: reason))
                for candidate in candidates { blocks[candidate.index].issue = reason }
                continue
            }
            blocks[winner].rowIndices += run
            blocks[winner].rowIndices.sort()
            blocks[winner].leftText = blocks[winner].rowIndices.compactMap { parts[$0]?.left }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
        for index in blocks.indices {
            if blocks[index].leftText.isEmpty { blocks[index].issue = "The amount has no uniquely associated label." }
            if canonicalAmount(blocks[index].amountText) == nil { blocks[index].issue = "The printed amount format is ambiguous." }
            if blocks[index].issue != nil {
                unresolved.append(.init(rowIndices: blocks[index].rowIndices,
                                        text: blocks[index].rowIndices.map { scan.rows[$0].text }.joined(separator: "\n"),
                                        reason: blocks[index].issue!))
            }
        }
        if !unresolved.isEmpty { issues.append("Some checkout text or amounts could not be paired uniquely; review the OCR block evidence.") }
        return .init(selections: selections, selectedRowIndices: selected, columns: columns,
                     blocks: blocks.sorted { $0.rowIndices[0] < $1.rowIndices[0] }, unresolved: unresolved, issues: issues)
    }

    private static func key(for label: String) -> String {
        // No special TOTAL rewriting: every original label follows the same rule.
        label.uppercased()
    }

    private static func isSummaryBoundary(_ label: String) -> Bool {
        let bare = label.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":=")))
        return ["TOTAL", "SUBTOTAL"].contains(bare.uppercased())
    }

    private static func canonicalAmount(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: #"[\p{Sc}\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "−", with: "-")
        if value.hasSuffix("-"), !value.hasPrefix("-") { value = "-" + value.dropLast() }
        if value.range(of: #"^-?[0-9]+(?:[.,][0-9]{2})?$"#, options: .regularExpression) != nil {
            return value.replacingOccurrences(of: ",", with: ".")
        }
        if value.range(of: #"^-?[0-9]{1,3}(?:,[0-9]{3})+\.[0-9]{2}$"#, options: .regularExpression) != nil {
            return value.replacingOccurrences(of: ",", with: "")
        }
        if value.range(of: #"^-?[0-9]{1,3}(?:\.[0-9]{3})+,[0-9]{2}$"#, options: .regularExpression) != nil {
            return value.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        return nil
    }

    func output() throws -> ModelOutput {
        var totals: [String: Any] = [:]
        let labels = Set(blocks.map { Self.key(for: $0.leftText) })
        var used: Set<String> = []
        for block in blocks where !block.leftText.isEmpty {
            let base = Self.key(for: block.leftText)
            var key = base
            var suffix = 2
            while used.contains(key) {
                key = "\(base)_\(suffix)"
                suffix += 1
                while labels.contains(key) { key = "\(base)_\(suffix)"; suffix += 1 }
            }
            used.insert(key)
            if block.issue == nil, let amount = Self.canonicalAmount(block.amountText) { totals[key] = amount }
            else { totals[key] = NSNull() }
        }
        let data = try JSONSerialization.data(withJSONObject: ["totals": totals], options: [.prettyPrinted, .sortedKeys])
        return ModelOutput(text: String(decoding: data, as: UTF8.self), reachedLimit: false)
    }

    func evidenceJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
