import Foundation
import CoreImage

nonisolated enum ReceiptDeskew {
    static let minimumRotation = 0.5 * Double.pi / 180

    /// Use text quadrilateral edges, not axis-aligned boundingBox corners.
    /// Normalize back to pixels first: receipt images are rarely square.
    static func estimate(_ observations: [OCRLine], width: Double, height: Double) -> Double? {
        guard width > 0, height > 0 else { return nil }
        let angles: [Double] = observations.compactMap { line in
            guard !line.text.isEmpty, (line.candidates.first?.confidence ?? 0) >= 0.3,
                  let quad = line.quadrilateral else { return nil }
            func edge(_ a: OCRLine.Point, _ b: OCRLine.Point) -> (angle: Double, length: Double) {
                let dx = (b.x - a.x) * width, dy = (b.y - a.y) * height
                return (atan2(dy, dx), hypot(dx, dy))
            }
            let top = edge(quad.topLeft, quad.topRight)
            let bottom = edge(quad.bottomLeft, quad.bottomRight)
            let side = (edge(quad.bottomLeft, quad.topLeft).length + edge(quad.bottomRight, quad.topRight).length) / 2
            guard min(top.length, bottom.length) >= max(20, 2 * side),
                  abs(top.angle - bottom.angle) <= 5 * .pi / 180 else { return nil }
            let angle = (top.angle + bottom.angle) / 2
            // Deskew near-upright receipts; EXIF handles camera orientation.
            guard angle.isFinite, abs(angle) <= .pi / 4 else { return nil }
            return angle
        }
        guard angles.count >= 3 else { return nil }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted(), middle = values.count / 2
            return values.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        let center = median(angles)
        let deviation = median(angles.map { abs($0 - center) })
        let tolerance = min(5 * .pi / 180, max(1.5 * .pi / 180, 3 * deviation))
        let inliers = angles.filter { abs($0 - center) <= tolerance }
        guard inliers.count >= 3, Double(inliers.count) / Double(angles.count) >= 0.6 else { return nil }
        return median(inliers)
    }

    static func rotate(_ image: CIImage, radians: Double) throws -> (image: CIImage, translation: CGPoint) {
        guard let filter = CIFilter(name: "CIAffineTransform", parameters: [
            kCIInputImageKey: image,
            kCIInputTransformKey: CGAffineTransform(rotationAngle: radians)
        ]), let rotated = filter.outputImage else { throw ReceiptError.invalidImage }
        // Expand the canvas instead of cropping corners of the receipt. White
        // padding prevents transparent pixels becoming black during OCR rendering.
        let bounds = rotated.extent.integral
        let translation = CGPoint(x: -bounds.minX, y: -bounds.minY)
        let shifted = rotated.transformed(by: CGAffineTransform(translationX: translation.x, y: translation.y))
        let canvas = CGRect(origin: .zero, size: bounds.size)
        let white = CIImage(color: .white).cropped(to: canvas)
        return (shifted.composited(over: white).cropped(to: canvas), translation)
    }
}
