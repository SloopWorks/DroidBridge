import Darwin
import Foundation

/// A phone explicitly enrolled for Wi-Fi debugging by this Mac. The instance
/// is learned from the authenticated pairing exchange (or the selected USB
/// transport), never from an unsolicited Bonjour advertisement.
public struct CompanionWirelessProfile: Identifiable, Equatable, Sendable {
    public var id: String { serviceInstance }
    public let serviceInstance: String
    public let label: String
    /// An observation for display and reconnect scheduling, not a dial target.
    public let lastVerifiedSerial: String?
}

/// Owns only reconnect discovery and the local enrollment records. It does not
/// retain ADB passwords, manage ADB's key store, or grant companion authority.
public actor CompanionWirelessReconnect {
    public static let shared = CompanionWirelessReconnect()
    public static var defaultURL: URL {
        let root = CompanionQAScope.current?.root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DroidBridge", isDirectory: true)
        return root.appendingPathComponent("WirelessADB.noindex", isDirectory: true).appendingPathComponent("profiles.json")
    }

    private let store: WirelessProfileStore
    private let now: @Sendable () -> TimeInterval
    private let verify: @Sendable (String, String, String, String) async throws -> Bool
    private let connect: @Sendable (String, String, String) async throws -> CompanionWirelessConnection
    private let model: @Sendable (String, String) async -> String?
    private var active: (id: UUID, serviceInstance: String, task: Task<Outcome, Error>)?
    private var attempts: [String: Schedule] = [:]

    private struct Schedule {
        var failures: Int
        var next: TimeInterval
    }

    private enum Outcome {
        case stillOnline
        case connected(CompanionWirelessConnection, model: String?)
    }

    public init(storageURL: URL = defaultURL) {
        self.init(storageURL: storageURL, now: { ProcessInfo.processInfo.systemUptime }, verify: { adb, serial, instance, fingerprint in
            try await CompanionWirelessADB.verifyConnected(adb: adb, serial: serial, serviceInstance: instance, fingerprint: fingerprint)
        }, connect: { adb, instance, fingerprint in
            try await CompanionWirelessADB.connectPaired(adb: adb, serviceInstance: instance, fingerprint: fingerprint)
        }, model: { adb, serial in
            guard let devices = try? await ProcessRunner.run(adb, arguments: ["devices", "-l"], timeout: 2) else { return nil }
            return AndroidDiscovery.parseDevices(devices.output).first { $0.serial == serial && $0.state == "device" }?.model
        })
    }

    init(storageURL: URL, now: @escaping @Sendable () -> TimeInterval,
         verify: @escaping @Sendable (String, String, String, String) async throws -> Bool,
         connect: @escaping @Sendable (String, String, String) async throws -> CompanionWirelessConnection,
         model: @escaping @Sendable (String, String) async -> String?) {
        store = WirelessProfileStore(url: storageURL)
        self.now = now; self.verify = verify; self.connect = connect; self.model = model
    }

    /// Only verified connection results from a QR or authorized USB setup may
    /// enroll a phone. The address is never used for a new connection attempt.
    public func remember(serviceInstance: String, label: String? = nil, connection: CompanionWirelessConnection) throws {
        try CompanionWirelessADB.validateServiceInstance(serviceInstance)
        try CompanionWirelessADB.validateFingerprint(connection.fingerprint)
        _ = try CompanionWirelessEndpoint(connection.serial)
        try store.update { records in
            let activeCount = records.filter(\.enabled).count
            if let index = records.firstIndex(where: { $0.serviceInstance == serviceInstance }) {
                guard records[index].fingerprint == connection.fingerprint else {
                    throw BridgeError.message("The saved Wi-Fi debugging identity changed. Use USB to connect this phone.")
                }
                if !records[index].enabled {
                    guard activeCount < WirelessProfileStore.maximumActive else { throw Self.activeLimit() }
                    records[index].enabled = true
                    records[index].generation = UUID()
                }
                try records[index].observe(serial: connection.serial)
                if let label = Self.label(label) { records[index].label = label }
                return
            }
            guard activeCount < WirelessProfileStore.maximumActive else { throw Self.activeLimit() }
            guard records.count < WirelessProfileStore.maximumRecords else { throw WirelessProfileStore.historyLimit() }
            records.append(.init(generation: UUID(), serviceInstance: serviceInstance, fingerprint: connection.fingerprint,
                                 label: Self.label(label) ?? "Android phone", aliases: [connection.serial], enabled: true))
        }
        attempts.removeValue(forKey: serviceInstance)
    }

    public func profiles() throws -> [CompanionWirelessProfile] {
        try store.load().filter(\.enabled).map(\.profile).sorted {
            $0.label == $1.label ? $0.serviceInstance < $1.serviceInstance : $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    /// Stops future automatic reconnect. Historical aliases stay blocked so
    /// old wrappers cannot open a different device that takes over an address.
    /// Android's debugging trust is a separate setting.
    public func forget(serviceInstance: String) throws {
        try CompanionWirelessADB.validateServiceInstance(serviceInstance)
        try store.update { records in
            guard let index = records.firstIndex(where: { $0.serviceInstance == serviceInstance && $0.enabled }) else { return }
            if records[index].aliases.isEmpty { records.remove(at: index) }
            else {
                records[index].enabled = false
                records[index].generation = UUID()
                records[index].label = "Android phone"
            }
        }
        if active?.serviceInstance == serviceInstance { active?.task.cancel() }
        attempts.removeValue(forKey: serviceInstance)
    }

    /// For an explicitly initiated retry of a saved connection.
    public func connectNow(adb: String, serviceInstance: String) async throws -> CompanionWirelessConnection {
        guard let profile = try store.load().first(where: { $0.enabled && $0.serviceInstance == serviceInstance }) else {
            throw BridgeError.message("Pair this phone over Wi-Fi before connecting it.")
        }
        guard let result = try await perform(adb: adb, serviceInstance: serviceInstance, profile: profile, verifyFirst: nil) else {
            throw BridgeError.message("The phone is already connected over Wi-Fi.")
        }
        return result
    }

    /// Use the address bound to the pairing response for the first dial.
    /// No background reconnect is enrolled until the identity is observed.
    public func connectNow(adb: String, pairing: CompanionWirelessPairing, discoveryTimeout: TimeInterval = 12) async throws -> CompanionWirelessConnection {
        guard let result = try await perform(adb: adb, serviceInstance: pairing.serviceInstance, profile: nil, verifyFirst: nil, initialConnect: {
            try await CompanionWirelessADB.connectPaired(adb: adb, pairing: pairing, discoveryTimeout: discoveryTimeout)
        }) else { throw BridgeError.message("The phone's Wi-Fi debugging connection is unavailable.") }
        return result
    }

    /// Called only by the management app. At most one peer is considered per
    /// pass, with per-phone backoff. The last IP/port is never used for a new
    /// connection; it is checked only when already present in ADB's device list.
    public func reconnectIfDue(adb: String, devices: [AndroidDevice]) async -> CompanionWirelessConnection? {
        guard active == nil, !Task.isCancelled, let records = try? store.load().filter(\.enabled) else { return nil }
        let instant = now()
        let validIDs = Set(records.map(\.serviceInstance))
        attempts = attempts.filter { validIDs.contains($0.key) }
        guard let profile = records.filter({ (attempts[$0.serviceInstance]?.next ?? 0) <= instant }).min(by: {
            let lhs = attempts[$0.serviceInstance]?.next ?? 0, rhs = attempts[$1.serviceInstance]?.next ?? 0
            return lhs == rhs ? $0.serviceInstance < $1.serviceInstance : lhs < rhs
        }) else { return nil }
        let alias = profile.aliases.last.flatMap { serial in devices.contains { $0.serial == serial && $0.state == "device" } ? serial : nil }
        return try? await perform(adb: adb, serviceInstance: profile.serviceInstance, profile: profile, verifyFirst: alias)
    }

    /// Old numeric addresses can be reassigned. An automatic recovery or saved
    /// launch using a recorded alias must check the current transport before
    /// sending app commands. This prevents ordinary address reuse; stock ADB
    /// does not mutually authenticate device identity against a spoofed LAN.
    public func checkKnownSerial(adb: String, serial: String) async throws {
        guard (try? CompanionWirelessEndpoint(serial)) != nil else { return }
        let owners = try store.load().filter { $0.aliases.contains(serial) }
        guard !owners.isEmpty else { return }
        guard owners.count == 1, let owner = owners.first, owner.enabled,
              try await verify(adb, serial, owner.serviceInstance, owner.fingerprint),
              try store.load().filter({ $0.aliases.contains(serial) }).map(\.generation) == [owner.generation] else {
            throw BridgeError.message("This address no longer identifies the remembered Android phone. Reconnect it from Devices.")
        }
        try Task.checkCancellation()
    }

    /// An authorized cable binds one current Wi-Fi IPv4 address and device
    /// fingerprint before discovery. Android's user-controlled TLS service
    /// must already be enabled; this path never changes debugging settings.
    public static func connectUsingUSB(adb: String, serial: String) async throws -> (serviceInstance: String, connection: CompanionWirelessConnection) {
        try AndroidDiscovery.validateSerial(serial)
        let result = try await ProcessRunner.run(adb, arguments: ["devices", "-l"], timeout: 3)
        try Task.checkCancellation()
        guard let transport = usbTransportID(result.output, serial: serial) else {
            throw BridgeError.message("Select a USB-connected phone and approve Android's USB debugging prompt first.")
        }
        let args = ["-t", String(transport), "shell"]
        async let fingerprint = CompanionWirelessADB.deviceFingerprint(adb: adb, transportID: transport)
        async let addresses = ProcessRunner.run(adb, arguments: args + ["ip", "-o", "-4", "address", "show", "up", "scope", "global"], timeout: 3)
        let hints = try await (fingerprint, addresses)
        try Task.checkCancellation()
        guard let host = usbWiFiHost(addresses: hints.1.output) else {
            throw BridgeError.message("Connect the phone to Wi-Fi or pair it with the QR code.")
        }
        let service = try await CompanionWirelessBonjour.resolveConnection(host: host, timeout: 12)
        let connection = try await CompanionWirelessADB.connectPaired(adb: adb, endpoint: service.endpoint,
                                                                       serviceInstance: service.serviceInstance, expectedFingerprint: hints.0)
        return (service.serviceInstance, connection)
    }

    static func usbWiFiHost(addresses: String) -> String? {
        let candidates = Set(addresses.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, fields[2] == "inet", fields[1].hasPrefix("wlan"),
                  !fields[1].dropFirst(4).isEmpty,
                  fields[1].dropFirst(4).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            let parts = fields[3].split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let mask = UInt8(parts[1]), mask <= 32 else { return nil }
            let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
            guard octets.count == 4, octets[0] > 0, octets[0] < 224, octets[0] != 127,
                  !(octets[0] == 169 && octets[1] == 254),
                  (try? CompanionWirelessEndpoint("\(parts[0]):1")) != nil else { return nil }
            return String(parts[0])
        })
        return candidates.count == 1 ? candidates.first : nil
    }

    static func usbTransportID(_ output: String, serial: String) -> UInt64? {
        let rows = output.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
            .filter { $0.first.map(String.init) == serial }
        guard rows.count == 1, let fields = rows.first, fields.count >= 4, fields[1] == "device" else { return nil }
        let flags = fields.dropFirst(2), usb = flags.filter { $0.hasPrefix("usb:") && $0.count > 4 }
        let ids = flags.filter { $0.hasPrefix("transport_id:") }
        guard usb.count == 1, ids.count == 1, let text = ids.first?.dropFirst("transport_id:".count),
              text.allSatisfy({ $0.isASCII && $0.isNumber }), let id = UInt64(text), id > 0 else { return nil }
        return id
    }

    private func perform(adb: String, serviceInstance instance: String, profile: WirelessProfileStore.Record?, verifyFirst: String?,
                         initialConnect: (@Sendable () async throws -> CompanionWirelessConnection)? = nil) async throws -> CompanionWirelessConnection? {
        guard active == nil else { throw BridgeError.message("A Wi-Fi connection is already in progress. Try again shortly.") }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task<Outcome, Error> { [verify, connect, model] in
            if let verifyFirst, let profile, (try? await verify(adb, verifyFirst, instance, profile.fingerprint)) == true { return .stillOnline }
            try Task.checkCancellation()
            let connection: CompanionWirelessConnection
            if let initialConnect { connection = try await initialConnect() }
            else if let profile { connection = try await connect(adb, instance, profile.fingerprint) }
            else { throw CancellationError() }
            try Task.checkCancellation()
            try CompanionWirelessADB.validateFingerprint(connection.fingerprint)
            guard profile == nil || connection.fingerprint == profile?.fingerprint else {
                throw BridgeError.message("The Wi-Fi connection did not identify the saved Android phone.")
            }
            _ = try CompanionWirelessEndpoint(connection.serial)
            return .connected(connection, model: await model(adb, connection.serial))
        }
        active = (id, instance, task)
        defer { if active?.id == id { active = nil } }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard !task.isCancelled else { throw CancellationError() }
            if let profile, try !store.load().contains(where: { $0.enabled && $0.generation == profile.generation }) { throw CancellationError() }
            switch result {
            case .stillOnline:
                attempts[instance] = Schedule(failures: 0, next: now() + 15)
                return nil
            case .connected(let connection, let model):
                if let profile {
                    try store.update { records in
                        guard let index = records.firstIndex(where: { $0.enabled && $0.generation == profile.generation }) else { throw CancellationError() }
                        try records[index].observe(serial: connection.serial)
                        if let label = Self.label(model), label != connection.serial { records[index].label = label }
                    }
                } else {
                    try remember(serviceInstance: instance, label: model == connection.serial ? nil : model, connection: connection)
                }
                attempts[instance] = Schedule(failures: 0, next: now() + 8)
                return connection
            }
        } catch {
            if profile != nil, !(error is CancellationError), !Task.isCancelled, !task.isCancelled {
                let failures = min(6, (attempts[instance]?.failures ?? 0) + 1)
                attempts[instance] = Schedule(failures: failures, next: now() + min(120, Double(4 << (failures - 1))))
            }
            throw error
        }
    }

    private static func label(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.prefix(640).filter { !CharacterSet.controlCharacters.contains($0) }.prefix(160)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return clean
    }

    private static func activeLimit() -> BridgeError {
        .message("Stop reconnecting a saved phone before adding another Wi-Fi debugging connection.")
    }
}

