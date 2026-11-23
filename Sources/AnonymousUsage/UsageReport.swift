import Foundation
import Network
import Security

/// Only these three bounded integers can cross the transport boundary.
public struct UsageReport: Encodable, Equatable, Sendable {
    public let foregroundSessions: Int
    public let activeMinutes: Int
    public let nativeSessions: Int

    enum CodingKeys: String, CodingKey {
        case foregroundSessions = "foreground_sessions"
        case activeMinutes = "active_minutes"
        case nativeSessions = "native_sessions"
    }
}

/// Perform a synchronous handoff only while the ledger still grants the same consent.
public typealias UsageAuthorization = (_ handoff: () -> Void) -> Bool

public protocol UsageTransport: AnyObject {
    func send(_ report: UsageReport, whileAuthorized: @escaping UsageAuthorization)
    func cancel()
}

/// A local QA adapter. Fixed destination and fixed request headers avoid cookies,
/// proxy discovery, redirects, URL credentials and system-specific user agents.
public final class LoopbackUsageTransport: UsageTransport {
    private let sender: FixedHTTPUsageTransport
    public init(port: UInt16) { sender = FixedHTTPUsageTransport(host: "127.0.0.1", port: port, tls: false) }
    public func send(_ report: UsageReport, whileAuthorized: @escaping UsageAuthorization) {
        sender.send(report, whileAuthorized: whileAuthorized)
    }
    public func cancel() { sender.cancel() }
}

/// This prospective endpoint is contacted only when the host explicitly wires this
/// adapter and its user consents. TLS uses system trust and hostname verification.
public final class ProductionUsageTransport: UsageTransport {
    private let sender: FixedHTTPUsageTransport
    public init?(approvedEndpoint: URL) {
        guard approvedEndpoint.absoluteString == "https://usage.sloopworks.com/v1/droidbridge/usage" else { return nil }
        sender = FixedHTTPUsageTransport(host: "usage.sloopworks.com", port: 443, tls: true)
    }
    public func send(_ report: UsageReport, whileAuthorized: @escaping UsageAuthorization) {
        sender.send(report, whileAuthorized: whileAuthorized)
    }
    public func cancel() { sender.cancel() }
}

private final class FixedHTTPUsageTransport: UsageTransport {
    private let host: String
    private let port: UInt16
    private let tls: Bool
    private let queue = DispatchQueue(label: "works.sloop.anonymous-usage.transport")
    private var connection: NWConnection?

    init(host: String, port: UInt16, tls: Bool) {
        self.host = host
        self.port = port
        self.tls = tls
    }

    public func send(_ report: UsageReport, whileAuthorized: @escaping UsageAuthorization) {
        queue.async { [self] in
            guard connection == nil, port > 0, let destination = NWEndpoint.Port(rawValue: port),
                  let body = try? JSONEncoder().encode(report) else { return }
            let parameters: NWParameters
            if tls {
                let options = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_tickets_enabled(options.securityProtocolOptions, false)
                sec_protocol_options_set_tls_resumption_enabled(options.securityProtocolOptions, false)
                parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
            } else {
                parameters = .tcp
            }
            let socket = NWConnection(host: NWEndpoint.Host(host), port: destination, using: parameters)
            connection = socket
            let headers = "POST /v1/droidbridge/usage HTTP/1.1\r\nHost: \(host):\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            socket.stateUpdateHandler = { [weak self, weak socket] state in
                guard let self, let socket, self.connection === socket else { return }
                switch state {
                case .ready:
                    let admitted = whileAuthorized {
                        socket.send(content: Data(headers.utf8) + body, completion: .contentProcessed { error in
                            if error != nil { self.finish(socket); return }
                            socket.receive(minimumIncompleteLength: 1, maximumLength: 256) { _, _, _, _ in
                                self.finish(socket)
                            }
                        })
                    }
                    if !admitted { self.finish(socket) }
                case .failed, .cancelled: self.finish(socket)
                default: break
                }
            }
            guard whileAuthorized({ socket.start(queue: queue) }) else { finish(socket); return }
            queue.asyncAfter(deadline: .now() + 3) { [weak self, weak socket] in
                if let socket { self?.finish(socket) }
            }
        }
    }

    public func cancel() {
        queue.async { [self] in
            if let connection { finish(connection) }
        }
    }

    private func finish(_ socket: NWConnection) {
        guard connection === socket else { return }
        connection = nil
        socket.stateUpdateHandler = nil
        socket.cancel()
    }
}
