import Foundation
import Darwin
import CryptoKit

/// Android's Wireless debugging QR invitation. A new one is required for every
/// attempt, and the secret stays in memory and goes to ADB through stdin only.
public final class CompanionWirelessQRInvitation: @unchecked Sendable {
    let serviceInstance: String
    private let secret: String
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var used = false

    public init() {
        serviceInstance = "studio-" + Self.randomHex(bytes: 12)
        secret = Self.randomHex(bytes: 16)
    }
    public var payload: String { "WIFI:T:ADB;S:\(serviceInstance);P:\(secret);;" }

    fileprivate func claim() throws -> (secret: String, timeRemaining: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let remaining = 120 - (ProcessInfo.processInfo.systemUptime - createdAt)
        guard !used, remaining > 0 else { throw BridgeError.message("Show a new QR code to start another pairing attempt.") }
        used = true
        return (secret, remaining)
    }

    private static func randomHex(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}

public struct CompanionWirelessPairing: Sendable {
    /// GUID returned by Android's authenticated ADB pairing exchange, not an
    /// identity inferred from a Bonjour name, Wi-Fi address, or device label.
    public let serviceInstance: String
    public let message: String
    fileprivate let pairingHost: String
    fileprivate let connectBefore: TimeInterval
}

public struct CompanionWirelessConnection: Equatable, Sendable {
    public let serial: String
    public let message: String
    /// Domain-separated digest of a device-local continuity signal. This is
    /// not a peer certificate and cannot authenticate an adversarial LAN.
    public let fingerprint: String
}

/// Bounded, cancellation-aware Android Wireless debugging. Bonjour locates a
/// peer; ADB performs pairing and authorization. A connection GUID check is
/// continuity information, not a substitute for companion TLS authentication.
public enum CompanionWirelessADB {
    public static func pair(adb: String, endpoint: CompanionWirelessEndpoint, code: String, timeout: TimeInterval = 25) async throws -> String {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw BridgeError.message("Enter the current six-digit wireless debugging pairing code.") }
        let result = try await run(adb: adb, arguments: ["pair", endpoint.argument], input: code + "\n", secret: code, timeout: timeout)
        return String(result.prefix(1000))
    }
    /// A manual pairing receipt can still spare the user from typing the
    /// second address when the network permits connection discovery.
    public static func pairForDiscovery(adb: String, endpoint: CompanionWirelessEndpoint, code: String) async throws -> CompanionWirelessPairing? {
        let output = try await pair(adb: adb, endpoint: endpoint, code: code)
        guard let instance = try? pairedInstance(output: output, endpoint: endpoint) else { return nil }
        return CompanionWirelessPairing(serviceInstance: instance, message: "Android paired with this Mac.", pairingHost: endpoint.host,
                                        connectBefore: ProcessInfo.processInfo.systemUptime + 30)
    }
    public static func connect(adb: String, endpoint: CompanionWirelessEndpoint, timeout: TimeInterval = 25) async throws -> String {
        let result = try await run(adb: adb, arguments: ["connect", endpoint.argument], input: nil, secret: nil, timeout: timeout)
        return String(result.prefix(1000))
    }

