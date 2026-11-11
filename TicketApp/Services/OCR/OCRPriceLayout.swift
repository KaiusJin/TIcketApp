import Foundation

/// Geometry supplies candidate columns and soft reading groups, never item or
/// total semantics. Every row remains available to the extraction model once.
nonisolated struct OCRPriceLayout: Codable, Sendable {
    struct Anchor: Codable, Sendable {
        let rowIndex: Int
        let observationIndex: Int
        let region: OCRLine.TextRegion
    }
    struct Column: Codable, Sendable {
        let rightEdge: Double
        let anchors: [Anchor]
    }
    struct Block: Codable, Sendable {
        let rowIndices: [Int]
    }
    let columns: [Column]
    /// The rightmost supported column is a grouping cue, not a total-price label.
    let primaryColumnIndex: Int?
    let blocks: [Block]

    // Require decimal cents or a currency sign. Bare integers, percentages,
    // embedded model numbers and unit suffixes cannot establish a price column.
    private static let money = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}.,/])(?:[-−]?\p{Sc}\s*[-−]?[0-9]+(?:[.,][0-9]{3})*(?:[.,][0-9]{2})?|[-−]?(?:[0-9]{1,3}(?:[.,][0-9]{3})+|[0-9]+)[.,][0-9]{2})(?:\s*\p{Sc})?-?(?![\p{L}\p{N}.,/%])"#)

    static func amountRanges(in text: String) -> [NSRange] {
        money.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    static func analyze(rows: [OCRRow], observations: [OCRLine], minimumRows: Int = 3) -> Self {
        let boxes = observations.filter { !$0.text.isEmpty && $0.width > 0 && $0.height > 0 }
        guard let left = boxes.map(\.x).min(), let right = boxes.map({ $0.x + $0.width }).max(), right > left else {
            return .init(columns: [], primaryColumnIndex: nil, blocks: rows.isEmpty ? [] : [.init(rowIndices: Array(rows.indices))])
        }
        let span = right - left
        var candidates: [Anchor] = []
        for (rowIndex, row) in rows.enumerated() {
            for index in row.observationIndices {
                let line = observations[index]
                let ranges = amountRanges(in: line.text)
                var regions = line.amountRegions ?? []
                // Old scans or unavailable substring boxes: only a whole amount
                // observation has known geometry. Never estimate character x's.
                if regions.isEmpty, ranges.count == 1, ranges[0] == NSRange(line.text.startIndex..., in: line.text) {
                    regions = [.init(location: 0, length: ranges[0].length,
                                     x: line.x, y: line.y, width: line.width, height: line.height)]
                }
                for region in regions where ranges.contains(NSRange(location: region.location, length: region.length)) {
                    guard region.width > 0, region.height > 0,
                          region.x >= left + span * 0.5,
                          region.x + region.width >= left + span * 0.65 else { continue }
                    candidates.append(.init(rowIndex: rowIndex, observationIndex: index, region: region))
                }
            }
        }
        // Estimate alignment tolerance from printed glyph size, relative to this
        // receipt's occupied width (not the image margin or a supermarket layout).
        let glyphWidths = candidates.map { $0.region.width / Double(max(1, $0.region.length)) }.sorted()
        let glyphWidth = glyphWidths.isEmpty ? span * 0.02 : glyphWidths[glyphWidths.count / 2]
        let tolerance = min(span * 0.025, max(span * 0.008, glyphWidth * 0.65))
        let sorted = candidates.sorted {
            let a = $0.region.x + $0.region.width, b = $1.region.x + $1.region.width
            return a == b ? $0.rowIndex < $1.rowIndex : a < b
        }
        var clusters: [[Anchor]] = []
        for anchor in sorted {
            let edge = anchor.region.x + anchor.region.width
            // Bound the whole cluster width; transitive jitter must not join two columns.
            if let first = clusters.last?.first, edge - (first.region.x + first.region.width) <= tolerance {
                clusters[clusters.count - 1].append(anchor)
            } else {
                clusters.append([anchor])
            }
        }
        func hasDescription(_ anchor: Anchor) -> Bool {
            let row = rows[anchor.rowIndex]
            return row.observationIndices.contains { index in
                let line = observations[index]
                if index == anchor.observationIndex {
                    let prefix = (line.text as NSString).substring(to: anchor.region.location)
                    return prefix.contains(where: \.isLetter)
                }
                return line.x + line.width <= anchor.region.x + tolerance && line.text.contains(where: \.isLetter)
            }
        }
        let columns = clusters.compactMap { anchors -> Column? in
            let rowIDs = Set(anchors.map(\.rowIndex))
            // Repetition alone can be a column of numbers unrelated to products.
            // Require independent rows with nearby descriptions as well.
            let describedRows = rowIDs.filter { row in
                if anchors.contains(where: { $0.rowIndex == row && hasDescription($0) }) { return true }
                guard row > 0 else { return false }
                let prior = rows[row - 1], current = rows[row]
                return prior.text.contains(where: \.isLetter)
                    && prior.y - (current.y + current.height) <= max(prior.height, current.height) * 1.5
            }
            guard rowIDs.count >= max(2, minimumRows), describedRows.count >= 2,
                  rowIDs.count == anchors.count else { return nil }
            let edges = anchors.map { $0.region.x + $0.region.width }.sorted()
            return .init(rightEdge: edges[edges.count / 2], anchors: anchors.sorted { $0.rowIndex < $1.rowIndex })
        }
        let primary = columns.indices.last
        let primaryAnchors = primary.map { columns[$0].anchors } ?? []
        let primaryRows = Set(primaryAnchors.map(\.rowIndex))
        let described = Set(primaryAnchors.filter(hasDescription).map(\.rowIndex))
        var blocks: [Block] = []
        var start = 0
        var anchorCount = 0
        for row in rows.indices {
            // Aim for a few neighboring prices per block. Never cut next to an
            // unpriced continuation or a price-only row: its owner is ambiguous.
            // Boundaries remain soft because a labeled discount can look like an item.
            if anchorCount >= 3, row > start, described.contains(row), described.contains(row - 1) {
                blocks.append(.init(rowIndices: Array(start..<row)))
                start = row
                anchorCount = 0
            }
            if primaryRows.contains(row) { anchorCount += 1 }
        }
        if start < rows.count { blocks.append(.init(rowIndices: Array(start..<rows.count))) }
        return .init(columns: columns, primaryColumnIndex: primary, blocks: blocks)
    }

    /// Only inserts delimiters. Original spelling, order, duplicates, quantities,
    /// signs, unassigned rows and every non-price fragment are preserved.
    func text(rows: [OCRRow], observations: [OCRLine]) -> String {
        let anchors = Dictionary(grouping: columns.flatMap(\.anchors), by: \.observationIndex)
        return blocks.map { block in
            block.rowIndices.map { row in
                rows[row].observationIndices.map { index in
                    var text = observations[index].text
                    for anchor in (anchors[index] ?? []).sorted(by: { $0.region.location > $1.region.location }) {
                        let nsRange = NSRange(location: anchor.region.location, length: anchor.region.length)
                        guard let range = Range(nsRange, in: text) else { continue }
                        text.replaceSubrange(range, with: "[price-column]" + String(text[range]) + "[/price-column]")
                    }
                    return text
                }.joined(separator: " ")
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
