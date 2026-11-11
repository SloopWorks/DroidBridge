import XCTest
@testable import DroidBridgeCore

final class CompanionWirelessADBTests: XCTestCase {
    func testQRUsesAndroidFormatAndFreshIndependentCredentials() {
        let first = CompanionWirelessQRInvitation(), second = CompanionWirelessQRInvitation()
        let format = #"^WIFI:T:ADB;S:studio-[0-9a-f]{24};P:[0-9a-f]{32};;$"#
        XCTAssertTrue(first.payload.range(of: format, options: .regularExpression) != nil)
        XCTAssertTrue(second.payload.range(of: format, options: .regularExpression) != nil)
        XCTAssertTrue(first.serviceInstance != second.serviceInstance)
        XCTAssertTrue(first.payload.components(separatedBy: ";P:").last != second.payload.components(separatedBy: ";P:").last)
    }

    func testBrowseMatchesOnlySelectedPairingOrRememberedConnection() {
        let qr = "studio-0123456789abcdef01234567"
        XCTAssertTrue(CompanionWirelessBonjour.matches(qr, instance: qr, kind: .pairing))
        XCTAssertFalse(CompanionWirelessBonjour.matches(qr + " (2)", instance: qr, kind: .pairing))
        let guid = "adb-fixture-123ABC"
        for valid in [guid, guid + " (2)", guid + " (11)"] {
            XCTAssertTrue(CompanionWirelessBonjour.matches(valid, instance: guid, kind: .connection))
        }
        for invalid in [guid + "0", guid + " (02)", guid + " (bad)", "other-" + guid] {
            XCTAssertFalse(CompanionWirelessBonjour.matches(invalid, instance: guid, kind: .connection))
        }
    }

    func testSavedBonjourCandidatesPreferReplacementAndKeepStableBound() {
        typealias Address = CompanionWirelessBonjour.Address
        let stale = Address(host: "192.0.2.9", port: 37123, isIPv4: true)
        let replacement = Address(host: "192.0.2.9", port: 39123, isIPv4: true)
        let alternate = Address(host: "2001:db8::9", port: 39123, isIPv4: false)
        let another = Address(host: "192.0.2.5", port: 37123, isIPv4: true)
        XCTAssertEqual(CompanionWirelessBonjour.orderedSavedCandidates([stale: 0, replacement: 2, alternate: 2, another: 0]),
                       [replacement, alternate, another])
    }

    func testOnlyAcceptExactADBPairingReceiptAndWellFormedGUID() throws {
        let endpoint = try CompanionWirelessEndpoint("127.0.0.1:37123")
        let line = "Enter pairing code: Successfully paired to 127.0.0.1:37123 [guid=adb-fixture-123ABC]"
        XCTAssertEqual(try CompanionWirelessADB.pairedInstance(output: line, endpoint: endpoint), "adb-fixture-123ABC")
        for invalid in [line + "\n" + line, line.replacingOccurrences(of: "37123", with: "37124"), line.replacingOccurrences(of: "adb-fixture-123ABC", with: "adb-fixture-123ABC (2)"), "Successfully paired"] {
            XCTAssertThrowsError(try CompanionWirelessADB.pairedInstance(output: invalid, endpoint: endpoint))
        }
    }

