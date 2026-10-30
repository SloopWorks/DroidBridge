import XCTest
import CoreGraphics
@testable import DroidBridgeCore
final class StartupFrameVisibilityTests:XCTestCase {
    func image(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat) throws -> CGImage {
        let context=try XCTUnwrap(CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:r,green:g,blue:b,alpha:1));context.fill(CGRect(x:0,y:0,width:64,height:64))
        return try XCTUnwrap(context.makeImage())
    }
    func testInitialSolidBlackAndNearBlackAreHeld() throws {
        XCTAssertFalse(StartupFrameVisibility.hasVisibleContent(try image(0,0,0)))
        XCTAssertFalse(StartupFrameVisibility.hasVisibleContent(try image(0.02,0.02,0.02)))
    }
    func testColoredAndLightSplashContentIsVisible() throws {
        XCTAssertTrue(StartupFrameVisibility.hasVisibleContent(try image(1,0,0)))
        XCTAssertTrue(StartupFrameVisibility.hasVisibleContent(try image(0,1,0)))
        XCTAssertTrue(StartupFrameVisibility.hasVisibleContent(try image(0,0,1)))
        XCTAssertTrue(StartupFrameVisibility.hasVisibleContent(try image(1,1,1)))
    }
}
