import XCTest
@testable import DroidBridgeCore
final class AndroidDiscoveryTests: XCTestCase {
 func testDevicesPreserveUnavailableStates() {
  let devices = AndroidDiscovery.parseDevices("List of devices attached\nemulator-5580 device product:sdk model:Pixel_7 transport_id:1\nUSB123 unauthorized\nbad offline\n* daemon started successfully\n")
  XCTAssertEqual(devices.count, 3); XCTAssertEqual(devices[0].model, "Pixel 7"); XCTAssertEqual(devices[1].state, "unauthorized")
 }
 func testAppLabelsAndWrappedNames() {
  let apps=AndroidDiscovery.parseApplications("[server] INFO: List of apps:\n * Settings                       com.android.settings\n - An unusually long application name\n                                  dev.droidbridge.testapp\n - Test duplicate                 dev.droidbridge.testapp\nINFO: done\n")
  XCTAssertEqual(apps.count,2); XCTAssertEqual(apps[0].name,"An unusually long application name"); XCTAssertEqual(apps[1].packageName,"com.android.settings")
 }
 func testHostilePackageAndSerialRejected() {
  for value in ["com.test;id","--foo","com..test","$(id)","com.a/Act", "com.1bad"] { XCTAssertThrowsError(try AndroidDiscovery.validatePackage(value)) }
  for value in ["com.android.settings","org.chromium.webview_shell","dev.droidbridge.testapp"] { XCTAssertNoThrow(try AndroidDiscovery.validatePackage(value)) }
  XCTAssertThrowsError(try AndroidDiscovery.validateSerial("a;reboot")); XCTAssertNoThrow(try AndroidDiscovery.validateSerial("192.168.1.2:5555"))
 }
 func testRunnerDoesNotEvaluateShell() async throws {
  let result=try await ProcessRunner.run("/bin/echo",arguments:["$(touch /tmp/droidbridge-injection)"])
  XCTAssertTrue(result.output.contains("$(touch"))
 }
 func testRunnerTimeoutAndFailure() async {
  do { _=try await ProcessRunner.run("/bin/sleep",arguments:["20"], timeout:0.1); XCTFail("must timeout") } catch {}
  do { _=try await ProcessRunner.run("/usr/bin/false",arguments:[]); XCTFail("must fail") } catch {}
 }
 func testLiveDiscoveryWhenOptedIn() async throws {
  guard let serial=ProcessInfo.processInfo.environment["DROIDBRIDGE_TEST_SERIAL"] else { throw XCTSkip("Set DROIDBRIDGE_TEST_SERIAL to an emulator serial") }
  let discovery=AndroidDiscovery(); let devices=try await discovery.devices(); let device=try XCTUnwrap(devices.first{$0.serial==serial})
  let apps=try await discovery.applications(device:device); XCTAssertTrue(apps.contains{$0.packageName=="com.android.settings"})
  let cap=try await discovery.capabilities(device:device); XCTAssertTrue(cap.virtualDisplays); XCTAssertTrue(cap.adaptiveResize)
 }
}
