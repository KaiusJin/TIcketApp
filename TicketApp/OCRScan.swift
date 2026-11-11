import Foundation

/// A row is a geometric grouping, not an assertion that it is one purchased item.
nonisolated struct OCRRow: Codable, Sendable {
    let text: String
    let observationIndices: [Int]
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

nonisolated struct OCRScan: Codable, Sendable {
    struct Geometry: Codable, Sendable {
        enum Status: String, Codable, Sendable {
            case corrected, alreadyAligned, insufficientEvidence, recognitionFallback
        }
        let status: Status
        let estimatedSkewRadians: Double?
        /// Positive is counterclockwise in Core Image's bottom-left coordinate system.
        let appliedRotationRadians: Double
        let originalWidth: Double
        let originalHeight: Double
        let imageWidth: Double
        let imageHeight: Double
        /// Pixel translation applied after rotating around the original image origin.
        let translationX: Double
        let translationY: Double
    }

    let originalObservations: [OCRLine]
    let correctedObservations: [OCRLine]
    let observations: [OCRLine]
    let rows: [OCRRow]
    let geometry: Geometry?

    init(observations: [OCRLine], originalObservations: [OCRLine] = [], correctedObservations: [OCRLine] = [], geometry: Geometry? = nil) {
        self.originalObservations = originalObservations
        self.correctedObservations = correctedObservations
        self.observations = observations
        self.geometry = geometry
        rows = OCRRowReconstructor.reconstruct(observations, imageWidth: geometry?.imageWidth ?? 1,
                                              imageHeight: geometry?.imageHeight ?? 1)
    }

    var text: String { rows.map(\.text).joined(separator: "\n") }

    func evidenceJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

nonisolated enum OCRRowReconstructor {
    static func reconstruct(_ observations: [OCRLine], imageWidth: Double = 1, imageHeight: Double = 1) -> [OCRRow] {
        let ordered = observations.indices.filter { !observations[$0].text.isEmpty }.sorted {
            let a = observations[$0], b = observations[$1]
            // Anchor rows on longer text before attaching prices/single characters.
            // Otherwise a stray glyph above a price can claim it before its item name.
            if a.width != b.width { return a.width > b.width }
            if a.midY != b.midY { return a.midY > b.midY }
            if a.x != b.x { return a.x < b.x }
            return $0 < $1
        }
        func angle(_ line: OCRLine) -> Double? {
            guard let quad = line.quadrilateral else { return nil }
            return atan2((quad.bottomRight.y - quad.bottomLeft.y) * imageHeight,
                         (quad.bottomRight.x - quad.bottomLeft.x) * imageWidth)
        }
        var groups: [[Int]] = []
        for index in ordered {
            let box = observations[index]
            var best: Int?
            var bestDistance = Double.infinity
            for (groupIndex, members) in groups.enumerated() {
                var distance = 0.0
                let compatible = members.allSatisfy { member in
                    let other = observations[member]
                    let height = min(box.height, other.height)
                    guard height > 0 else { return false }
                    if let a = angle(box), let b = angle(other), abs(a - b) > 10 * .pi / 180 { return false }
                    let overlapY = min(box.y + box.height, other.y + other.height) - max(box.y, other.y)
                    let overlapX = min(box.x + box.width, other.x + other.width) - max(box.x, other.x)
                    let delta = abs(box.midY - other.midY) / height
                    distance = max(distance, delta)
                    // Compare every fragment, not the growing union: a tall box or
                    // a staircase of boxes must not bridge adjacent purchase rows.
                    return delta <= 0.5 && overlapY >= height * 0.5
                        && overlapX <= min(box.width, other.width) * 0.15
                }
                if compatible && distance < bestDistance {
                    best = groupIndex
                    bestDistance = distance
                }
            }
            if let best { groups[best].append(index) } else { groups.append([index]) }
        }

        return groups.map { group in
            let indices = group.sorted {
                if observations[$0].x != observations[$1].x { return observations[$0].x < observations[$1].x }
                return $0 < $1
            }
            let boxes = indices.map { observations[$0] }
            let x = boxes.map(\.x).min()!, y = boxes.map(\.y).min()!
            return OCRRow(text: boxes.map(\.text).joined(separator: " "), observationIndices: indices,
                          x: x, y: y, width: boxes.map { $0.x + $0.width }.max()! - x,
                          height: boxes.map { $0.y + $0.height }.max()! - y)
        }.sorted {
            let a = $0.y + $0.height / 2, b = $1.y + $1.height / 2
            if a != b { return a > b }
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.observationIndices[0] < $1.observationIndices[0]
        }
    }
}
