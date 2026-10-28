import XCTest
@testable import DroidBridgeCore

final class DeviceSelectionTests: XCTestCase {
    let devices = [AndroidDevice(serial: "emulator-5554", model: "Existing"), AndroidDevice(serial: "emulator-5580", model: "Test")]
    func testExplicitSerialWinsOverFirstDevice() {
        XCTAssertEqual(DeviceSelection.index(in: devices, currentSerial: nil, preferredSerial: "emulator-5580"), 1)
    }
    func testMissingExplicitSerialDoesNotQueryAnotherDevice() {
        XCTAssertNil(DeviceSelection.index(in: devices, currentSerial: nil, preferredSerial: "pixel-unplugged"))
    }
    func testUserSelectionAndDefault() {
        XCTAssertEqual(DeviceSelection.index(in: devices, currentSerial: "emulator-5554", preferredSerial: "emulator-5580"), 0)
        XCTAssertEqual(DeviceSelection.index(in: devices, currentSerial: nil, preferredSerial: nil), 0)
        XCTAssertNil(DeviceSelection.index(in: [], currentSerial: nil, preferredSerial: nil))
    }
}
