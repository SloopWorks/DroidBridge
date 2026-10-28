import XCTest
import CoreVideo
@testable import DroidBridgeStreaming
import DroidBridgeCore

final class NativeDiagnosticsTests: XCTestCase {
    func testDecoderCallbackFailureIsObservableAndLaterOutputCanRecover() throws {
        let decoder = H264Decoder()
        var errors: [Int32] = []; var frames = 0
        decoder.onDecodeError = { errors.append($0) }
        decoder.output = { _ in frames += 1 }
        decoder.handleDecodedOutput(status:-12909,buffer:nil)
        XCTAssertEqual(errors,[-12909]); XCTAssertEqual(frames,0)
        // A missing buffer with noErr can be a dropped/delayed frame, not a
        // terminal decoder failure. A later valid output must still render.
        decoder.handleDecodedOutput(status:0,buffer:nil)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,2,2,kCVPixelFormatType_32BGRA,nil,&pixelBuffer),kCVReturnSuccess)
        decoder.handleDecodedOutput(status:0,buffer:try XCTUnwrap(pixelBuffer))
        XCTAssertEqual(frames,1); XCTAssertEqual(errors,[-12909])
    }
    func testStartupDiagnosticDistinguishesMissingAndUndecodedMedia() {
        var facts = NativeVideoDiagnostics()
        XCTAssertTrue(facts.summary.contains("announced size=unavailable"))
        XCTAssertTrue(facts.summary.contains("last decoder status=unavailable"))
        facts.packets=7; facts.bytes=1024; facts.width=720; facts.height=1080
        facts.decoderErrors=1; facts.lastDecoderStatus = -12909
        XCTAssertTrue(facts.summary.contains("video packets=7, bytes=1024, decoded frames=0"))
        XCTAssertTrue(facts.summary.contains("announced size=720x1080"))
        XCTAssertTrue(facts.summary.contains("last decoder status=-12909"))
    }
}
