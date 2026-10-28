import CoreGraphics
import XCTest
@testable import DroidBridgeCore
final class InputGeometryTests: XCTestCase {
    func testLetterboxAndCenter() {
        let rect = InputGeometry.aspectFitRect(videoWidth: 400, videoHeight: 800, bounds: CGRect(x: 0, y: 0, width: 800, height: 800))
        XCTAssertEqual(rect, CGRect(x: 200, y: 0, width: 400, height: 800))
        XCTAssertNil(InputGeometry.coordinates(point: CGPoint(x: 100, y: 200), rect: rect, videoWidth: 400, videoHeight: 800))
        let center = InputGeometry.coordinates(point: CGPoint(x: 400, y: 400), rect: rect, videoWidth: 400, videoHeight: 800)
        XCTAssertEqual(center?.x, 200); XCTAssertEqual(center?.y, 400)
    }
    func testDragClampsAndInvalidDimensions() {
        let rect = CGRect(x: 50, y: 50, width: 100, height: 200)
        let outside = InputGeometry.coordinates(point: CGPoint(x: -20, y: 999), rect: rect, videoWidth: 200, videoHeight: 400, clamp: true)
        XCTAssertEqual(outside?.x, 0); XCTAssertEqual(outside?.y, 399)
        XCTAssertNil(InputGeometry.coordinates(point: .zero, rect: .zero, videoWidth: 200, videoHeight: 400))
        XCTAssertEqual(InputGeometry.aspectFitRect(videoWidth: 0, videoHeight: 800, bounds: rect), .zero)
    }
}