    func testPairCodeUsesStdinAndIsRedactedFromReturnedOutput() async throws {
        let root = try fixture("""
        #!/bin/sh
        test "$#" -eq 2 || exit 2
        test "$1" = pair || exit 3
        test "$2" = 127.0.0.1:37123 || exit 4
        IFS= read -r code
        test "$code" = 123456 || exit 5
        printf 'Successfully paired [code %s]' "$code"
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await CompanionWirelessADB.pair(adb: root.appendingPathComponent("adb").path, endpoint: CompanionWirelessEndpoint("127.0.0.1:37123"), code: "123456")
        XCTAssertEqual(result, "Successfully paired [code [redacted]]")
        XCTAssertFalse(result.contains("123456"))
    }

    func testTimeoutAndCancellationFinishBoundedly() async throws {
        let root = try fixture("#!/bin/sh\nexec /bin/sleep 10\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try CompanionWirelessEndpoint("127.0.0.1:37123")
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await CompanionWirelessADB.connect(adb: root.appendingPathComponent("adb").path, endpoint: endpoint, timeout: 0.1)
            XCTFail("A hanging ADB process must time out")
        } catch { XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2) }
        let task = Task { try await CompanionWirelessADB.connect(adb: root.appendingPathComponent("adb").path, endpoint: endpoint) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled ADB setup must not succeed") }
        catch { XCTAssertTrue(error is CancellationError); XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3) }
    }

    func testConnectVerifiesExactTransportIDInsteadOfAnyReadyDevice() async throws {
        let root = try fixture("""
        #!/bin/sh
        case "$*" in
          'connect 127.0.0.1:37123') printf 'connected to 127.0.0.1:37123\\n' ;;
          'devices -l') printf 'List of devices attached\\nphone-usb device usb:123 transport_id:1\\n127.0.0.1:37123 device transport_id:42\\n' ;;
          '-t 42 shell getprop persist.adb.wifi.guid') : ;; # Stock API35 can hide this property.
          '-t 42 shell settings --user 0 get secure android_id') printf 'ab12cd34ef56ab78\\n' ;;
          *) exit 3 ;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let adb = root.appendingPathComponent("adb").path
        let endpoint = try CompanionWirelessEndpoint("127.0.0.1:37123")
        let fingerprint = try CompanionWirelessADB.fingerprint(androidID: "ab12cd34ef56ab78")
        let result = try await CompanionWirelessADB.connectPaired(adb: adb, endpoint: endpoint, serviceInstance: "adb-fixture-123ABC", expectedFingerprint: nil)
        XCTAssertEqual(result.serial, endpoint.argument)
        XCTAssertEqual(result.fingerprint, fingerprint)
        let present = try await CompanionWirelessADB.verifyConnected(adb: adb, serial: endpoint.argument, serviceInstance: "adb-fixture-123ABC", fingerprint: fingerprint)
        XCTAssertTrue(present)
        let absent = try await CompanionWirelessADB.verifyConnected(adb: adb, serial: "127.0.0.1:37124", serviceInstance: "adb-fixture-123ABC", fingerprint: fingerprint)
        XCTAssertFalse(absent)
    }

    func testMismatchedFingerprintUnwindsOnlyNewlyOpenedEndpoint() async throws {
        for existing in [false, true] {
            let root = try fixture("""
            #!/bin/sh
            case "$*" in
              'connect 127.0.0.1:37123') printf '\(existing ? "already " : "")connected to 127.0.0.1:37123\\n' ;;
              'devices -l') printf 'List of devices attached\\n127.0.0.1:37123 device transport_id:42\\n' ;;
              '-t 42 shell getprop persist.adb.wifi.guid') printf 'adb-fixture-123ABC\\n' ;;
              '-t 42 shell settings --user 0 get secure android_id') printf '12345678abcdef12\\n' ;;
              'disconnect 127.0.0.1:37123') touch "${0%/*}/disconnected" ;;
              *) exit 3 ;;
            esac
            """)
            defer { try? FileManager.default.removeItem(at: root) }
            let adb = root.appendingPathComponent("adb").path
            let endpoint = try CompanionWirelessEndpoint("127.0.0.1:37123")
            do {
                _ = try await CompanionWirelessADB.connectPaired(adb: adb, endpoint: endpoint, serviceInstance: "adb-fixture-123ABC", expectedFingerprint: CompanionWirelessADB.fingerprint(androidID: "ab12cd34ef56ab78"))
                XCTFail("A connection with the wrong identity must not succeed")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("did not identify"))
                XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("disconnected").path), !existing)
            }
        }
    }

    func testSavedReconnectChecksOverlappingAddressesUntilOneIsVerified() async throws {
        let root = try fixture("""
        #!/bin/sh
        printf '%s\\n' "$*" >> "${0%/*}/calls"
        case "$*" in
          'connect 127.0.0.1:37123') printf 'failed to connect\\n' ;;
          'connect 127.0.0.1:37124') printf 'connected to 127.0.0.1:37124\\n' ;;
          'connect 127.0.0.1:37125') printf 'connected to 127.0.0.1:37125\\n' ;;
          'devices -l') printf '127.0.0.1:37124 device transport_id:42\\n127.0.0.1:37125 device transport_id:43\\n' ;;
          '-t 42 shell getprop persist.adb.wifi.guid'|'-t 43 shell getprop persist.adb.wifi.guid') printf 'adb-fixture-123ABC\\n' ;;
          '-t 42 shell settings --user 0 get secure android_id') printf '12345678abcdef12\\n' ;;
          '-t 43 shell settings --user 0 get secure android_id') printf 'ab12cd34ef56ab78\\n' ;;
          'disconnect 127.0.0.1:37124') : ;;
          *) exit 3 ;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let addresses = try [37123, 37124, 37124, 37125].map { try CompanionWirelessEndpoint("127.0.0.1:\($0)") }
        let result = try await CompanionWirelessADB.connectSavedCandidates(adb: root.appendingPathComponent("adb").path, serviceInstance: "adb-fixture-123ABC",
                                                                            fingerprint: CompanionWirelessADB.fingerprint(androidID: "ab12cd34ef56ab78"), candidates: addresses)
        XCTAssertEqual(result.serial, "127.0.0.1:37125")
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8).split(whereSeparator: \.isNewline)
        XCTAssertEqual(calls.filter { $0.hasPrefix("connect ") || $0.hasPrefix("disconnect ") },
                       ["connect 127.0.0.1:37123", "connect 127.0.0.1:37124", "disconnect 127.0.0.1:37124", "connect 127.0.0.1:37125"])
    }

    func testFingerprintRejectsMissingAndMalformedAndroidIDs() throws {
        let digest = try CompanionWirelessADB.fingerprint(androidID: "ab12cd34ef56ab78")
        XCTAssertNoThrow(try CompanionWirelessADB.validateFingerprint(digest))
        XCTAssertEqual(digest, try CompanionWirelessADB.fingerprint(androidID: "AB12CD34EF56AB78"))
        XCTAssertEqual(try CompanionWirelessADB.fingerprint(androidID: "a7"), try CompanionWirelessADB.fingerprint(androidID: "00000000000000a7"))
        XCTAssertNotEqual(digest, "ab12cd34ef56ab78")
        for value in ["", "null", "0000000000000000", "bad12cd34ef56ab78", "ab12cd34ef56ab7g"] {
            XCTAssertThrowsError(try CompanionWirelessADB.fingerprint(androidID: value))
        }
    }

    func testAmbiguousAndOfflineADBRowsCannotAuthorizeAProbe() {
        let serial = "127.0.0.1:37123"
        XCTAssertNil(CompanionWirelessADB.readyTransportID("\(serial) offline transport_id:42", serial: serial))
        XCTAssertNil(CompanionWirelessADB.readyTransportID("\(serial) device transport_id:42\n\(serial) device transport_id:43", serial: serial))
        XCTAssertNil(CompanionWirelessADB.readyTransportID("\(serial) device transport_id:42 transport_id:43", serial: serial))
    }

    private func fixture(_ script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wireless-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("adb")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return root
    }
}
