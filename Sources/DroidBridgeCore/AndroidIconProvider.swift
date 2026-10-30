import Foundation
import ImageIO
import Darwin

/// Resolves the actual Android launcher Activity/alias icon using Android's own
/// drawable renderer. No APK parsing, root, installed helper, or network service.
public struct AndroidIconProvider {
    private let toolchain: Toolchain
    private let helperPath: String?
    private let receiptDirectoryURL: URL

    public init(toolchain: Toolchain = Toolchain(), helperPath: String? = nil, receiptDirectoryURL: URL? = nil) {
        self.toolchain = toolchain
        self.helperPath = helperPath
        self.receiptDirectoryURL = receiptDirectoryURL ?? Self.defaultReceiptDirectory
    }

    public func icon(device: AndroidDevice, application: AndroidApplication) async throws -> Data {
        try AndroidDiscovery.validateSerial(device.serial)
        try AndroidDiscovery.validatePackage(application.packageName)
        guard device.state == "device" else { throw BridgeError.message("Authorize and connect the Android device before creating its app icon.") }
        let helper = try resolveHelper()
        let receipt = IconRequestReceipt(ownerPID: getpid(), serial: device.serial, identity: UUID())
        let identity = receipt.identity.uuidString.lowercased()
        let remoteJar = receipt.remoteJar
        let remotePNG = receipt.remotePNG
        // Persist ownership before any remote write, so a host crash can recover
        // the exact request without sweeping another live app's temporary files.
        let receiptURL = try receipt.save(directory: receiptDirectoryURL)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-icon-\(identity).png")
        defer { try? FileManager.default.removeItem(at: local) }
        do {
            try Task.checkCancellation()
            _ = try await ProcessRunner.run(toolchain.adb, arguments: ["-s", device.serial, "push", helper, remoteJar], timeout: 20)
            try Task.checkCancellation()
            _ = try await ProcessRunner.run(toolchain.adb, arguments: ["-s", device.serial, "shell", "CLASSPATH=\(remoteJar)", "app_process", "/", "dev.droidbridge.icons.IconHelper", application.packageName, remotePNG], timeout: 25)
            try Task.checkCancellation()
            _ = try await ProcessRunner.run(toolchain.adb, arguments: ["-s", device.serial, "pull", remotePNG, local.path], timeout: 20)
            let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.intValue > 0, bytes.intValue <= 2 * 1024 * 1024 else {
                throw BridgeError.message("Android launcher icon exceeded its size limit.")
            }
            let png = try Data(contentsOf: local)
            try Self.validatePNG(png)
            try Task.checkCancellation()
            try await cleanup(device: device, paths: [remoteJar, remotePNG])
            try Self.removeReceipt(at: receiptURL)
            return png
        } catch {
            // A failed read must also remove partially pushed helper/output files.
            // Cleanup is awaited and targets only this request's random identity.
            do {
                try await cleanup(device: device, paths: [remoteJar, remotePNG])
                try Self.removeReceipt(at: receiptURL)
            }
            catch let cleanupError {
                throw BridgeError.message("Could not create Android app icon: \(error.localizedDescription). Temporary device files could not be removed: \(cleanupError.localizedDescription)")
            }
            throw error
        }
    }

    private static var defaultReceiptDirectory: URL {
        CompanionQAScope.current?.iconReceiptDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge/icon-receipts")
    }

