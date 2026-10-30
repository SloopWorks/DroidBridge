import Foundation
import Darwin

public struct CompanionPairCode: Equatable {
    public let secret: String
    public let deviceID: String?
    public let expires: Date?
    public let serverPin: String

    public init(_ text: String, now: Date = Date()) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 1024 else { throw BridgeError.message("This pairing code is too long.") }
        func validSecret(_ value: String) -> Bool {
            guard value.utf8.count == 43, value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
                  let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), bytes.count == 32 else { return false }
            return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value
        }
        guard let uri = URLComponents(string: text), uri.scheme == "droidbridge", uri.host == "pair", uri.path.isEmpty,
              uri.user == nil, uri.password == nil, uri.port == nil, uri.fragment == nil, let query = uri.queryItems,
              query.count == 4, Set(query.map(\.name)) == ["secret", "expires", "device_id", "server_pin"],
              let value = query.first(where: { $0.name == "secret" })?.value, validSecret(value),
              let device = query.first(where: { $0.name == "device_id" })?.value, UUID(uuidString: device) != nil,
              let pin = query.first(where: { $0.name == "server_pin" })?.value, pin.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let seconds = query.first(where: { $0.name == "expires" })?.value, seconds.allSatisfy({ $0.isASCII && $0.isNumber }),
              let epoch = TimeInterval(seconds), epoch.isFinite else { throw BridgeError.message("Use the complete current DroidBridge pairing link or QR, including its server fingerprint. A secret alone cannot authenticate the phone.") }
        let expiry = Date(timeIntervalSince1970: epoch)
        guard expiry > now else { throw BridgeError.message("This pairing code has expired. Open a new pairing window on the phone.") }
        guard expiry.timeIntervalSince(now) <= 180 else { throw BridgeError.message("The phone and Mac clocks differ. Correct their time, then open a new pairing link on the phone.") }
        secret = value; deviceID = device.lowercased(); expires = expiry; serverPin = pin
    }
}

/// Wireless debugging is Android's TLS-authenticated ADB transport. The
/// companion API still stays on loopback behind an exact owned ADB forward.
public struct CompanionWirelessEndpoint: Equatable {
    public let argument: String
    public init(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 300, !value.contains(where: { $0.isWhitespace }) else {
            throw BridgeError.message("Enter the phone's IP address and port, for example 192.168.1.10:37123.")
        }
        let host: String, portText: String
        if value.hasPrefix("["), let end = value.firstIndex(of: "]"), value.index(after: end) < value.endIndex,
           value[value.index(after: end)] == ":" {
            host = String(value[value.index(after: value.startIndex)..<end])
            portText = String(value[value.index(end, offsetBy: 2)...])
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { throw BridgeError.message("Enter a numeric IPv6 address in brackets followed by a port.") }
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw BridgeError.message("Enter a numeric IP address followed by the port shown on the phone.") }
            host = String(parts[0]); portText = String(parts[1])
            var address = in_addr()
            guard inet_pton(AF_INET, host, &address) == 1 else { throw BridgeError.message("Enter the phone's numeric IP address, not a web address or hostname.") }
        }
        guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(portText), (1...65535).contains(port) else {
            throw BridgeError.message("The wireless debugging port must be between 1 and 65535.")
        }
        argument = value
    }
}
