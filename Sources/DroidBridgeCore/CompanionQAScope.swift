import Foundation
import CryptoKit
import Darwin

/// Explicit, isolated installed-app verification. It changes storage and the
/// owned emulator cohort, never authentication or Android readiness policy.
public struct CompanionQAScope: Sendable {
    public let root: URL
    public let serial: String
    public static let current: Self? = try? parse(arguments: ProcessInfo.processInfo.arguments)

    public static func parse(arguments: [String]) throws -> Self? {
        let roots = arguments.indices.filter { arguments[$0] == "--companion-qa-root" }
        guard !roots.isEmpty else { return nil }
        let serials = arguments.indices.filter { arguments[$0] == "--serial" }
        guard roots.count == 1, serials.count == 1, roots[0] + 1 < arguments.count, serials[0] + 1 < arguments.count else { throw BridgeError.message("Companion QA requires one private root and one owned emulator serial.") }
        let path = arguments[roots[0] + 1], serial = arguments[serials[0] + 1]
        guard ["emulator-5580", "emulator-5582"].contains(serial), path.hasPrefix("/"), path.utf8.count <= 2048,
              path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw BridgeError.message("Companion QA accepts only a canonical absolute root and emulator-5580 or emulator-5582.") }
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700,
              let resolved = realpath(path, nil) else { throw BridgeError.message("Companion QA root must already exist, be owned by this user, and have mode 700.") }
        defer { free(resolved) }
        guard String(cString: resolved) == path else { throw BridgeError.message("Companion QA root cannot use a symbolic-link alias.") }
        return Self(root: URL(fileURLWithPath: path, isDirectory: true), serial: serial)
    }
    public var serviceSuffix: String { SHA256.hash(data: Data(root.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() }
    public var keychainServiceSuffix: String { ".qa." + serviceSuffix }
    public var preferencesURL: URL { root.appendingPathComponent("preferences.json") }
    public var audioDirectory: URL { root.appendingPathComponent("AudioRoutes.noindex", isDirectory: true) }
    public var receiptDirectory: URL { root.appendingPathComponent("SessionReceipts", isDirectory: true) }
    public var iconReceiptDirectory: URL { root.appendingPathComponent("IconReceipts", isDirectory: true) }
    public var logDirectory: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var sessionsURL: URL { root.appendingPathComponent("sessions.json") }
    public var brokerDirectory: URL { root.appendingPathComponent("CompanionBroker", isDirectory: true) }
    public var managedPaths: ManagedAppsPaths { ManagedAppsPaths(privateRoot: root.appendingPathComponent("ManagedApps.noindex"), activeRoot: root.appendingPathComponent("Applications")) }
    public func filterDevices(_ devices: [AndroidDevice]) -> [AndroidDevice] { devices.filter { $0.serial == serial } }
}
