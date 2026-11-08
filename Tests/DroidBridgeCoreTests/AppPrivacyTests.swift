import XCTest
import AppKit
import Darwin
@testable import DroidBridgeCore

final class AppPrivacyTests: XCTestCase {
    /// Stream only a fixture-ID match; the full user's LS inventory never enters logs.
    func registered(_ identifier: String) async throws -> Bool {
        try await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: WrapperBackup.registrationTool)
            process.arguments = ["-dump"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
            defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
            var tail = "", found = false, size = 0
            while let data = try pipe.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
                size += data.count
                guard size <= 128 * 1024 * 1024 else { process.terminate(); throw BridgeError.message("Launch Services dump exceeded fixture bound") }
                let text = tail + String(decoding: data, as: UTF8.self)
                found = found || text.contains(identifier)
                tail = String(text.suffix(identifier.count))
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw BridgeError.message("Launch Services fixture dump failed") }
            return found
        }.value
    }
    func thin(seed: UInt8 = 1) -> Data {
        var data = Data([0xcf,0xfa,0xed,0xfe] + Array(repeating: 0, count: 28))
        data[16] = 1; data[20] = 24
        data.append(contentsOf: [0x1b,0,0,0,24,0,0,0] + Array(repeating: seed, count: 16))
        return data
    }
    func testUUIDIsolationAndStrictParsing() throws {
        let source = thin()
        let first = try AppBinaryIdentity.personalized(source, identifier: "app.example.one")
        XCTAssertEqual(first, try AppBinaryIdentity.personalized(source, identifier: "app.example.one"))
        XCTAssertNotEqual(first, try AppBinaryIdentity.personalized(source, identifier: "app.example.two"))
        XCTAssertNotEqual(first, try AppBinaryIdentity.personalized(thin(seed: 2), identifier: "app.example.one"))
        XCTAssertEqual(first.prefix(40), source.prefix(40))
        XCTAssertEqual(try AppBinaryIdentity.uuidOffsets(first), [40])
        for count in [0, 4, 27, 31, 39, 55] {
            XCTAssertThrowsError(try AppBinaryIdentity.personalized(source.prefix(count), identifier: "app.example.one"))
        }
        var wrong = source; wrong[20] = 23
        XCTAssertThrowsError(try AppBinaryIdentity.personalized(wrong, identifier: "app.example.one"))
        wrong = source; wrong[36] = 0xff
        XCTAssertThrowsError(try AppBinaryIdentity.personalized(wrong, identifier: "app.example.one"))
    }
    func testUniversalSlicesAndOverlaps() throws {
        // Big-endian FAT header, two 64-bit little-endian Mach-O slices.
        var fat = Data([0xca,0xfe,0xba,0xbe,0,0,0,2])
        for offset: UInt8 in [48, 104] {
            fat.append(Data([0,0,0,0,0,0,0,0,0,0,0,offset,0,0,0,56,0,0,0,0]))
        }
        fat.append(thin()); fat.append(thin(seed: 2))
        let result = try AppBinaryIdentity.personalized(fat, identifier: "app.example.universal")
        XCTAssertEqual(try AppBinaryIdentity.uuidOffsets(result), [88,144])
        XCTAssertNotEqual(result[88..<104], result[144..<160])
        fat[39] = 48
        XCTAssertThrowsError(try AppBinaryIdentity.personalized(fat, identifier: "app.example.universal"))
    }
    func testSignedPayloadProvenance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppIdentity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), app = root.appendingPathComponent("app")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: source)
        try FileManager.default.copyItem(at: source, to: app)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.path)
        try AppBinaryIdentity.personalize(app, identifier: "app.example.one")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: app.path)[.posixPermissions] as? NSNumber)?.intValue, 0o555)
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", "--identifier", "app.example.one", app.path])
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--strict", app.path])
        let matches = try await AppBinaryIdentity.matches(app, source: source, identifier: "app.example.one")
        XCTAssertTrue(matches)
        let other = try await AppBinaryIdentity.matches(app, source: source, identifier: "app.example.two")
        XCTAssertFalse(other)
        XCTAssertNotEqual(try Data(contentsOf: source), try Data(contentsOf: app))
    }
    func testRetiredBackupRestoresExactMetadataAndRejectsSymlinks() throws {
        // Use /private/tmp lexically: /tmp itself is a macOS symlink.
        let root = URL(fileURLWithPath: "/private/tmp/BackupIdentity-" + UUID().uuidString)
        let app = root.appendingPathComponent("Example.app")
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":"app.droidbridge.wrapper.dev.example.test", "CFBundleExecutable":"DroidBridge", "CFBundlePackageType":"APPL"], format: .xml, options: 0)
        try info.write(to: infoURL)
        try JSONEncoder().encode(["package":"dev.example.test", "serial":"emulator-5580"]).write(to: app.appendingPathComponent("Contents/Resources/launch.json"))
        try WrapperBackup.retire(app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: infoURL.path))
        XCTAssertEqual(try Data(contentsOf: WrapperBackup.infoURL(app)), info)
        try WrapperBackup.retire(app) // Crash/retry is idempotent.
        try FileManager.default.moveItem(at: WrapperBackup.infoURL(app), to: infoURL)
        XCTAssertEqual(try Data(contentsOf: infoURL), info)
        let link = root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        XCTAssertThrowsError(try WrapperBackup.retire(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: infoURL.path))
    }
    func testADBChildBrowsingPolicyDoesNotChangeParentEnvironment() async throws {
        let original = ProcessInfo.processInfo.environment["ADB_MDNS"]
        let root = URL(fileURLWithPath: "/private/tmp/ADBPolicy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("adb")
        try Data("#!/bin/sh\nprintf '%s' \"$ADB_MDNS\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let result = try await ProcessRunner.run(fake.path, arguments: [], environment: ["ADB_MDNS":"1"])
        XCTAssertEqual(result.output, "0")
        let child = try await ProcessRunner.run("/usr/bin/printenv", arguments: ["ADB_MDNS"], environment: Toolchain().environment)
        XCTAssertEqual(child.output.trimmingCharacters(in: .whitespacesAndNewlines), "0")
        XCTAssertEqual(ProcessInfo.processInfo.environment["ADB_MDNS"], original)
    }

    func testLegacyBackupUnregistrationRemovesActualLaunchServicesRecord() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/LegacyBackup-" + UUID().uuidString)
        let directory = root.appendingPathComponent(".DroidBridge Backups")
        let app = directory.appendingPathComponent("Example-old.app")
        let identifier = "app.droidbridge.wrapper.dev.example.p" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let package = String(identifier.dropFirst("app.droidbridge.wrapper.".count))
        let executable = app.appendingPathComponent("Contents/MacOS/DroidBridge")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try AppBinaryIdentity.personalize(executable, identifier: identifier)
        let info: [String: Any] = ["CFBundleIdentifier":identifier, "CFBundleExecutable":"DroidBridge", "CFBundlePackageType":"APPL", "CFBundleName":"Backup retirement fixture", "CFBundleVersion":"1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try JSONEncoder().encode(["package":package, "serial":"emulator-5580"]).write(to: app.appendingPathComponent("Contents/Resources/launch.json"))
        let player = app.appendingPathComponent("Contents/Resources/Runtime/Player.app")
        let playerExecutable = player.appendingPathComponent("Contents/MacOS/scrcpy")
        try FileManager.default.createDirectory(at: playerExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: playerExecutable)
        try AppBinaryIdentity.personalize(playerExecutable, identifier: identifier + ".player")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":identifier + ".player", "CFBundleExecutable":"scrcpy", "CFBundlePackageType":"APPL", "CFBundleVersion":"1"], format: .xml, options: 0).write(to: player.appendingPathComponent("Contents/Info.plist"))
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", player.path])
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", app.path])
        _ = try await ProcessRunner.run(WrapperBackup.registrationTool, arguments: ["-f", app.path])
        _ = try await ProcessRunner.run(WrapperBackup.registrationTool, arguments: ["-f", player.path])
        let before = try await registered(identifier)
        XCTAssertTrue(before, "Fixture was not actually registered")
        let childBefore = try await registered(identifier + ".player")
        XCTAssertTrue(childBefore, "Nested Player fixture was not registered")
        let skipped = try await WrapperBackup.retireDirectory(directory, runningBundlePaths: [app.path])
        XCTAssertEqual(skipped.retired.count, 0)
        let completed = try await WrapperBackup.retireDirectory(directory, runningBundlePaths: [])
        XCTAssertEqual(completed.retired.count, 1)
        let after = try await registered(identifier)
        XCTAssertFalse(after, "Retired bundle remains in Launch Services")
        let childAfter = try await registered(identifier + ".player")
        XCTAssertFalse(childAfter, "Nested Player remains in Launch Services")
        try await WrapperBackup.unregister(app) // Already-absent parent and Player are retry-safe.
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
        let retry = try await WrapperBackup.retireDirectory(directory, runningBundlePaths: [])
        XCTAssertEqual(retry.retired.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: WrapperBackup.infoURL(app).path))
        for bundle in [app, player] {
            try FileManager.default.moveItem(at: WrapperBackup.infoURL(bundle), to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        try FileManager.default.removeItem(at: app.appendingPathComponent(".launch-services-unregistered"))
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path])
    }
}

