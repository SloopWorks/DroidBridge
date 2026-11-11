import Darwin
import dnssd
import Foundation

/// A short, targeted browse on the Mac. It does not enable mDNS in ADB's shared
/// server, retain advertisements after the operation, or connect to peers.
enum CompanionWirelessBonjour {
    enum Kind: String { case pairing = "_adb-tls-pairing._tcp", connection = "_adb-tls-connect._tcp" }

    struct Address: Hashable, Sendable {
        let host: String
        let port: UInt16
        let isIPv4: Bool

        var endpoint: CompanionWirelessEndpoint {
            get throws { try CompanionWirelessEndpoint(isIPv4 ? "\(host):\(port)" : "[\(host)]:\(port)") }
        }
    }

    static func resolve(instance: String, kind: Kind, timeout: TimeInterval, expectedHost: String? = nil) async throws -> Address {
        let targets = try await resolveTargets(instance: instance, kind: kind, timeout: timeout, expectedHost: expectedHost)
        guard let target = targets.first else { throw discoveryUnavailable }
        return target.address
    }

    /// A saved phone may publish old and new listener ports at the same time.
    /// These are only dial candidates; the caller checks the saved fingerprint.
    static func resolveSavedConnection(instance: String, timeout: TimeInterval) async throws -> [Address] {
        try CompanionWirelessADB.validateServiceInstance(instance)
        return try await resolveTargets(instance: instance, kind: .connection, timeout: timeout, expectedHost: nil, saved: true).map(\.address)
    }

    /// The authorized USB phone supplies this exact WLAN address. The caller
    /// separately verifies that the wireless transport matches its USB digest.
    static func resolveConnection(host: String, timeout: TimeInterval) async throws -> (serviceInstance: String, endpoint: CompanionWirelessEndpoint) {
        var ipv4 = in_addr()
        guard inet_pton(AF_INET, host, &ipv4) == 1 else { throw BridgeError.message("Android did not report one valid Wi-Fi address over USB.") }
        let targets = try await resolveTargets(instance: nil, kind: .connection, timeout: timeout, expectedHost: host)
        guard let target = targets.first else { throw discoveryUnavailable }
        return (target.instance, try target.address.endpoint)
    }

    private struct Target: Hashable, Sendable {
        let instance: String
        let address: Address
    }

    private static func resolveTargets(instance: String?, kind: Kind, timeout: TimeInterval, expectedHost: String?, saved: Bool = false) async throws -> [Target] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try lookup(instance: instance, kind: kind, timeout: timeout, expectedHost: expectedHost, saved: saved) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private struct Service: Hashable {
        let index: UInt32
        let instance: String
        let type: String
        let domain: String
    }

    private final class BrowseState {
        let instance: String?
        let kind: Kind
        var services = Set<Service>()
        var lastChange: TimeInterval = 0
        var error: DNSServiceErrorType = 0
        init(instance: String?, kind: Kind) { self.instance = instance; self.kind = kind }
    }

    private final class ServiceState {
        var target: String?
        var port: UInt16 = 0
        var error: DNSServiceErrorType = 0
    }

    private final class AddressState {
        let port: UInt16
        var addresses = Set<Address>()
        var lastChange: TimeInterval = 0
        var error: DNSServiceErrorType = 0
        init(port: UInt16) { self.port = port }
    }

    static func matches(_ advertised: String, instance: String, kind: Kind) -> Bool {
        if advertised == instance { return true }
        return kind == .connection && registrationNumber(advertised, instance: instance) != nil
    }

    private static func registrationNumber(_ advertised: String, instance: String) -> Int? {
        if advertised == instance { return 0 }
        // DNS-SD can add a bounded numeric suffix when an older advertisement
        // has not disappeared yet. A prefix match alone would accept other phones.
        guard advertised.hasPrefix(instance + " ("), advertised.hasSuffix(")") else { return nil }
        let index = advertised.dropFirst(instance.count + 2).dropLast()
        guard (1...3).contains(index.count), index.allSatisfy({ $0.isASCII && $0.isNumber }), index.first != "0" else { return nil }
        return Int(index)
    }

    static let maximumSavedCandidates = 3

    static func orderedSavedCandidates(_ addresses: [Address: Int]) -> [Address] {
        Array(addresses.keys.sorted { a, b in
            // A conflicting numeric registration is usually the replacement.
            // Among equivalent registrations prefer IPv4, then a stable order.
            let lhs = addresses[a] ?? 0, rhs = addresses[b] ?? 0
            if lhs != rhs { return lhs > rhs }
            if a.isIPv4 != b.isIPv4 { return a.isIPv4 }
            if a.host != b.host { return a.host < b.host }
            return a.port < b.port
        }.prefix(maximumSavedCandidates))
    }

