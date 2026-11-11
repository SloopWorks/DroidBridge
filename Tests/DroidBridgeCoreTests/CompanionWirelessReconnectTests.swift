import Foundation
import XCTest
@testable import DroidBridgeCore

final class CompanionWirelessReconnectTests: XCTestCase {
    private let alpha = "adb-Alpha-abc123", beta = "adb-Beta-efg456"
    private let old = "192.168.1.4:37000", fresh = "192.168.1.9:37401"

    private static func fingerprint(_ instance: String) -> String {
        String(repeating: instance.contains("Alpha") ? "a" : "b", count: 64)
    }

    private func connected(_ serial: String, _ instance: String) -> CompanionWirelessConnection {
        .init(serial: serial, message: "Connected", fingerprint: Self.fingerprint(instance))
    }

    private func scope() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wireless-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("profiles.json")
    }

    func testNoEnrollmentDoesNotTouchNetworkAndInvalidGUIDIsRejected() async throws {
        let harness = Harness(url: try scope())
        let result = await harness.service.reconnectIfDue(adb: "fixture", devices: [.init(serial: old, model: "Phone")])
        XCTAssertNil(result)
        let calls = await harness.network.calls
        XCTAssertEqual(calls, [])
        do { try await harness.service.remember(serviceInstance: "adb-example._adb-tls-connect._tcp", connection: connected(old, alpha)); XCTFail("Expected invalid GUID refusal") }
        catch { }
        let profiles = try await harness.service.profiles()
        XCTAssertEqual(profiles, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url.path))
    }

    func testPortAndIPRotationUsesGUIDAndPreservesHistoricalAliasCheckAcrossRestart() async throws {
        let harness = Harness(url: try scope())
        try await harness.service.remember(serviceInstance: alpha, label: "Pixel", connection: connected(old, alpha))
        await harness.network.setGUID(alpha, at: old)
        let online = await harness.service.reconnectIfDue(adb: "fixture", devices: [.init(serial: old, model: "Pixel")])
        XCTAssertNil(online)
        let firstCalls = await harness.network.calls
        XCTAssertEqual(firstCalls, [.verify(serial: old, instance: alpha)])

        // Another previously paired phone has acquired the old address. A new
        // advertisement for the original GUID contains the new IP and port.
        harness.clock.advance(16)
        await harness.network.setGUID(beta, at: old)
        await harness.network.setGUID(alpha, at: fresh)
        await harness.network.setRoute(fresh, for: alpha)
        let recovered = await harness.service.reconnectIfDue(adb: "fixture", devices: [.init(serial: old, model: "Other")])
        XCTAssertEqual(recovered?.serial, fresh)
        let calls = await harness.network.calls
        XCTAssertEqual(calls, [.verify(serial: old, instance: alpha), .verify(serial: old, instance: alpha), .connect(instance: alpha)])

        let reloaded = harness.newService()
        let profiles = try await reloaded.profiles()
        XCTAssertEqual(profiles.map(\.lastVerifiedSerial), [fresh])
        do { try await reloaded.checkKnownSerial(adb: "fixture", serial: old); XCTFail("Old alias authorized the wrong phone") }
        catch { }
        try await reloaded.checkKnownSerial(adb: "fixture", serial: fresh)
        let permissions = try FileManager.default.attributesOfItem(atPath: harness.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testPerPhoneBackoffDoesNotStarveOtherSavedPhones() async throws {
        let harness = Harness(url: try scope())
        try await harness.service.remember(serviceInstance: alpha, connection: connected(old, alpha))
        try await harness.service.remember(serviceInstance: beta, connection: connected(fresh, beta))
        await harness.network.setRoute(fresh, for: beta)
        let failure = await harness.service.reconnectIfDue(adb: "fixture", devices: [])
        XCTAssertNil(failure)
        let other = await harness.service.reconnectIfDue(adb: "fixture", devices: [])
        XCTAssertEqual(other?.serial, fresh)
        let beforeDue = await harness.service.reconnectIfDue(adb: "fixture", devices: [])
        XCTAssertNil(beforeDue)
        var calls = await harness.network.calls
        // IDs are sorted deterministically when multiple phones first become due.
        XCTAssertEqual(calls, [.connect(instance: alpha), .connect(instance: beta)])
        harness.clock.advance(4)
        let next = await harness.service.reconnectIfDue(adb: "fixture", devices: [])
        XCTAssertNil(next)
        calls = await harness.network.calls
        XCTAssertEqual(calls, [.connect(instance: alpha), .connect(instance: beta), .connect(instance: alpha)])
    }

    func testForgetFencesLateResultAndKeepsStaleAliasBlocked() async throws {
        let harness = Harness(url: try scope())
        try await harness.service.remember(serviceInstance: alpha, connection: connected(old, alpha))
        await harness.network.pauseNextConnection()
        let pending = Task { await harness.service.reconnectIfDue(adb: "fixture", devices: []) }
        await harness.network.waitForPausedConnection()
        try await harness.service.forget(serviceInstance: alpha)
        await harness.network.resume(serial: fresh)
        let late = await pending.value
        XCTAssertNil(late)

        let reloaded = harness.newService()
        let profiles = try await reloaded.profiles()
        XCTAssertTrue(profiles.isEmpty)
        let absent = await reloaded.reconnectIfDue(adb: "fixture", devices: [])
        XCTAssertNil(absent)
        do { try await reloaded.checkKnownSerial(adb: "fixture", serial: old); XCTFail("Forget let the old alias through") }
        catch { }
        let beforeRePair = await harness.network.calls
        XCTAssertEqual(beforeRePair, [.connect(instance: alpha)])

        try await reloaded.remember(serviceInstance: alpha, connection: connected(fresh, alpha))
        await harness.network.setGUID(alpha, at: fresh)
        try await reloaded.checkKnownSerial(adb: "fixture", serial: fresh)
        do { try await reloaded.checkKnownSerial(adb: "fixture", serial: old); XCTFail("Re-pair let the old alias through") }
        catch { }
    }

    func testAmbiguousHistoricalAddressRefusesBeforeAnyDeviceCommand() async throws {
        let harness = Harness(url: try scope())
        try await harness.service.remember(serviceInstance: alpha, connection: connected(old, alpha))
        try await harness.service.remember(serviceInstance: beta, connection: connected(old, beta))
        await harness.network.setGUID(beta, at: old)
        do { try await harness.service.checkKnownSerial(adb: "fixture", serial: old); XCTFail("Address historically belonged to two different phones") }
        catch { }
        let calls = await harness.network.calls
        XCTAssertEqual(calls, [])
    }

    func testStorageRejectsSymlinkAndLeavesTargetUntouched() async throws {
        let url = try scope()
        let target = url.deletingLastPathComponent().appendingPathComponent("target")
        try Data("existing".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let harness = Harness(url: url)
        do { try await harness.service.remember(serviceInstance: alpha, connection: connected(old, alpha)); XCTFail("Accepted a symlinked profile store") }
        catch { }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "existing")
    }

    func testUSBSelectionRequiresExactlyOneAuthorizedUSBTransportID() {
        let good = "PXL123 device usb:336592896X product:pixel model:Pixel_10 transport_id:31"
        XCTAssertEqual(CompanionWirelessReconnect.usbTransportID(good, serial: "PXL123"), 31)
        XCTAssertNil(CompanionWirelessReconnect.usbTransportID(good, serial: "PXL12"))
        XCTAssertNil(CompanionWirelessReconnect.usbTransportID(good + "\nPXL123 offline transport_id:88", serial: "PXL123"))
        XCTAssertNil(CompanionWirelessReconnect.usbTransportID(good + " transport_id:32", serial: "PXL123"))
        XCTAssertNil(CompanionWirelessReconnect.usbTransportID("PXL123 unauthorized usb:336 transport_id:31", serial: "PXL123"))
        XCTAssertNil(CompanionWirelessReconnect.usbTransportID("PXL123 device model:Pixel transport_id:31", serial: "PXL123"))
    }

    func testUSBWiFiHintRejectsOtherInterfacesAndAmbiguity() {
        let wlan = "12: wlan0    inet 192.168.1.8/24 brd 192.168.1.255 scope global wlan0"
        let cellular = "7: rmnet_data1    inet 10.111.3.8/24 scope global rmnet_data1"
        let vpn = "7: tun0    inet 100.88.3.8/24 scope global tun0"
        XCTAssertEqual(CompanionWirelessReconnect.usbWiFiHost(addresses: [wlan, cellular, vpn].joined(separator: "\n")), "192.168.1.8")
        XCTAssertNil(CompanionWirelessReconnect.usbWiFiHost(addresses: cellular + "\n" + vpn))
        XCTAssertNil(CompanionWirelessReconnect.usbWiFiHost(addresses: wlan + "\n11: wlan1    inet 10.0.0.4/24 scope global wlan1"))
        XCTAssertNil(CompanionWirelessReconnect.usbWiFiHost(addresses: "12: wlan0    inet 127.0.0.1/24 scope global wlan0"))
    }

    private struct Harness {
        let url: URL
        let clock = Clock()
        let network = Network()
        let service: CompanionWirelessReconnect

        init(url: URL) {
            self.url = url
            service = Self.make(url, clock, network)
        }

        func newService() -> CompanionWirelessReconnect { Self.make(url, clock, network) }

        private static func make(_ url: URL, _ clock: Clock, _ network: Network) -> CompanionWirelessReconnect {
            CompanionWirelessReconnect(storageURL: url, now: { clock.now() }, verify: { _, serial, instance, fingerprint in
                await network.verify(serial: serial, instance: instance, fingerprint: fingerprint)
            }, connect: { _, instance, fingerprint in
                try await network.connect(instance: instance, fingerprint: fingerprint)
            }, model: { _, _ in "Pixel" })
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 100
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
        func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; time += seconds }
    }

    private actor Network {
        enum Call: Equatable { case verify(serial: String, instance: String); case connect(instance: String) }
        private(set) var calls: [Call] = []
        private var identifiers: [String: String] = [:]
        private var routes: [String: String] = [:]
        private var pauseNext = false
        private var held: CheckedContinuation<String, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func setGUID(_ instance: String, at serial: String) { identifiers[serial] = CompanionWirelessReconnectTests.fingerprint(instance) }
        func setRoute(_ serial: String, for instance: String) { routes[instance] = serial }

        func verify(serial: String, instance: String, fingerprint: String) -> Bool {
            calls.append(.verify(serial: serial, instance: instance))
            return identifiers[serial] == fingerprint
        }

        func connect(instance: String, fingerprint: String) async throws -> CompanionWirelessConnection {
            calls.append(.connect(instance: instance))
            let serial: String
            if pauseNext {
                pauseNext = false
                serial = await withCheckedContinuation { continuation in
                    held = continuation
                    started?.resume()
                    started = nil
                }
            } else {
                guard let available = routes[instance] else { throw BridgeError.message("No advertisement") }
                serial = available
            }
            return .init(serial: serial, message: "Connected", fingerprint: fingerprint)
        }

        func pauseNextConnection() { pauseNext = true }
        func waitForPausedConnection() async { if held == nil { await withCheckedContinuation { started = $0 } } }
        func resume(serial: String) { held?.resume(returning: serial); held = nil }
    }
}
