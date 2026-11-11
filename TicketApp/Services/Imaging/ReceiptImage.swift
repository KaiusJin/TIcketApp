import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downsample during decode, rather than allocating a full-resolution camera bitmap first.
actor ReceiptImage {
    func prepare(_ data: Data, maxPixelSize: Int = 2048) throws -> Data {
        InferenceDiagnostics.current?.phase("image_downsample")
        InferenceDiagnostics.current?.event("image_input_bytes=\(data.count) target_edge=\(maxPixelSize)")
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ReceiptError.invalidImage }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw ReceiptError.invalidImage
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ReceiptError.invalidImage }
            try Task.checkCancellation()
            InferenceDiagnostics.current?.event("image_ready width=\(image.width) height=\(image.height) bytes=\(output.length)")
            return output as Data
        }
    }
}