extension ManagedAppsTests {
    func testBackupRetirementMigrationRetryAndRunningGuard() throws {
        let first = try catalog.reserve(device: device, application: application, backend: .native)
        try stage(first); let accepted = try catalog.commit(first)
        let next = try catalog.reserve(device: device, application: application, backend: .native)
        try stage(next); _ = try catalog.commit(next)
        let backup = paths.privateRoot.appendingPathComponent("backups/\(accepted.deviceHash)/\(accepted.packageName)-\(accepted.generation.uuidString).app")
        let normal = backup.appendingPathComponent("Contents/Info.plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: normal.path))
        let retired = WrapperBackup.infoURL(backup)
        try FileManager.default.moveItem(at: retired, to: normal) // Simulate a legacy generation.
        let foreign = backup.deletingLastPathComponent().appendingPathComponent("foreign.app")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        XCTAssertEqual(try catalog.retireBackups(runningBundlePaths: [backup.path]).retired, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: normal.path))
        let migration = try catalog.retireBackups(runningBundlePaths: [])
        XCTAssertEqual(migration.retired, [backup])
        XCTAssertFalse(migration.issues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: normal.path))
        // A crash after retirement but before the Launch Services receipt retries.
        XCTAssertEqual(try catalog.retireBackups(runningBundlePaths: []).retired, [backup])
        try catalog.completeBackupUnregistration(backup)
        XCTAssertEqual(try catalog.retireBackups(runningBundlePaths: []).retired, [])
        XCTAssertThrowsError(try catalog.completeBackupUnregistration(accepted.inactiveBundleURL))
    }
}
