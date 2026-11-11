import Foundation
import Vision
import CoreImage

actor ReceiptOCR {
    func recognize(_ data: Data) throws -> OCRScan {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                throw ReceiptError.invalidImage
            }
            let original = decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX,
                                                                     y: -decoded.extent.minY))
            let first = try recognizeText(original, phase: "vision_initial")
            let angle = ReceiptDeskew.estimate(first, width: original.extent.width, height: original.extent.height)
            var image = original
            var observations = first
            var correctedObservations: [OCRLine] = []
            var rotation = 0.0
            var translation = CGPoint.zero
            var status: OCRScan.Geometry.Status = angle == nil ? .insufficientEvidence : .alreadyAligned
            if let angle, abs(angle) >= ReceiptDeskew.minimumRotation {
                try Task.checkCancellation()
                InferenceDiagnostics.current?.phase("vision_deskew")
                let corrected = try ReceiptDeskew.rotate(original, radians: -angle)
                let second = try recognizeText(corrected.image, phase: "vision_corrected", source: .corrected)
                correctedObservations = second
                if second.contains(where: { !$0.text.isEmpty }) {
                    image = corrected.image
                    observations = second
                    rotation = -angle
                    translation = corrected.translation
                    status = .corrected
                } else {
                    // Preserve first-pass evidence if rotation makes OCR return no text.
                    status = .recognitionFallback
                }
            }
            try Task.checkCancellation()
            InferenceDiagnostics.current?.phase("vision_rows")
            let geometry = OCRScan.Geometry(
                status: status, estimatedSkewRadians: angle, appliedRotationRadians: rotation,
                originalWidth: original.extent.width, originalHeight: original.extent.height,
                imageWidth: image.extent.width, imageHeight: image.extent.height,
                translationX: translation.x, translationY: translation.y)
            if status == .corrected {
                observations = OCRReconciliation.recoverLeadingQuantities(corrected: observations, original: first, geometry: geometry)
            }
            let scan = OCRScan(observations: observations, originalObservations: first,
                               correctedObservations: correctedObservations, geometry: geometry)
            let layout = scan.priceLayout
            InferenceDiagnostics.current?.event("vision_scan status=\(status.rawValue) rotation_degrees=\(rotation * 180 / .pi) observations=\(observations.count) rows=\(scan.rows.count) price_columns=\(layout.columns.count) reading_blocks=\(layout.blocks.count)")
            try Task.checkCancellation()
            return scan
        }
    }

    private func recognizeText(_ image: CIImage, phase: String, source: OCRLine.Source = .initial) throws -> [OCRLine] {
        try Task.checkCancellation()
        let trace = InferenceDiagnostics.current
        trace?.phase(phase)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "fr-CA"].filter(supported.contains)
        trace?.event("vision_request width=\(Int(image.extent.width)) height=\(Int(image.extent.height)) languages=\(request.recognitionLanguages.joined(separator: ","))")
        try VNImageRequestHandler(ciImage: image).perform([request])
        try Task.checkCancellation()
        trace?.event("vision_complete observations=\(request.results?.count ?? 0)")
        return (request.results ?? []).map { observation in
            let box = observation.boundingBox
            func point(_ point: CGPoint) -> OCRLine.Point { .init(x: point.x, y: point.y) }
            let candidates = observation.topCandidates(3)
            let amountRegions: [OCRLine.TextRegion] = candidates.first.map { candidate in
                let raw = candidate.string
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let leadingCount = raw.prefix(while: { $0.isWhitespace }).utf16.count
                return OCRPriceLayout.amountRanges(in: text).compactMap { range in
                    let rawRange = NSRange(location: range.location + leadingCount, length: range.length)
                    guard let substring = Range(rawRange, in: raw),
                          let rectangle = try? candidate.boundingBox(for: substring) else { return nil }
                    let bounds = rectangle.boundingBox
                    return .init(location: range.location, length: range.length,
                                 x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
                }
            } ?? []
            return OCRLine(candidates: candidates.map {
                .init(text: $0.string, confidence: $0.confidence)
            }, x: box.minX, y: box.minY, width: box.width, height: box.height,
               quadrilateral: .init(topLeft: point(observation.topLeft), topRight: point(observation.topRight),
                                    bottomLeft: point(observation.bottomLeft), bottomRight: point(observation.bottomRight)),
                           source: source, amountRegions: amountRegions)
        }
    }
}