    private static func lookup(instance: String?, kind: Kind, timeout: TimeInterval, expectedHost: String?, saved: Bool) throws -> [Target] {
        let deadline = ProcessInfo.processInfo.systemUptime + min(120, max(0.1, timeout.isFinite ? timeout : 12))
        let state = BrowseState(instance: instance, kind: kind)
        var browse: DNSServiceRef?
        let result = DNSServiceBrowse(&browse, 0, 0, kind.rawValue, "local.", { _, flags, index, error, name, type, domain, context in
            guard let context else { return }
            let state = Unmanaged<BrowseState>.fromOpaque(context).takeUnretainedValue()
            guard error == 0 else { state.error = error; return }
            guard let name, let type, let domain else { return }
            let service = Service(index: index, instance: String(cString: name), type: String(cString: type), domain: String(cString: domain))
            guard service.domain.lowercased() == "local.",
                  service.type.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == state.kind.rawValue else { return }
            if let instance = state.instance {
                guard CompanionWirelessBonjour.matches(service.instance, instance: instance, kind: state.kind) else { return }
            } else {
                guard (try? CompanionWirelessADB.validateServiceInstance(service.instance)) != nil else { return }
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
                if state.services.insert(service).inserted { state.lastChange = ProcessInfo.processInfo.systemUptime }
            } else if state.services.remove(service) != nil { state.lastChange = ProcessInfo.processInfo.systemUptime }
        }, Unmanaged.passUnretained(state).toOpaque())
        try check(result)
        guard let browse else { throw discoveryUnavailable }
        defer { DNSServiceRefDeallocate(browse); withExtendedLifetime(state) {} }
        while ProcessInfo.processInfo.systemUptime < deadline {
            try pump(browse)
            try check(state.error)
            guard !state.services.isEmpty,
                  ProcessInfo.processInfo.systemUptime - state.lastChange >= 0.25 else { continue }
            let candidates = state.services
            guard candidates.count <= 8 else { throw ambiguous }
            var targets = Set<Target>()
            var ranks: [Address: Int] = [:]
            func rank(_ service: Service) -> Int { instance.flatMap { registrationNumber(service.instance, instance: $0) } ?? 0 }
            for service in candidates.sorted(by: { a, b in
                if saved, rank(a) != rank(b) { return rank(a) > rank(b) }
                return (a.instance, a.index) < (b.instance, b.index)
            }) {
                try Task.checkCancellation()
                // Keep enough time to try all observed matching interfaces.
                let window = min(deadline, ProcessInfo.processInfo.systemUptime + 2)
                let addresses = try resolve(service, deadline: window)
                if saved {
                    for address in addresses { ranks[address] = max(ranks[address] ?? 0, rank(service)) }
                } else {
                    targets.formUnion(addresses.map { Target(instance: instance ?? service.instance, address: $0) })
                }
            }
            if saved, let instance, !ranks.isEmpty {
                return orderedSavedCandidates(ranks).map { Target(instance: instance, address: $0) }
            }
            let eligible = targets.filter { expectedHost == nil || $0.address.host == expectedHost }
            let ipv4 = eligible.filter { $0.address.isIPv4 }
            let preferred = ipv4.isEmpty ? eligible : ipv4
            guard preferred.count <= 1 else { throw ambiguous }
            if let target = preferred.first { return [target] }
            // A device can publish before its address arrives. Re-resolve within
            // the same time budget and continue handling browse changes.
        }
        throw BridgeError.message(kind == .pairing
            ? "Couldn’t find the phone’s pairing request. Keep Wireless debugging open, check that both devices share a network, then show a new QR code."
            : "Couldn’t find the paired phone on Wi-Fi. Turn on Wireless debugging and check that both devices share a network, then reconnect.")
    }

