import Darwin
import Foundation
import XCTest
@testable import AnonymousUsage

final class UsageMeterTests: XCTestCase {
    private final class Recorder: UsageTransport {
        private let lock = NSLock()
        private var values: [UsageReport] = []
        var reports: [UsageReport] { lock.withLock { values } }
        var deferred: (() -> Void)?
        var delay = false
        func send(_ report: UsageReport, whileAuthorized: @escaping UsageAuthorization) {
            let handoff: () -> Void = {
                _ = whileAuthorized { self.lock.withLock { self.values.append(report) } }
            }
            if delay { deferred = handoff } else { handoff() }
        }
        func cancel() {}
    }

    private var directory: URL!
    private let recorder = Recorder()
    private var day = 100
    private var uptime = 0.0

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func meter(scope: String = "qa-loopback", control: Bool = true) -> UsageMeter {
        UsageMeter(directory: directory, transport: recorder, consentScope: scope, canChangeConsent: control,
                   day: { self.day }, uptime: { self.uptime })
    }

    func testDenyByDefaultScopeAndOwner() {
        let main = meter()
        let wrapper = meter(control: false)
        wrapper.setConsent(true)
        wrapper.recordNativeSession()
        wrapper.sendPending()
        wrapper.settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        main.setConsent(true)
        main.settle()
        let other = meter(scope: "other", control: false)
        other.recordNativeSession()
        other.settle()
        wrapper.recordNativeSession()
        wrapper.settle()
        main.sendPending()
        main.settle()
        XCTAssertEqual(recorder.reports, [.init(foregroundSessions: 0, activeMinutes: 0, nativeSessions: 1)])
    }

    func testWithdrawalPurgesAndFencesExistingWrapper() {
        let main = meter()
        let wrapper = meter(control: false)
        main.setConsent(true)
        main.settle()
        wrapper.setForeground(true)
        wrapper.recordNativeSession()
        wrapper.settle()
        main.setConsent(false)
        main.settle()
        wrapper.tick()
        wrapper.sendPending()
        wrapper.settle()
        XCTAssertTrue(recorder.reports.isEmpty)
        main.setConsent(true)
        main.recordNativeSession()
        main.settle()
        uptime = 4000
        wrapper.tick()
        wrapper.sendPending()
        wrapper.settle()
        XCTAssertEqual(recorder.reports, [.init(foregroundSessions: 0, activeMinutes: 0, nativeSessions: 1)])
    }