private struct WirelessProfileStore {
    static let maximumActive = 16
    static let maximumRecords = 64
    static let maximumAliases = 256
    private static let byteLimit = 1_048_576
    let url: URL

    struct Record: Codable, Equatable {
        var generation: UUID
        let serviceInstance: String
        let fingerprint: String
        var label: String
        var aliases: [String]
        var enabled: Bool
        var profile: CompanionWirelessProfile { .init(serviceInstance: serviceInstance, label: label, lastVerifiedSerial: aliases.last) }
        mutating func observe(serial: String) throws {
            aliases.removeAll { $0 == serial }
            guard aliases.count < WirelessProfileStore.maximumAliases else { throw WirelessProfileStore.historyLimit() }
            aliases.append(serial)
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let records: [Record]
    }

    func load() throws -> [Record] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return [] }
        guard fd >= 0 else { throw Self.invalid() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try Self.validateFile(fd)
        let data = try handle.read(upToCount: Self.byteLimit + 1) ?? Data()
        guard data.count <= Self.byteLimit else { throw Self.invalid() }
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        guard decoded.version == 1 else { throw Self.invalid() }
        try Self.validate(decoded.records)
        return decoded.records
    }

    func update(_ change: (inout [Record]) throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Self.invalid() }
        let lock = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Self.invalid() }
        defer { close(lock) }
        try Self.validateFile(lock)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
                  errno == EWOULDBLOCK || errno == EINTR else { throw BridgeError.message("Saved Wi-Fi debugging connections are busy. Try again.") }
            usleep(1_000)
        }
        var records = try load()
        let previous = records
        try change(&records)
        guard records != previous else { return }
        try Task.checkCancellation()
        try Self.validate(records)
        let bytes = try JSONEncoder().encode(Envelope(version: 1, records: records))
        guard bytes.count <= Self.byteLimit else { throw Self.invalid() }
        let temporary = directory.appendingPathComponent(".wireless-\(UUID().uuidString)")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.invalid() }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw Self.invalid() }
    }

    private static func validateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw invalid() }
    }

    private static func validate(_ records: [Record]) throws {
        guard records.count <= maximumRecords, records.filter(\.enabled).count <= maximumActive,
              Set(records.map(\.generation)).count == records.count,
              Set(records.map(\.serviceInstance)).count == records.count else { throw invalid() }
        for record in records {
            try CompanionWirelessADB.validateServiceInstance(record.serviceInstance)
            try CompanionWirelessADB.validateFingerprint(record.fingerprint)
            guard !record.label.isEmpty, record.label.utf8.count <= 640,
                  !record.label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  record.aliases.count <= maximumAliases,
                  Set(record.aliases).count == record.aliases.count else { throw invalid() }
            for alias in record.aliases { _ = try CompanionWirelessEndpoint(alias) }
        }
    }

    private static func invalid() -> BridgeError { .message("Saved Wi-Fi debugging connections could not be read safely.") }
    static func historyLimit() -> BridgeError { .message("Wi-Fi debugging address history reached its safety limit. Use USB or contact support.") }
}
