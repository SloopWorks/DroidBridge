import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import DroidBridgeCore

final class CompanionQRImageReaderTests: XCTestCase {
    func testActualImageDecodesCurrentPairingQRAndValidatesIdentity() throws {
        let now = Date()
        let expiry = Int(now.timeIntervalSince1970) + 120
        let id = UUID().uuidString
        let uri = "droidbridge://pair?secret=\(String(repeating: "A", count: 43))&expires=\(expiry)&device_id=\(id)&server_pin=\(String(repeating: "a", count: 64))"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(uri.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let image = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(image, to: url)
        let decoded = try CompanionQRImageReader.read(url)
        XCTAssertEqual(decoded, uri)
        XCTAssertEqual(try CompanionPairCode(decoded, now: now).deviceID, id.lowercased())
    }

    func testActualNonQRImageAndOversizedInputAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qr-reject-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(CIImage(color: CIColor.white).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100)), to: url)
        XCTAssertThrowsError(try CompanionQRImageReader.read(url))
        try Data(count: 20 * 1024 * 1024 + 1).write(to: url)
        XCTAssertThrowsError(try CompanionQRImageReader.read(url))
    }

    private func write(_ image: CIImage, to url: URL) throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let pixels = try XCTUnwrap(context.createCGImage(image, from: image.extent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