    func testClippingAndRolloverTickDefersDeliveryUntilForegroundTransition() throws {
        let main = meter()
        main.setConsent(true)
        main.setForeground(true)
        main.settle()
        for _ in 0..<130 {
            uptime += 180
            main.tick()
            main.settle()
        }
        for _ in 0..<10 {
            main.setForeground(false)
            main.settle()
            uptime += 1800
            main.setForeground(true)
            main.recordNativeSession()
            main.settle()
        }
        XCTAssertTrue(recorder.reports.isEmpty)
        day += 1
        main.tick()
        main.settle()
        XCTAssertTrue(recorder.reports.isEmpty, "A rollover tick must only sample")
        main.setForeground(true)
        main.settle()
        XCTAssertTrue(recorder.reports.isEmpty, "Reaffirming the current state is not a transition")
        main.setForeground(false)
        main.settle()
        XCTAssertEqual(recorder.reports.count, 1)
        let report = try XCTUnwrap(recorder.reports.first)
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: Int],
                       ["foreground_sessions": 8, "active_minutes": 120, "native_sessions": 8])
        let restarted = meter()
        restarted.recordNativeSession()
        restarted.sendPending()
        restarted.settle()
        XCTAssertEqual(recorder.reports.count, 1)
        day -= 1
        restarted.sendPending()
        restarted.settle()
        XCTAssertEqual(recorder.reports.count, 1)
    }

    func testParallelDrainAndExpiry() {
        let main = meter()
        main.setConsent(true)
        main.recordNativeSession()
        main.settle()
        let clients = (0..<10).map { _ in meter(control: false) }
        clients.forEach { $0.sendPending() }
        clients.forEach { $0.settle() }
        XCTAssertEqual(recorder.reports.count, 1)
        main.recordNativeSession()
        main.settle()
        day += 8
        main.tick()
        main.settle()
        XCTAssertEqual(recorder.reports.count, 1)
    }

    func testDeferredSocketRechecksConsentRevision() {
        let main = meter()
        let wrapper = meter(control: false)
        main.setConsent(true)
        main.settle()
        recorder.delay = true
        wrapper.recordNativeSession()
        wrapper.sendPending()
        wrapper.settle()
        XCTAssertNotNil(recorder.deferred)
        main.setConsent(false)
        main.setConsent(true)
        main.settle()
        recorder.deferred?()
        XCTAssertTrue(recorder.reports.isEmpty)
    }

    func testPrivateLedgerCreationReplacementAndLegacyModeRepair() throws {
        let main = meter()
        main.setConsent(true)
        main.settle()
        let file = directory.appendingPathComponent("aggregate-v1.json")
        let lock = directory.appendingPathComponent("usage.lock")
        func mode(_ url: URL) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(lock), 0o600)
        main.recordNativeSession()
        main.settle()
        XCTAssertEqual(try mode(file), 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path)
        main.tick()
        main.settle()
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(lock), 0o600)
    }

    private func consentResult(_ operation: (@escaping (UsageConsentResult) -> Void) -> Void) throws -> UsageConsentResult {
        let done = expectation(description: "durable permission result")
        var result: UsageConsentResult?
        operation { value in result = value; done.fulfill() }
        wait(for: [done], timeout: 1)
        return try XCTUnwrap(result)
    }

    func testHeldAccountingLockCannotPreventWithdrawalOrReviveDeferredSend() throws {
        let main = meter()
        let wrapper = meter(control: false)
        XCTAssertEqual(try consentResult { main.setConsent(true, completion: $0) }.status, .enabled)
        let marker = directory.appendingPathComponent("permission-v1")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as? Int, 0o600)
        recorder.delay = true
        wrapper.recordNativeSession()
        wrapper.sendPending()
        wrapper.settle()
        XCTAssertNotNil(recorder.deferred)
        let fd = open(directory.appendingPathComponent("usage.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let withdrawn = try consentResult { main.setConsent(false, completion: $0) }
        XCTAssertEqual(withdrawn.status, .disabled)
        XCTAssertTrue(withdrawn.purgePending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try consentResult { meter().readConsentStatus($0) }.status, .disabled)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertEqual(try consentResult { main.setConsent(true, completion: $0) }.status, .enabled)
        recorder.deferred?()
        XCTAssertTrue(recorder.reports.isEmpty)
    }

    func testMissingLegacyPermissionAndInaccessibleAuthorityFailClosed() throws {
        let main = meter()
        main.setConsent(true)
        main.recordNativeSession()
        main.settle()
        let marker = directory.appendingPathComponent("permission-v1")
        try FileManager.default.removeItem(at: marker)
        let wrapper = meter(control: false)
        wrapper.sendPending()
        wrapper.settle()
        XCTAssertTrue(recorder.reports.isEmpty)
        XCTAssertEqual(try consentResult { wrapper.readConsentStatus($0) }.status, .disabled)
        XCTAssertEqual(try consentResult { main.setConsent(true, completion: $0) }.status, .enabled)
        main.sendPending()
        main.settle()
        XCTAssertTrue(recorder.reports.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: marker.path)
        XCTAssertEqual(try consentResult { wrapper.readConsentStatus($0) }.status, .unavailable)
        wrapper.recordNativeSession()
        wrapper.sendPending()
        wrapper.settle()
        XCTAssertTrue(recorder.reports.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertEqual(try consentResult { main.setConsent(false, completion: $0) }.status, .unavailable)
        XCTAssertEqual(try consentResult { wrapper.readConsentStatus($0) }.status, .unavailable)
    }

    func testInvalidAccountingLockStillRemovesPermission() throws {
        let main = meter()
        main.setConsent(true)
        main.settle()
        let lock = directory.appendingPathComponent("usage.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let result = try consentResult { main.setConsent(false, completion: $0) }
        XCTAssertEqual(result.status, .disabled)
        XCTAssertTrue(result.purgePending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("permission-v1").path))
    }

    func testCorruptAggregateIsPurgedAndCannotRevivePriorGrant() throws {
        let main = meter()
        main.setConsent(true)
        main.recordNativeSession()
        recorder.delay = true
        main.sendPending()
        main.settle()
        XCTAssertNotNil(recorder.deferred)
        let ledger = directory.appendingPathComponent("aggregate-v1.json")
        try Data("invalid".utf8).write(to: ledger)
        let result = try consentResult { main.setConsent(false, completion: $0) }
        XCTAssertEqual(result.status, .disabled)
        XCTAssertFalse(result.purgePending)
        XCTAssertEqual(try consentResult { main.setConsent(true, completion: $0) }.status, .enabled)
        recorder.deferred?()
        XCTAssertTrue(recorder.reports.isEmpty)
        recorder.delay = false
        main.recordNativeSession()
        main.sendPending()
        main.settle()
        XCTAssertTrue(recorder.reports.isEmpty)
    }

    func testEndpointPolicyWithoutNetwork() {
        XCTAssertNotNil(ProductionUsageTransport(approvedEndpoint: URL(string: "https://usage.sloopworks.com/v1/droidbridge/usage")!))
        for invalid in ["https://usage.example.com", "https://usage.sloopworks.com:443", "https://u:p@usage.sloopworks.com", "http://usage.sloopworks.com", "https://usage.sloopworks.com?foo=bar", "https://usage.sloopworks.com#ignored", "http://example.com", "https://u:p@example.com", "https://example.com:443",
                        "https://example.com/path", "https://example.com?x=", "https://example.com#x"] {
            XCTAssertNil(ProductionUsageTransport(approvedEndpoint: URL(string: invalid + "/v1/droidbridge/usage")!))
        }
    }
}
