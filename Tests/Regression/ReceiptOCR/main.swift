import Foundation
import CoreGraphics
import CoreImage

func expect(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    print("PASS: \(message)")
}
func fragment(_ text: String, _ x: Double, _ y: Double, _ width: Double = 0.2, _ height: Double = 0.02) -> OCRLine {
    .init(candidates: [.init(text: text, confidence: 0.9)], x: x, y: y, width: width, height: height)
}
let fragments = [fragment("4.99", 0.8, 0.802, 0.1), fragment("Milk", 0.1, 0.8),
                 fragment("2", 0.65, 0.797, 0.05), fragment("Bread", 0.1, 0.75),
                 fragment("3.25", 0.8, 0.749, 0.1), fragment("0.500 kg @ 6.50", 0.1, 0.72, 0.6)]
let scan = OCRScan(observations: fragments)
expect(scan.text == "Milk 2 4.99\nBread 3.25\n0.500 kg @ 6.50", "Jittered price/name/quantity columns reconstructed; weight detail remains separate")
expect(scan.rows[0].observationIndices == [1, 2, 0], "Rows retain source indices in left-to-right order")
expect(abs(scan.rows[0].width - 0.8) < 1e-9 && abs(scan.rows[0].height - 0.025) < 1e-9, "Row union encloses all original fragments")
expect(OCRScan(observations: fragments.reversed()).text == scan.text, "Reading order is independent of Vision result order")
expect(OCRScan(observations: []).rows.isEmpty, "Empty OCR produces no fabricated rows")
let blanks = OCRScan(observations: [fragment("  ", 0.1, 0.9), .init(candidates: [], x: 0.1, y: 0.7, width: 0.2, height: 0.02)])
expect(blanks.rows.isEmpty && blanks.observations.count == 2, "Empty candidates remain in raw evidence but not reconstructed text")
expect(OCRScan(observations: [fragment("Milk", 0.1, 0.8), fragment("Milk", 0.1, 0.75)]).rows.count == 2, "Repeated purchases are preserved")
expect(OCRScan(observations: [fragment("A", 0.1, 0.8), fragment("B", 0.4, 0.791), fragment("C", 0.7, 0.782)]).rows.count == 2, "Pairwise checks prevent transitive chaining into the next row")
expect(OCRScan(observations: [fragment("Tall", 0.1, 0.7, 0.2, 0.16), fragment("Price", 0.8, 0.8)]).rows.count == 2, "Tall observations do not absorb adjacent small rows")
expect(OCRScan(observations: [fragments[0], fragments[0]]).rows.count == 2, "Overlapping OCR boxes are preserved separately, not silently deduplicated")

func tiltedLine(degrees: Double, width: Double = 1000, height: Double = 2000) -> OCRLine {
    let angle = degrees * .pi / 180
    func point(_ x: Double, _ y: Double) -> OCRLine.Point {
        .init(x: (200 + x * cos(angle) - y * sin(angle)) / width,
              y: (800 + x * sin(angle) + y * cos(angle)) / height)
    }
    return .init(candidates: [.init(text: "Receipt item", confidence: 0.9)], x: 0.1, y: 0.4, width: 0.3, height: 0.02,
                 quadrilateral: .init(topLeft: point(0, 30), topRight: point(300, 30),
                                      bottomLeft: point(0, 0), bottomRight: point(300, 0)))
}
for degrees in [-12.0, 0, 12] {
    let lines = [tiltedLine(degrees: degrees), tiltedLine(degrees: degrees + 0.1), tiltedLine(degrees: degrees - 0.1), tiltedLine(degrees: 35)]
    let angle = ReceiptDeskew.estimate(lines, width: 1000, height: 2000)!
    expect(abs(angle * 180 / .pi - degrees) < 0.11, "Estimate \(degrees) degrees on non-square image despite outlier")
}
expect(ReceiptDeskew.estimate([tiltedLine(degrees: 12)], width: 1000, height: 2000) == nil, "A single line cannot rotate the whole receipt")
expect(ReceiptDeskew.estimate([-25.0, -15, -5, 5, 15, 25].map { tiltedLine(degrees: $0) }, width: 1000, height: 2000) == nil, "Inconsistent text directions do not force rotation")
expect(ReceiptDeskew.estimate(fragments, width: 1000, height: 2000) == nil, "Axis-aligned bounding boxes alone cannot imply a skew angle")

