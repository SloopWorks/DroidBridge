import XCTest
import CoreGraphics
@testable import DroidBridgeStreaming

final class FrameMailboxTests: XCTestCase {
    private func image(_ width: Int) -> CGImage {
        CGContext(data:nil,width:width,height:1,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    @MainActor func testBlockedDeliveryRetainsNewestImageAndAllCounters() {
        var pending: [@MainActor () -> Void] = []
        var delivered: [FrameDelivery] = []
        let mailbox = FrameMailbox(scheduler:{ pending.append($0) },delivery:{ delivered.append($0) })
        for width in 1...100 { mailbox.publish(image(width),bytes:width) }
        XCTAssertEqual(pending.count,1,"Blocked main thread must schedule one task")
        pending.removeFirst()()
        XCTAssertEqual(delivered.count,1); XCTAssertEqual(delivered[0].image.width,100)
        XCTAssertEqual(delivered[0].frames,100); XCTAssertEqual(delivered[0].bytes,5050)
        XCTAssertTrue(pending.isEmpty)
        mailbox.publish(image(101),bytes:50)
        XCTAssertEqual(pending.count,1); pending.removeFirst()()
        XCTAssertEqual(delivered.last?.frames,1); XCTAssertEqual(delivered.last?.bytes,50)
    }
    @MainActor func testProducerDuringDeliverySchedulesOneSuccessorAndCancelDropsPending() {
        var pending: [@MainActor () -> Void] = []
        var delivered: [Int] = []
        var mailbox: FrameMailbox!
        mailbox = FrameMailbox(scheduler:{ pending.append($0) },delivery:{ [self] frame in
            delivered.append(frame.image.width)
            if frame.image.width == 1 { mailbox.publish(image(2),bytes:2); mailbox.publish(image(3),bytes:3) }
        })
        mailbox.publish(image(1),bytes:1); pending.removeFirst()()
        XCTAssertEqual(delivered,[1]); XCTAssertEqual(pending.count,1)
        pending.removeFirst()(); XCTAssertEqual(delivered,[1,3]); XCTAssertTrue(pending.isEmpty)
        mailbox.publish(image(4),bytes:4); mailbox.cancel(); pending.removeFirst()()
        mailbox.publish(image(5),bytes:5)
        XCTAssertEqual(delivered,[1,3]); XCTAssertTrue(pending.isEmpty)
    }
}
