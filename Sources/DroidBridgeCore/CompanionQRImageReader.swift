import Foundation
import ImageIO
import Vision

public enum CompanionQRImageReader {
    /// Call off the UI actor. Only a bounded thumbnail is decoded for Vision;
    /// the file is never sent to a service or retained by this reader.
    public static func read(_ url: URL) throws -> String {
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard properties.isRegularFile == true, let size = properties.fileSize, size > 0, size <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let dimensions = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = dimensions[kCGImagePropertyPixelWidth] as? Int, let height = dimensions[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 12000, height <= 12000, width <= 32_000_000 / height else { throw BridgeError.message("Use a QR image smaller than 20 MiB and 32 megapixels.") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw BridgeError.message("This image could not be decoded.") }
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request]); try Task.checkCancellation()
        guard let text = request.results?.compactMap(\.payloadStringValue).first else { throw BridgeError.message("No QR code was found in this image. Try a clearer image or enter the pairing code.") }
        guard text.utf8.count <= 1024 else { throw BridgeError.message("This pairing code is too long.") }
        return text
    }
}