    /// A startup recovery pass never deletes by prefix. Invalid receipts remain
    /// visible, live owners retain their request, and disconnected devices retry
    /// on a later pass. Limit each pass to 128 bounded receipts and 16 diagnostic messages.
    public static func recoverAbandonedRequests(toolchain: Toolchain = Toolchain(), receiptDirectoryURL: URL? = nil) async -> [String] {
        // Reserve one second for subprocess termination/reaping overhead.
        let deadline = ProcessInfo.processInfo.systemUptime + 14
        let directory = receiptDirectoryURL ?? defaultReceiptDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent } }
        catch { return ["Could not read Android icon recovery receipts: \(error.localizedDescription)"] }
        var messages: [String] = []
        func report(_ message: String) {
            if messages.count < 15 { messages.append(message) }
            else if messages.count == 15 { messages.append("Additional Android icon recovery diagnostics omitted; remaining receipts are preserved.") }
        }
        let cursorURL = directory.appendingPathComponent(".recovery-cursor")
        var cursor: String?
        let cursorData: Data? = {
            guard let reader = try? FileHandle(forReadingFrom: cursorURL) else { return nil }
            defer { try? reader.close() }
            return try? reader.read(upToCount: 129)
        }()
        if let data = cursorData, data.count <= 128,
           let value = String(data: data, encoding: .utf8), value.hasSuffix(".json"),
           let uuid = UUID(uuidString: String(value.dropLast(5))), value == uuid.uuidString.lowercased() + ".json" { cursor = value }
        let ordered = cursor.map { boundary in urls.filter { $0.lastPathComponent > boundary } + urls.filter { $0.lastPathComponent <= boundary } } ?? urls
        var lastConsidered: String?
        defer {
            // Rotating the bounded pass prevents offline/invalid receipts at the
            // start of lexical order from starving later recoverable requests.
            if let lastConsidered { try? Data(lastConsidered.utf8).write(to: cursorURL, options: .atomic) }
        }
        if urls.count > 128 { report("Additional Android icon receipts will be considered on the next recovery pass.") }
        var connectedSerials: Set<String>?
        var producerSnapshot: [String]?
        var snapshotAttempted = false
        func remainingTimeout() throws -> TimeInterval {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining >= 0.2 else { throw BridgeError.message("Android icon recovery reached its aggregate time budget; remaining requests are retained.") }
            return min(5, remaining)
        }
        for url in ordered.prefix(128) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                report("Android icon recovery reached its aggregate time budget; remaining requests are retained.")
                break
            }
            lastConsidered = url.lastPathComponent
            var cleaningSerial: String?
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 4097) <= 4096 else { throw BridgeError.message("Invalid receipt file") }
                let receipt = try JSONDecoder().decode(IconRequestReceipt.self, from: Data(contentsOf: url))
                try AndroidDiscovery.validateSerial(receipt.serial)
                guard receipt.ownerPID > 0, url.deletingPathExtension().lastPathComponent == receipt.identity.uuidString.lowercased() else { throw BridgeError.message("Invalid receipt identity") }
                if kill(receipt.ownerPID, 0) == 0 || errno == EPERM { continue }
                if !snapshotAttempted {
                    snapshotAttempted = true
                    let inventory = try await ProcessRunner.run("/bin/ps", arguments: ["-ww", "-axo", "pid=,command="], timeout: try remainingTimeout())
                    producerSnapshot = inventory.output.components(separatedBy: .newlines)
                }
                guard let producerSnapshot else { throw BridgeError.message("Cannot inspect outstanding icon producers; request is retained.") }
                if producerSnapshot.contains(where: { producerMatches($0, receipt: receipt) }) {
                    report("Android icon recovery retained \(url.lastPathComponent): its exact producer is still running.")
                    continue
                }
                if connectedSerials == nil {
                    connectedSerials = [] // A discovery failure must not repeat a slow probe for each receipt.
                    let devices = try await ProcessRunner.run(toolchain.adb, arguments: ["devices", "-l"], timeout: try remainingTimeout())
                    connectedSerials = Set(AndroidDiscovery.parseDevices(devices.output).filter { $0.state == "device" }.map(\.serial))
                }
                guard connectedSerials?.contains(receipt.serial) == true else {
                    report("Android icon recovery retained \(url.lastPathComponent): device is unavailable.")
                    continue
                }
                cleaningSerial = receipt.serial
                _ = try await ProcessRunner.run(toolchain.adb, arguments: ["-s", receipt.serial, "shell", "rm", "-f", receipt.remoteJar, receipt.remotePNG], timeout: try remainingTimeout())
                try removeReceipt(at: url)
                report("Recovered abandoned Android icon request \(receipt.identity.uuidString.lowercased()).")
            } catch {
                // One failed cleanup must not restage every receipt on an ADB
                // connection that disappeared after the initial discovery.
                if let cleaningSerial { connectedSerials?.remove(cleaningSerial) }
                report("Android icon recovery retained \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return messages
    }

    private static func producerMatches(_ command: String, receipt: IconRequestReceipt) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let pid = words.first.flatMap(Int32.init), pid > 0,
              words.contains("push") || words.contains("app_process"),
              words.contains(receipt.remoteJar) || words.contains("CLASSPATH=" + receipt.remoteJar) || words.contains(receipt.remotePNG) else { return false }
        // Both exact identity and serial must match; do not confuse another
        // device/request or a recovery `rm` with the outstanding producer.
        return words.indices.dropLast().contains { words[$0] == "-s" && words[$0 + 1] == receipt.serial }
    }

    private static func removeReceipt(at url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch {
            let failure = error as NSError
            // Concurrent hosts can both complete the same idempotent rm -f.
            // An already-removed local receipt is the canonical completed result.
            guard failure.domain == NSCocoaErrorDomain, failure.code == NSFileNoSuchFileError else { throw error }
        }
    }

    private func resolveHelper() throws -> String {
        let candidates = [helperPath, ProcessInfo.processInfo.environment["DROIDBRIDGE_ICON_HELPER"],
                          Bundle.main.resourceURL?.appendingPathComponent("Runtime/share/droidbridge/icon-helper.jar").path,
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/icon-helper/icon-helper.jar").path].compactMap { $0 }
        guard let found = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) }) else {
            throw BridgeError.message("Android icon helper is missing. Reinstall DroidBridge or run scripts/build-icon-helper.sh in a source checkout.")
        }
        return found
    }

    private func cleanup(device: AndroidDevice, paths: [String]) async throws {
        _ = try await ProcessRunner.run(toolchain.adb, arguments: ["-s", device.serial, "shell", "rm", "-f"] + paths, timeout: 5)
    }

    static func validatePNG(_ data: Data) throws {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count <= 2 * 1024 * 1024, data.count >= 24,
              Array(data.prefix(8)) == signature,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 512,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 512,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 512, image.height == 512 else {
            throw BridgeError.message("Android returned an invalid launcher icon (expected a 512 × 512 PNG).")
        }
    }
}

/// Paths are always derived from the UUID; a stored receipt cannot supply a
/// command or remote filename. Internal visibility supports isolated regressions.
struct IconRequestReceipt: Codable {
    let ownerPID: Int32
    let serial: String
    let identity: UUID
    var remoteJar: String { "/data/local/tmp/droidbridge-icon-\(identity.uuidString.lowercased()).jar" }
    var remotePNG: String { "/data/local/tmp/droidbridge-icon-\(identity.uuidString.lowercased()).png" }
    func save(directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(identity.uuidString.lowercased() + ".json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        return url
    }
}