let original = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 2000))
let rotated = try ReceiptDeskew.rotate(original, radians: -12 * .pi / 180)
expect(rotated.image.extent.minX == 0 && rotated.image.extent.minY == 0, "Corrected canvas starts at zero")
let transform = CGAffineTransform(rotationAngle: -12 * .pi / 180)
for point in [CGPoint.zero, CGPoint(x: 1000, y: 0), CGPoint(x: 0, y: 2000), CGPoint(x: 1000, y: 2000)] {
    let mapped = point.applying(transform)
    let final = CGPoint(x: mapped.x + rotated.translation.x, y: mapped.y + rotated.translation.y)
    expect(final.x >= 0 && final.y >= 0 && final.x <= rotated.image.extent.width && final.y <= rotated.image.extent.height,
           "Expanded affine canvas preserves corner \(point)")
}
let ciContext = CIContext(options: [.useSoftwareRenderer: true])
var pixel = [UInt8](repeating: 0, count: 4)
ciContext.render(rotated.image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
expect(pixel.allSatisfy { $0 > 250 }, "Rotated canvas padding renders opaque white")

let identity = OCRScan.Geometry(status: .corrected, estimatedSkewRadians: 0, appliedRotationRadians: 0,
                                originalWidth: 1000, originalHeight: 1000, imageWidth: 1000, imageHeight: 1000,
                                translationX: 0, translationY: 0)
func originalQuantity(_ text: String, y: Double = 0.5) -> OCRLine {
    .init(candidates: [.init(text: text, confidence: 1)], x: 0.1, y: y, width: 0.32, height: 0.03,
          quadrilateral: .init(topLeft: .init(x: 0.1, y: y + 0.03), topRight: .init(x: 0.42, y: y + 0.03),
                               bottomLeft: .init(x: 0.1, y: y), bottomRight: .init(x: 0.42, y: y)))
}
let droppedQuantity = fragment("Example item", 0.12, 0.5, 0.3, 0.03)
let recovered = OCRReconciliation.recoverLeadingQuantities(corrected: [droppedQuantity], original: [originalQuantity("2 Example item")], geometry: identity)
expect(recovered[0].text == "2 Example item" && recovered[0].source == .initialMapped, "Dropped quantity recovered only from mapped first-pass evidence")
let differentRow = OCRReconciliation.recoverLeadingQuantities(corrected: [droppedQuantity], original: [originalQuantity("2 Example item", y: 0.7)], geometry: identity)
expect(differentRow[0].text == droppedQuantity.text, "Quantity from another purchase row is never copied")
let ambiguous = OCRReconciliation.recoverLeadingQuantities(corrected: [droppedQuantity], original: [originalQuantity("2 Example item"), originalQuantity("3 Example item")], geometry: identity)
expect(ambiguous[0].text == droppedQuantity.text, "Conflicting quantity evidence remains unresolved")
let absent = OCRReconciliation.recoverLeadingQuantities(corrected: [droppedQuantity], original: [originalQuantity("Example item")], geometry: identity)
expect(absent[0].text == droppedQuantity.text, "Missing quantity is never fabricated")

// Pass real receipt paths explicitly; private images are never copied into the repository.
let ocr = ReceiptOCR()
for (index, path) in CommandLine.arguments.dropFirst().enumerated() {
    let result = try await ocr.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let geometry = result.geometry!
    let directory = URL(fileURLWithPath: "/tmp/TicketApp-OCR-Verification", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try result.evidenceJSON().write(to: directory.appendingPathComponent("receipt-\(index + 1).json"), atomically: true, encoding: .utf8)
    try result.text.write(to: directory.appendingPathComponent("receipt-\(index + 1).txt"), atomically: true, encoding: .utf8)
    let original = CIImage(data: try Data(contentsOf: URL(fileURLWithPath: path)), options: [.applyOrientationProperty: true])!
    let corrected = try ReceiptDeskew.rotate(original, radians: geometry.appliedRotationRadians).image
    if let preview = CIContext().jpegRepresentation(of: corrected, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) {
        try preview.write(to: directory.appendingPathComponent("receipt-\(index + 1)-corrected.jpg"))
    }
    print("Receipt \(index + 1): estimate=\(geometry.estimatedSkewRadians.map { $0 * 180 / .pi } ?? 999), applied=\(geometry.appliedRotationRadians * 180 / .pi), status=\(geometry.status), rows=\(result.rows.count)")
    let expected = [("1 Ayce Dusted Wings", "25.99"), ("1 Wht Sangria Gl", "9.39"), ("1 20oz Coors Light", "8.79"),
                    ("SUBTOTAL", "44.17"), ("HST", "5.74"), ("TOTAL", "49.91")]
    for (name, amount) in expected {
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: ":", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let match = result.rows.contains { normalized($0.text) == name + " " + amount }
        expect(match, "Receipt \(index + 1): exact quantity/name/amount row \(name) / \(amount)")
    }
    let decoded = try JSONDecoder().decode(OCRScan.self, from: Data(result.evidenceJSON().utf8))
    expect(decoded.text == result.text && decoded.geometry?.appliedRotationRadians == geometry.appliedRotationRadians,
           "Scan serialization preserves rows, geometry and evidence")
}
do {
    _ = try await ocr.recognize(Data("invalid".utf8))
    preconditionFailure("Invalid image accepted")
} catch ReceiptError.invalidImage { print("PASS: invalid image rejected") }
let cancelled = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await ocr.recognize(Data())
}
do {
    _ = try await cancelled.value
    preconditionFailure("Cancelled OCR returned success")
} catch is CancellationError { print("PASS: cancellation stops OCR before recognition") }
print("Deskew and row reconstruction checks completed.")
