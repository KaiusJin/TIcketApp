import Foundation

nonisolated enum OCRReconciliation {
    /// Resampling can make Vision drop a narrow leading quantity. Recover it only
    /// when the first pass actually read it, with agreeing text and overlapping geometry.
    /// Both raw OCR passes remain in OCRScan; no quantity is inferred from prices.
    static func recoverLeadingQuantities(corrected: [OCRLine], original: [OCRLine],
                                         geometry: OCRScan.Geometry) -> [OCRLine] {
        let mapped = original.compactMap { map($0, geometry: geometry) }
        return corrected.map { line in
            let matches = mapped.filter { first in
                guard first.text.hasSuffix(" " + line.text),
                      (first.candidates.first?.confidence ?? 0) >= (line.candidates.first?.confidence ?? 0) else { return false }
                let prefix = first.text.dropLast(line.text.count + 1)
                guard !prefix.isEmpty, prefix.contains(where: \.isNumber),
                      prefix.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) else { return false }
                let overlapWidth = max(0, min(first.x + first.width, line.x + line.width) - max(first.x, line.x))
                let overlapHeight = max(0, min(first.y + first.height, line.y + line.height) - max(first.y, line.y))
                let area = line.width * line.height
                return area > 0 && overlapWidth * overlapHeight / area >= 0.8
                    && abs(first.midY - line.midY) <= min(first.height, line.height) * 0.5
                    && abs((first.x + first.width) - (line.x + line.width)) <= line.height
            }
            return matches.count == 1 ? matches[0] : line
        }
    }

    private static func map(_ line: OCRLine, geometry: OCRScan.Geometry) -> OCRLine? {
        guard let quad = line.quadrilateral else { return nil }
        let angle = geometry.appliedRotationRadians
        func point(_ point: OCRLine.Point) -> OCRLine.Point {
            let x = point.x * geometry.originalWidth, y = point.y * geometry.originalHeight
            return .init(x: (x * cos(angle) - y * sin(angle) + geometry.translationX) / geometry.imageWidth,
                         y: (x * sin(angle) + y * cos(angle) + geometry.translationY) / geometry.imageHeight)
        }
        let mapped = OCRLine.Quadrilateral(topLeft: point(quad.topLeft), topRight: point(quad.topRight),
                                          bottomLeft: point(quad.bottomLeft), bottomRight: point(quad.bottomRight))
        let points = [mapped.topLeft, mapped.topRight, mapped.bottomLeft, mapped.bottomRight]
        let x = points.map(\.x).min()!, y = points.map(\.y).min()!
        let regions = line.amountRegions?.map { region in
            let corners = [point(.init(x: region.x, y: region.y)),
                           point(.init(x: region.x + region.width, y: region.y)),
                           point(.init(x: region.x, y: region.y + region.height)),
                           point(.init(x: region.x + region.width, y: region.y + region.height))]
            let minX = corners.map(\.x).min()!, minY = corners.map(\.y).min()!
            return OCRLine.TextRegion(location: region.location, length: region.length, x: minX, y: minY,
                                      width: corners.map(\.x).max()! - minX, height: corners.map(\.y).max()! - minY)
        }
        return OCRLine(candidates: line.candidates, x: x, y: y,
                       width: points.map(\.x).max()! - x, height: points.map(\.y).max()! - y,
                       quadrilateral: mapped, source: .initialMapped, amountRegions: regions)
    }
}