    public static func validateServiceInstance(_ instance: String) throws {
        guard (5...63).contains(instance.utf8.count), instance.hasPrefix("adb-"),
              instance.dropFirst(4).utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw BridgeError.message("Android did not provide a valid wireless debugging identity.")
        }
    }

    public static func pair(adb: String, invitation: CompanionWirelessQRInvitation, discoveryTimeout: TimeInterval = 90) async throws -> CompanionWirelessPairing {
        try Task.checkCancellation()
        let credential = try invitation.claim()
        let started = ProcessInfo.processInfo.systemUptime
        let address = try await CompanionWirelessBonjour.resolve(instance: invitation.serviceInstance, kind: .pairing, timeout: min(discoveryTimeout, credential.timeRemaining))
        let remaining = credential.timeRemaining - (ProcessInfo.processInfo.systemUptime - started)
        guard remaining > 0 else { throw BridgeError.message("This QR code expired. Show a new one and try again.") }
        let endpoint = try address.endpoint
        let output = try await run(adb: adb, arguments: ["pair", endpoint.argument], input: credential.secret + "\n", secret: credential.secret, timeout: min(25, remaining))
        let instance = try pairedInstance(output: output, endpoint: endpoint)
        return CompanionWirelessPairing(serviceInstance: instance, message: "Android paired with this Mac.", pairingHost: address.host,
                                        connectBefore: ProcessInfo.processInfo.systemUptime + 30)
    }

    static func pairedInstance(output: String, endpoint: CompanionWirelessEndpoint) throws -> String {
        let prefix = "Successfully paired to \(endpoint.argument) [guid="
        let candidates = output.components(separatedBy: .newlines).compactMap { line -> String? in
            let response = line.hasPrefix("Enter pairing code: ") ? String(line.dropFirst("Enter pairing code: ".count)) : line
            guard response.hasPrefix(prefix), response.hasSuffix("]") else { return nil }
            return String(response.dropFirst(prefix.count).dropLast())
        }
        guard candidates.count == 1, let instance = candidates.first else { throw BridgeError.message("ADB did not confirm pairing. Keep Wireless debugging open and try a new QR code.") }
        try validateServiceInstance(instance)
        return instance
    }

    public static func connectPaired(adb: String, pairing: CompanionWirelessPairing, discoveryTimeout: TimeInterval = 12) async throws -> CompanionWirelessConnection {
        let remaining = pairing.connectBefore - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw BridgeError.message("Show a new QR code to finish connecting to this phone.") }
        return try await connectPaired(adb: adb, serviceInstance: pairing.serviceInstance, expectedHost: pairing.pairingHost,
                                       expectedFingerprint: nil, discoveryTimeout: min(discoveryTimeout, remaining))
    }

    public static func connectPaired(adb: String, serviceInstance: String, fingerprint: String, discoveryTimeout: TimeInterval = 12) async throws -> CompanionWirelessConnection {
        try validateFingerprint(fingerprint)
        let discovered = try await CompanionWirelessBonjour.resolveSavedConnection(instance: serviceInstance, timeout: discoveryTimeout)
        return try await connectSavedCandidates(adb: adb, serviceInstance: serviceInstance, fingerprint: fingerprint, candidates: discovered.map { try $0.endpoint })
    }

    static func connectSavedCandidates(adb: String, serviceInstance: String, fingerprint: String, candidates: [CompanionWirelessEndpoint]) async throws -> CompanionWirelessConnection {
        try validateServiceInstance(serviceInstance)
        try validateFingerprint(fingerprint)
        var attempted = Set<String>()
        var lastError: Error?
        for endpoint in candidates where attempted.insert(endpoint.argument).inserted {
            guard attempted.count <= CompanionWirelessBonjour.maximumSavedCandidates else { break }
            try Task.checkCancellation()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            do {
                return try await connectPaired(adb: adb, endpoint: endpoint, serviceInstance: serviceInstance,
                                               expectedFingerprint: fingerprint, deadline: deadline)
            } catch is CancellationError {
                throw CancellationError()
            } catch { lastError = error }
        }
        throw lastError ?? BridgeError.message("Couldn’t find an available Wi-Fi address for the saved phone.")
    }

    private static func connectPaired(adb: String, serviceInstance: String, expectedHost: String?, expectedFingerprint: String?, discoveryTimeout: TimeInterval) async throws -> CompanionWirelessConnection {
        try validateServiceInstance(serviceInstance)
        let address = try await CompanionWirelessBonjour.resolve(instance: serviceInstance, kind: .connection, timeout: discoveryTimeout, expectedHost: expectedHost)
        return try await connectPaired(adb: adb, endpoint: address.endpoint, serviceInstance: serviceInstance, expectedFingerprint: expectedFingerprint)
    }

    static func connectPaired(adb: String, endpoint: CompanionWirelessEndpoint, serviceInstance: String, expectedFingerprint: String?, deadline: TimeInterval? = nil) async throws -> CompanionWirelessConnection {
        try validateServiceInstance(serviceInstance)
        if let expectedFingerprint { try validateFingerprint(expectedFingerprint) }
        let serial = endpoint.argument
        let output = try await connect(adb: adb, endpoint: endpoint, timeout: stepTimeout(deadline == nil ? 12 : 3, before: deadline))
        let lines = output.components(separatedBy: .newlines)
        let opened = lines.contains("connected to \(serial)")
        let reused = lines.contains("already connected to \(serial)")
        guard opened != reused else {
            throw BridgeError.message("ADB did not confirm a connection to the selected Wi-Fi address.")
        }
        // A connect reply alone is not an authenticated, available transport.
        // Check exactly one ready entry and bind the read-only probe to its ID.
        guard let transport = try await readyTransport(adb: adb, serial: serial, timeout: stepTimeout(deadline == nil ? 3 : 1, before: deadline)) else {
            throw BridgeError.message("ADB hasn’t made the Wi-Fi connection available. Keep Wireless debugging on and try again.")
        }
        let identity = try? await verifiedFingerprint(adb: adb, transport: transport, serviceInstance: serviceInstance, deadline: deadline)
        try Task.checkCancellation()
        guard let identity, expectedFingerprint == nil || identity == expectedFingerprint else {
            // Only unwind a newly opened exact transport if it is still the
            // same one we probed. Preserve pre-existing/shared transports.
            // Allow short cleanup even if the verification budget just expired.
            if opened, (try? await readyTransport(adb: adb, serial: serial, timeout: deadline == nil ? 3 : 1)) == transport {
                _ = try? await run(adb: adb, arguments: ["disconnect", serial], input: nil, secret: nil, timeout: deadline == nil ? 2 : 1)
            }
            throw BridgeError.message("The Wi-Fi connection did not identify itself as this paired phone. Check Wireless debugging, then retry.")
        }
        try Task.checkCancellation()
        return CompanionWirelessConnection(serial: serial, message: "Connected to Android over Wi-Fi.", fingerprint: identity)
    }

    public static func verifyConnected(adb: String, serial: String, serviceInstance: String, fingerprint: String) async throws -> Bool {
        try validateServiceInstance(serviceInstance)
        try validateFingerprint(fingerprint)
        try AndroidDiscovery.validateSerial(serial)
        guard let transport = try await readyTransport(adb: adb, serial: serial) else { return false }
        return try await verifiedFingerprint(adb: adb, transport: transport, serviceInstance: serviceInstance) == fingerprint
    }

    private static func stepTimeout(_ limit: TimeInterval, before deadline: TimeInterval?) throws -> TimeInterval {
        guard let deadline else { return limit }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining >= 0.1 else { throw BridgeError.message("The Wi-Fi address did not respond in time.") }
        return min(limit, remaining)
    }

    private static func readyTransport(adb: String, serial: String, timeout: TimeInterval = 3) async throws -> UInt64? {
        let listing = try await run(adb: adb, arguments: ["devices", "-l"], input: nil, secret: nil, timeout: timeout)
        return readyTransportID(listing, serial: serial)
    }

    static func readyTransportID(_ listing: String, serial: String) -> UInt64? {
        let records = listing.components(separatedBy: .newlines).map { $0.split(whereSeparator: \.isWhitespace) }.filter { $0.first.map(String.init) == serial }
        guard records.count == 1, let record = records.first, record.count >= 3, record[1] == "device" else { return nil }
        let ids = record.dropFirst(2).filter { $0.hasPrefix("transport_id:") }
        guard ids.count == 1, let id = ids.first, let transportID = UInt64(id.dropFirst("transport_id:".count)), transportID > 0 else { return nil }
        return transportID
    }

    private static func verifiedFingerprint(adb: String, transport: UInt64, serviceInstance: String, deadline: TimeInterval? = nil) async throws -> String? {
        // Some stock Android builds restrict this property's SELinux context.
        // A readable mismatch still rules out the peer; blank is not evidence.
        let guid = try? await run(adb: adb, arguments: ["-t", String(transport), "shell", "getprop", "persist.adb.wifi.guid"], input: nil, secret: nil,
                                  timeout: stepTimeout(deadline == nil ? 3 : 0.75, before: deadline))
        try Task.checkCancellation()
        if let guid, !guid.isEmpty, guid != serviceInstance { return nil }
        return try await deviceFingerprint(adb: adb, transportID: transport, timeout: stepTimeout(deadline == nil ? 3 : 1.5, before: deadline))
    }

    public static func deviceFingerprint(adb: String, transportID: UInt64) async throws -> String {
        try await deviceFingerprint(adb: adb, transportID: transportID, timeout: 3)
    }

    private static func deviceFingerprint(adb: String, transportID: UInt64, timeout: TimeInterval) async throws -> String {
        guard transportID > 0 else { throw BridgeError.message("No exact Android transport is available to verify.") }
        let identifier = try await run(adb: adb, arguments: ["-t", String(transportID), "shell", "settings", "--user", "0", "get", "secure", "android_id"], input: nil, secret: nil, timeout: timeout)
        return try fingerprint(androidID: identifier)
    }

    static func fingerprint(androidID: String) throws -> String {
        let normalized = androidID.lowercased()
        // AOSP stores this UInt64 in hex without requiring leading zeroes.
        guard (1...16).contains(normalized.utf8.count), normalized.utf8.contains(where: { $0 != 48 }), isHex(normalized) else {
            throw BridgeError.message("Android did not provide a readable identity for this Wi-Fi connection.")
        }
        let padded = String(repeating: "0", count: 16 - normalized.utf8.count) + normalized
        let digest = SHA256.hash(data: Data("DroidBridge wireless continuity v1\u{0}\(padded)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func validateFingerprint(_ fingerprint: String) throws {
        guard fingerprint.utf8.count == 64, isHex(fingerprint) else { throw BridgeError.message("The saved Wi-Fi identity is invalid. Pair the phone again.") }
    }

    private static func isHex(_ value: String) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private final class Owner: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var status: Int32?
        func launch(_ child: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try child.run(); process = child
        }
        func cancel() {
            lock.lock(); cancelled = true
            let child = process; lock.unlock()
            if let child, child.isRunning { child.terminate() }
        }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        var exitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return status }
        func terminated(_ status: Int32) {
            lock.lock(); defer { lock.unlock() }; self.status = status
        }
    }

    private static func run(adb: String, arguments: [String], input: String?, secret: String?, timeout: TimeInterval) async throws -> String {
        let owner = Owner()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                let capture = Pipe(), pipe = Pipe()
                let reader = capture.fileHandleForReading
                let writer = pipe.fileHandleForWriting
                defer { try? reader.close(); try? writer.close() }
                guard fcntl(reader.fileDescriptor, F_SETFL, O_NONBLOCK) != -1,
                      fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw BridgeError.message("Unable to prepare wireless debugging.") }
                let child = Process(); child.executableURL = URL(fileURLWithPath: adb); child.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["ADB_MDNS"] = "0"
                environment.removeValue(forKey: "ADB_TRACE")
                child.environment = environment
                child.standardOutput = capture; child.standardError = capture; child.standardInput = pipe
                child.terminationHandler = { [weak owner] child in owner?.terminated(child.terminationStatus) }
                try owner.launch(child)
                try? capture.fileHandleForWriting.close()
                if let input { try? writer.write(contentsOf: Data(input.utf8)) }
                try? writer.close()
                let deadline = ProcessInfo.processInfo.systemUptime + min(30, max(0.1, timeout.isFinite ? timeout : 8))
                var captured = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                var exceeded = false
                var status: Int32?
                while true {
                    let count = Darwin.read(reader.fileDescriptor, &buffer, buffer.count)
                    if count > 0 { captured.append(contentsOf: buffer.prefix(count)) }
                    if owner.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline || captured.count > 64 * 1024 {
                        exceeded = true
                        if child.isRunning {
                            child.terminate()
                            let grace = ProcessInfo.processInfo.systemUptime + 0.5
                            while child.isRunning && ProcessInfo.processInfo.systemUptime < grace { try? await Task.sleep(nanoseconds: 20_000_000) }
                            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                        }
                        break
                    }
                    if count <= 0 {
                        if let exit = owner.exitStatus { status = exit; break }
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
                if owner.isCancelled { throw CancellationError() }
                guard !exceeded else { throw BridgeError.message("Wireless debugging timed out. Keep Wireless debugging open on Android and try again.") }
                var output = String(decoding: captured, as: UTF8.self)
                if let secret { output = output.replacingOccurrences(of: secret, with: "[redacted]") }
                guard status == 0, !output.lowercased().contains("failed"), !output.lowercased().contains("cannot connect") else { throw BridgeError.message("Wireless debugging failed. Check Wireless debugging on Android and try again.") }
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
        }, onCancel: { owner.cancel() })
    }
}
