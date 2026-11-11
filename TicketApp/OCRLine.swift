import Foundation

nonisolated struct OCRLine: Codable, Sendable {
    enum Source: String, Codable, Sendable { case initial, corrected, initialMapped }
    struct Point: Codable, Sendable {
        let x: Double
        let y: Double
    }
    struct Quadrilateral: Codable, Sendable {
        let topLeft: Point
        let topRight: Point
        let bottomLeft: Point
        let bottomRight: Point
    }
    struct Candidate: Codable, Sendable {
        let text: String
        let confidence: Float
    }
    /// Exact substring box from Vision's best candidate, in the same coordinate
    /// system as the observation. Offsets address `text` in UTF-16.
    struct TextRegion: Codable, Sendable {
        let location: Int
        let length: Int
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    let candidates: [Candidate]
    /// Normalized coordinates, origin at bottom left, after EXIF orientation.
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let quadrilateral: Quadrilateral?
    let source: Source
    // Optional so previously exported scans remain decodable.
    let amountRegions: [TextRegion]?

    init(candidates: [Candidate], x: Double, y: Double, width: Double, height: Double,
         quadrilateral: Quadrilateral? = nil, source: Source = .initial, amountRegions: [TextRegion]? = nil) {
        self.candidates = candidates
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.quadrilateral = quadrilateral
        self.source = source
        self.amountRegions = amountRegions
    }

    var text: String { candidates.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    var midY: Double { y + height / 2 }
}