    private static func resolve(_ service: Service, deadline: TimeInterval) throws -> Set<Address> {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
        let state = ServiceState()
        var reference: DNSServiceRef?
        let result = DNSServiceResolve(&reference, 0, service.index, service.instance, service.type, service.domain, { _, _, _, error, _, target, port, _, _, context in
            guard let context else { return }
            let state = Unmanaged<ServiceState>.fromOpaque(context).takeUnretainedValue()
            state.error = error
            if error == 0, let target {
                let host = String(cString: target)
                guard host.utf8.count <= 255, host.lowercased().hasSuffix(".local."), port != 0 else { return }
                state.target = host; state.port = UInt16(bigEndian: port)
            }
        }, Unmanaged.passUnretained(state).toOpaque())
        try check(result)
        guard let reference else { throw discoveryUnavailable }
        defer { DNSServiceRefDeallocate(reference); withExtendedLifetime(state) {} }
        while state.target == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try pump(reference)
            if isGone(state.error) { return [] }; try check(state.error)
        }
        guard let target = state.target else { return [] }
        return try resolveAddresses(target: target, index: service.index, port: state.port, deadline: deadline)
    }

    private static func resolveAddresses(target: String, index: UInt32, port: UInt16, deadline: TimeInterval) throws -> Set<Address> {
        let state = AddressState(port: port)
        var reference: DNSServiceRef?
        let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let result = DNSServiceGetAddrInfo(&reference, 0, index, protocols, target, { _, flags, _, error, _, address, ttl, context in
            guard let context else { return }
            let state = Unmanaged<AddressState>.fromOpaque(context).takeUnretainedValue()
            state.error = error
            guard error == 0, let address, let value = CompanionWirelessBonjour.numericAddress(address, port: state.port) else { return }
            if ttl > 0, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
                if state.addresses.insert(value).inserted { state.lastChange = ProcessInfo.processInfo.systemUptime }
            } else if state.addresses.remove(value) != nil { state.lastChange = ProcessInfo.processInfo.systemUptime }
        }, Unmanaged.passUnretained(state).toOpaque())
        try check(result)
        guard let reference else { throw discoveryUnavailable }
        defer { DNSServiceRefDeallocate(reference); withExtendedLifetime(state) {} }
        while ProcessInfo.processInfo.systemUptime < deadline {
            try pump(reference)
            if !isGone(state.error) { try check(state.error) }
            if !state.addresses.isEmpty, ProcessInfo.processInfo.systemUptime - state.lastChange >= 0.25 { break }
        }
        return state.addresses
    }

    private static func numericAddress(_ address: UnsafePointer<sockaddr>, port: UInt16) -> Address? {
        let family = Int32(address.pointee.sa_family)
        if family == AF_INET {
            let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let value = UInt32(bigEndian: ipv4.s_addr)
            // Reject unspecified, multicast, and broadcast addresses. Loopback
            // is a valid numeric endpoint for authorized local ADB relays.
            guard value != 0, value < 0xe0000000 else { return nil }
        } else if family == AF_INET6 {
            let ipv6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
            let bytes = withUnsafeBytes(of: ipv6.sin6_addr) { Array($0) }
            // The numeric ADB endpoint format cannot reliably preserve an
            // interface zone across host processes. Prefer IPv4 on these LANs.
            guard ipv6.sin6_scope_id == 0, bytes.first != 0xff, bytes.contains(where: { $0 != 0 }),
                  !(bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) else { return nil }
        } else { return nil }
        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return Address(host: String(cString: text), port: port, isIPv4: family == AF_INET)
    }

    private static func pump(_ reference: DNSServiceRef) throws {
        try Task.checkCancellation()
        let fd = DNSServiceRefSockFD(reference)
        guard fd >= 0 else { throw discoveryUnavailable }
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&item, 1, 100)
        if result < 0 { if errno == EINTR { return }; throw discoveryUnavailable }
        if item.revents & Int16(POLLIN) != 0 { try check(DNSServiceProcessResult(reference)) }
        else if item.revents != 0 { throw discoveryUnavailable }
    }

    private static func isGone(_ error: DNSServiceErrorType) -> Bool {
        error == kDNSServiceErr_NoSuchRecord || error == kDNSServiceErr_NoSuchName || error == kDNSServiceErr_Timeout
    }

    private static func check(_ error: DNSServiceErrorType) throws {
        guard error != 0 else { return }
        if error == kDNSServiceErr_NoAuth || error == kDNSServiceErr_PolicyDenied {
            throw BridgeError.message("Allow DroidBridge in System Settings → Privacy & Security → Local Network, then try again.")
        }
        throw discoveryUnavailable
    }

    private static var discoveryUnavailable: BridgeError { .message("Local network discovery isn’t available. Check your Mac’s network connection and Local Network access.") }
    private static var ambiguous: BridgeError { .message("More than one matching Wi-Fi address appeared. Keep the phone on one network and try again.") }
}
