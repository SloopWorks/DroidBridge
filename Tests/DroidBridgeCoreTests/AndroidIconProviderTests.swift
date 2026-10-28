import XCTest
import CoreGraphics
import ImageIO
@testable import DroidBridgeCore

final class AndroidIconProviderTests: XCTestCase {
    private func png(width: Int = 512, height: Int = 512) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testPNGValidationRejectsMalformedAndWrongDimensions() throws {
        XCTAssertNoThrow(try AndroidIconProvider.validatePNG(png()))
        XCTAssertThrowsError(try AndroidIconProvider.validatePNG(png(width: 256)))
        XCTAssertThrowsError(try AndroidIconProvider.validatePNG(Data([137, 80, 78, 71, 13, 10, 26, 10] + Array(repeating: 0, count: 100))))
        XCTAssertThrowsError(try AndroidIconProvider.validatePNG(Data(repeating: 0, count: 2 * 1024 * 1024 + 1)))
    }

    func testProviderCleansOwnedFilesOnSuccessAndHelperFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-icon-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("source.png"), helper = root.appendingPathComponent("helper.jar"), adb = root.appendingPathComponent("adb"), log = root.appendingPathComponent("argv.log")
        let receipts = root.appendingPathComponent("receipts")
        try png().write(to: image); try Data("test helper".utf8).write(to: helper)
        func script(fail: Bool) throws {
            let body = """
            #!/bin/bash
            printf '%s\\n' "$*" >> '\(log.path)'
            if [[ "$3" == push ]]; then [[ -n "$(/usr/bin/find '\(receipts.path)' -name '*.json' -print -quit)" ]] || exit 9; fi
            if [[ "$3" == pull ]]; then /bin/cp '\(image.path)' "$5"; fi
            if [[ "$3" == shell && "$5" == app_process ]]; then exit \(fail ? 1 : 0); fi
            exit 0
            """
            try body.write(to: adb, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        }
        try script(fail: false)
        let provider = AndroidIconProvider(toolchain: Toolchain(adb: adb.path), helperPath: helper.path, receiptDirectoryURL: receipts)
        let device = AndroidDevice(serial: "emulator-5580", model: "Fixture")
        let application = AndroidApplication(packageName: "dev.droidbridge.iconfixture", name: "Fixture")
        let result = try await provider.icon(device: device, application: application)
        XCTAssertEqual(result, try png())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: receipts.path).filter { $0.hasSuffix(".json") }.isEmpty)
        var lines = try String(contentsOf: log).split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.last!.contains("shell rm -f /data/local/tmp/droidbridge-icon-"))
        XCTAssertTrue(lines.last!.contains(".jar /data/local/tmp/droidbridge-icon-"))
        try script(fail: true)
        do { _ = try await provider.icon(device: device, application: application); XCTFail("Must propagate helper failure") } catch {}
        lines = try String(contentsOf: log).split(separator: "\n")
        XCTAssertEqual(lines.count, 7)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: receipts.path).filter { $0.hasSuffix(".json") }.isEmpty)
        XCTAssertTrue(lines.last!.contains("shell rm -f"))
        do { _ = try await provider.icon(device: device, application: AndroidApplication(packageName: "com.bad;touch", name: "Bad")); XCTFail("Must reject shell metacharacters") } catch {}
        XCTAssertEqual(try String(contentsOf: log).split(separator: "\n").count, 7)
    }

    func testRecoveryPreservesLiveOwnerAndRetriesOfflineExactPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-icon-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipts = root.appendingPathComponent("receipts"), adb = root.appendingPathComponent("adb"), log = root.appendingPathComponent("argv.log"), offline = root.appendingPathComponent("offline")
        try Data().write(to: offline)
        let script = """
        #!/bin/bash
        printf '%s\\n' "$*" >> '\(log.path)'
        if [[ "$1" == devices ]]; then
            if [[ -f '\(offline.path)' ]]; then printf 'emulator-5580 offline\\n'; else printf 'emulator-5580 device\\n'; fi
            exit 0
        fi
        [[ ! -f '\(offline.path)' ]] || exit 1
        exit 0
        """
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try child.run(); child.waitUntilExit()
        let dead = IconRequestReceipt(ownerPID: child.processIdentifier, serial: "emulator-5580", identity: UUID())
        let deadURL = try dead.save(directory: receipts)
        let active = IconRequestReceipt(ownerPID: getpid(), serial: "emulator-5580", identity: UUID())
        let activeURL = try active.save(directory: receipts)
        let invalid = IconRequestReceipt(ownerPID: child.processIdentifier, serial: "bad;reboot", identity: UUID())
        let invalidURL = try invalid.save(directory: receipts)
        let mismatchedURL = receipts.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try JSONEncoder().encode(dead).write(to: mismatchedURL)
        let oversizedURL = receipts.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try Data(repeating: 0, count: 4097).write(to: oversizedURL)
        let tools = Toolchain(adb: adb.path)
        let failed = await AndroidIconProvider.recoverAbandonedRequests(toolchain: tools, receiptDirectoryURL: receipts)
        XCTAssertTrue(failed.contains { $0.contains("retained") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: deadURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidURL.path))
        try FileManager.default.removeItem(at: offline)
        let recovered = await AndroidIconProvider.recoverAbandonedRequests(toolchain: tools, receiptDirectoryURL: receipts)
        XCTAssertTrue(recovered.contains { $0.contains("Recovered abandoned") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: deadURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mismatchedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oversizedURL.path))
        let lines = try String(contentsOf: log).split(separator: "\n")
        let removals = lines.filter { $0.contains("shell rm -f") }
        XCTAssertEqual(removals.count, 1)
        let expected = "-s emulator-5580 shell rm -f \(dead.remoteJar) \(dead.remotePNG)"
        XCTAssertTrue(removals.allSatisfy { $0 == expected })
        XCTAssertFalse(lines.contains { $0.contains(active.identity.uuidString.lowercased()) })
        XCTAssertFalse(lines.contains { $0.contains("reboot") })
    }

    func testFailedRequestCleanupRetainsReceiptUntilRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-icon-offline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipts = root.appendingPathComponent("receipts"), adb = root.appendingPathComponent("adb"), helper = root.appendingPathComponent("helper.jar"), offline = root.appendingPathComponent("offline")
        try Data().write(to: helper); try Data().write(to: offline)
        let script = """
        #!/bin/bash
        if [[ "$1" == devices ]]; then printf 'emulator-5580 device\\n'; exit 0; fi
        [[ ! -f '\(offline.path)' ]] || exit 1
        exit 0
        """
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let tools = Toolchain(adb: adb.path)
        let provider = AndroidIconProvider(toolchain: tools, helperPath: helper.path, receiptDirectoryURL: receipts)
        do { _ = try await provider.icon(device: AndroidDevice(serial: "emulator-5580", model: "Fixture"), application: AndroidApplication(packageName: "com.android.settings", name: "Settings")); XCTFail("Offline push must fail") } catch {}
        let saved = try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil)
        XCTAssertEqual(saved.count, 1)
        let url = try XCTUnwrap(saved.first)
        let receipt = try JSONDecoder().decode(IconRequestReceipt.self, from: Data(contentsOf: url))
        XCTAssertEqual(receipt.ownerPID, getpid()); XCTAssertEqual(receipt.serial, "emulator-5580")
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try child.run(); child.waitUntilExit()
        _ = try IconRequestReceipt(ownerPID: child.processIdentifier, serial: receipt.serial, identity: receipt.identity).save(directory: receipts)
        try FileManager.default.removeItem(at: offline)
        let messages = await AndroidIconProvider.recoverAbandonedRequests(toolchain: tools, receiptDirectoryURL: receipts)
        XCTAssertEqual(messages.count, 1); XCTAssertTrue(messages[0].contains("Recovered abandoned"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: receipts.path).filter { $0.hasSuffix(".json") }.isEmpty)
    }

    func testConcurrentRecoveryReturnsCanonicalCompletedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-icon-concurrent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipts = root.appendingPathComponent("receipts"), adb = root.appendingPathComponent("adb")
        let script = """
        #!/bin/bash
        if [[ "$1" == devices ]]; then printf 'emulator-5580 device\\n'; exit 0; fi
        /bin/sleep 0.1
        exit 0
        """
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try child.run(); child.waitUntilExit()
        _ = try IconRequestReceipt(ownerPID: child.processIdentifier, serial: "emulator-5580", identity: UUID()).save(directory: receipts)
        let tools = Toolchain(adb: adb.path)
        async let first = AndroidIconProvider.recoverAbandonedRequests(toolchain: tools, receiptDirectoryURL: receipts)
        async let second = AndroidIconProvider.recoverAbandonedRequests(toolchain: tools, receiptDirectoryURL: receipts)
        let messages = await [first, second]
        XCTAssertTrue(messages.allSatisfy { $0.count == 1 && $0[0].contains("Recovered abandoned") }, "\(messages)")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: receipts.path).filter { $0.hasSuffix(".json") }.isEmpty)
    }

    func testRecoveryWaitsForExactDelayedProducerBeforeRemovingReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-icon-producer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipts = root.appendingPathComponent("receipts"), adb = root.appendingPathComponent("adb"), marker = root.appendingPathComponent("remote.jar"), writer = root.appendingPathComponent("writer.sh"), release = root.appendingPathComponent("release"), log = root.appendingPathComponent("argv.log")
        let script = """
        #!/bin/bash
        printf '%s\\n' "$*" >> '\(log.path)'
        if [[ "$1" == devices ]]; then printf 'emulator-5580 device\\n'; exit 0; fi
        /bin/rm -f '\(marker.path)'
        """
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        try "while [[ ! -f '\(release.path)' ]]; do /bin/sleep 0.02; done; /usr/bin/touch '\(marker.path)'\n".write(to: writer, atomically: true, encoding: .utf8)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try child.run(); child.waitUntilExit()
        let dead = IconRequestReceipt(ownerPID: child.processIdentifier, serial: "emulator-5580", identity: UUID())
        let receiptURL = try dead.save(directory: receipts)
        let producer = Process(); producer.executableURL = URL(fileURLWithPath: "/bin/bash")
        producer.arguments = [writer.path, "-s", dead.serial, "push", dead.remoteJar, dead.remotePNG]
        try producer.run()
        defer { if producer.isRunning { producer.terminate() } }
        let tools = Toolchain(adb: adb.path)
        let held = await AndroidIconProvider.recoverAbandonedRequests(toolchain: tools, receiptDirectoryURL: receipts)
        XCTAssertTrue(held.contains { $0.contains("exact producer is still running") }, "\(held)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "Must not issue cleanup before the delayed writer finishes")
        try Data().write(to: release)
        while producer.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(producer.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The delayed producer must actually write after the first recovery pass")
        let recovered = await AndroidIconProvider.recoverAbandonedRequests(toolchain: tools, receiptDirectoryURL: receipts)
        XCTAssertTrue(recovered.contains { $0.contains("Recovered abandoned") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertTrue(try String(contentsOf: log).contains("-s \(dead.serial) shell rm -f \(dead.remoteJar) \(dead.remotePNG)"))
    }

    func testBoundedRecoveryCursorReachesReceiptAfter128RetainedRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-icon-cursor-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipts = root.appendingPathComponent("receipts"), adb = root.appendingPathComponent("adb")
        let script = """
        #!/bin/bash
        if [[ "$1" == devices ]]; then printf 'emulator-5580 device\\n'; fi
        exit 0
        """
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try child.run(); child.waitUntilExit()
        for value in 0..<128 {
            let uuid = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value)))
            _ = try IconRequestReceipt(ownerPID: child.processIdentifier, serial: "offline-serial", identity: uuid).save(directory: receipts)
        }
        let target = IconRequestReceipt(ownerPID: child.processIdentifier, serial: "emulator-5580", identity: try XCTUnwrap(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")))
        let targetURL = try target.save(directory: receipts)
        let tools = Toolchain(adb: adb.path)
        let first = await AndroidIconProvider.recoverAbandonedRequests(toolchain: tools, receiptDirectoryURL: receipts)
        XCTAssertLessThanOrEqual(first.count, 16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path), "The first bounded pass must not process receipt 129")
        let second = await AndroidIconProvider.recoverAbandonedRequests(toolchain: tools, receiptDirectoryURL: receipts)
        XCTAssertLessThanOrEqual(second.count, 16)
        XCTAssertTrue(second.contains { $0.contains("Recovered abandoned") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path), "The rotating cursor must admit the later eligible receipt")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: receipts.path).filter { $0.hasSuffix(".json") }.count, 128)
    }

    func testLiveAdaptiveAliasAndSystemIconsWhenOptedIn() async throws {
        guard let serial = ProcessInfo.processInfo.environment["DROIDBRIDGE_TEST_SERIAL"],
              ProcessInfo.processInfo.environment["DROIDBRIDGE_TEST_ICONS"] == "1" else { throw XCTSkip("Build icon helper and install icon fixture, then set DROIDBRIDGE_TEST_SERIAL and DROIDBRIDGE_TEST_ICONS=1") }
        let device = AndroidDevice(serial: serial, model: "Icon test emulator")
        let provider = AndroidIconProvider()
        let before = try await ProcessRunner.run(Toolchain().adb, arguments: ["-s", serial, "shell", "find", "/data/local/tmp", "-maxdepth", "1", "-name", "droidbridge-icon-*"])
        let baseline = Set(before.output.split(separator: "\n").map(String.init))
        let infoEntry = try await ProcessRunner.run(Toolchain().adb, arguments: ["-s", serial, "shell", "cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.INFO", "dev.droidbridge.iconfixture"])
        XCTAssertTrue(infoEntry.output.contains(".InfoAlias"), infoEntry.output)
        let alias = try await provider.icon(device: device, application: AndroidApplication(packageName: "dev.droidbridge.iconfixture", name: "Alias"))
        let settings = try await provider.icon(device: device, application: AndroidApplication(packageName: "com.android.settings", name: "Settings"))
        XCTAssertNotEqual(alias, settings)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(alias as CFData, nil)), 0, nil))
        var pixels = [UInt8](repeating: 0, count: 512 * 512 * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 2048, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        let middle = (256 * 512 + 256) * 4
        // Alias foreground is yellow. Application-level vector icon is blue:
        // this asserts the activity alias is honored, beyond merely valid PNG.
        // A separately resolved CATEGORY_INFO entry is blue, so INFO must not win.
        XCTAssertGreaterThan(pixels[middle], 240); XCTAssertGreaterThan(pixels[middle + 1], 180); XCTAssertLessThan(pixels[middle + 2], 20)
        do { _ = try await provider.icon(device: device, application: AndroidApplication(packageName: "dev.droidbridge.missing", name: "Missing")); XCTFail("Missing app must fail") } catch {}
        let remaining = try await ProcessRunner.run(Toolchain().adb, arguments: ["-s", serial, "shell", "find", "/data/local/tmp", "-maxdepth", "1", "-name", "droidbridge-icon-*"])
        let leaked = Set(remaining.output.split(separator: "\n").map(String.init)).subtracting(baseline)
        XCTAssertTrue(leaked.isEmpty, "This test's requests left new temporary files: \(leaked.sorted())")
    }
}
