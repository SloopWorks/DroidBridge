import XCTest
@testable import DroidBridgeStreaming

final class AppDisplayWatchTests: XCTestCase {
    private let package = "dev.droidbridge.testapp7"

    private func snapshot(_ phone: String = "", _ mac: String = "") -> AppDisplayWatch.Snapshot? {
        AppDisplayWatch.Snapshot("""
        ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)
        Display #0 (activities from top to bottom):
        \(phone)
        Display #2 (activities from top to bottom):
        \(mac)
        """, package: package)
    }

    func testConfirmsSameTaskMovedAcrossDisplays() {
        var watch = AppDisplayWatch()
        let task = "    * Hist  #0: ActivityRecord{3c98123 u0 \(package)/.MainActivity t1475}"
        XCTAssertNil(watch.observe(snapshot("", task), ownedDisplay: 2))
        XCTAssertNil(watch.observe(snapshot(task), ownedDisplay: 2))
        XCTAssertEqual(watch.observe(snapshot(task), ownedDisplay: 2), .init(task: .init(user: 0, id: 1475), display: 0))
    }

    func testDoesNotReportAnotherInstanceUserOrPackageAsTheMovedTask() {
        var watch = AppDisplayWatch()
        let task = "    * Hist  #0: ActivityRecord{123abcd u0 \(package)/.MainActivity t1475}"
        let others = """
            * Hist  #0: ActivityRecord{456abcd u0 \(package)/.MainActivity t1476}
            * Hist  #0: ActivityRecord{789abcd u10 \(package)/.MainActivity t1475}
            * Hist  #0: ActivityRecord{012abcd u0 \(package).clone/.MainActivity t1475}
        """
        XCTAssertNil(watch.observe(snapshot("", task), ownedDisplay: 2))
        for _ in 0..<2 { XCTAssertNil(watch.observe(snapshot(others), ownedDisplay: 2)) }
        let stillOnMac = "    * Hist  #0: ActivityRecord{456abcd u0 \(package)/.MainActivity t1476}"
        for _ in 0..<2 { XCTAssertNil(watch.observe(snapshot(task, stillOnMac), ownedDisplay: 2)) }
    }

    func testUnknownOrTransientSampleDoesNotConfirmMove() {
        var watch = AppDisplayWatch()
        let task = "    * Hist  #0: ActivityRecord{123abcd u0 \(package)/.MainActivity t1475}"
        XCTAssertNil(watch.observe(snapshot("", task), ownedDisplay: 2))
        XCTAssertNil(watch.observe(snapshot(task), ownedDisplay: 2))
        XCTAssertNil(watch.observe(nil, ownedDisplay: 2))
        XCTAssertNil(watch.observe(snapshot(task), ownedDisplay: 2))
        XCTAssertNil(watch.observe(snapshot("", task), ownedDisplay: 2))
        XCTAssertNil(watch.observe(snapshot(task), ownedDisplay: 2))
    }

    func testLaunchReceiptUsesExactPackageAndOneValidVirtualDisplay() {
        let receipt = "[server] INFO: Starting app \"Test app\" [\(package)] on display "
        XCTAssertEqual(AppDisplayWatch.launchedDisplay([receipt + "3..."], package: package), 3)
        XCTAssertNil(AppDisplayWatch.launchedDisplay([receipt + "0..."], package: package))
        XCTAssertNil(AppDisplayWatch.launchedDisplay([receipt + "3...", receipt + "4..."], package: package))
        XCTAssertNil(AppDisplayWatch.launchedDisplay([receipt + "3..."], package: package + ".clone"))
    }
}
