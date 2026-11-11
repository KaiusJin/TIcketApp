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
    let candidates: [Candidate]
    /// Normalized coordinates, origin at bottom left, after EXIF orientation.
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let quadrilateral: Quadrilateral?
    let source: Source

    init(candidates: [Candidate], x: Double, y: Double, width: Double, height: Double,
         quadrilateral: Quadrilateral? = nil, source: Source = .initial) {
        self.candidates = candidates
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.quadrilateral = quadrilateral
        self.source = source
    }

    var text: String { candidates.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    var midY: Double { y + height / 2 }
}

