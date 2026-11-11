import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let context = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let image = context.makeImage()!
let original = NSMutableData()
let destination = CGImageDestinationCreateWithData(original, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
precondition(CGImageDestinationFinalize(destination))
let processor = ReceiptImage()
let result = try await processor.prepare(original as Data)
let source = CGImageSourceCreateWithData(result as CFData, nil)!
let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
precondition(properties[kCGImagePropertyPixelWidth] as! Int == 1536)
precondition(properties[kCGImagePropertyPixelHeight] as! Int == 2048)
let thumbnail = try await processor.prepare(result, maxPixelSize: 480)
let preview = CGImageSourceCreateWithData(thumbnail as CFData, nil)!
let previewProperties = CGImageSourceCopyPropertiesAtIndex(preview, 0, nil)! as NSDictionary
precondition(previewProperties[kCGImagePropertyPixelHeight] as! Int == 480)
do {
    _ = try await processor.prepare(Data("invalid".utf8))
    fatalError("Invalid image accepted")
} catch ReceiptError.invalidImage { }
print("PASS: image downsampling, EXIF orientation, preview bound and invalid input")
