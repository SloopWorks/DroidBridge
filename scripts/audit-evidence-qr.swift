// Read-only publication audit. Decoded values stay in memory and are never
// printed. A detected QR code requires separate review before publication.
import Foundation
import ImageIO
import Vision

guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift scripts/audit-evidence-qr.swift EVIDENCE_DIRECTORY") }
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { fatalError("Evidence directory unavailable") }
var scanned = 0
var detections: [[String: Any]] = []
var failures: [String] = []
for case let file as URL in iterator where ["png", "jpg", "jpeg"].contains(file.pathExtension.lowercased()) {
    do {
        try autoreleasepool {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= 16_777_216,
                  let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else {
                throw NSError(domain: "Image exceeds audit bounds or is unreadable", code: 1)
            }
            let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
            try VNImageRequestHandler(url: file).perform([request])
            scanned += 1
            if let results = request.results, !results.isEmpty {
                detections.append(["file": String(file.path.dropFirst(root.path.count + 1)), "qr_count": results.count, "decoded_value_logged": false])
            }
        }
    } catch { failures.append(String(file.path.dropFirst(root.path.count + 1))) }
}
let result: [String: Any] = ["scope": "Read-only Vision QR detection; no decoded payloads logged; detections require separate review", "images_scanned": scanned, "qr_detections": detections, "unreadable_or_oversize_images": failures]
let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(bytes); FileHandle.standardOutput.write(Data([10]))
if !detections.isEmpty || !failures.isEmpty { exit(1) }
