import Foundation

/// Capture is device-wide. No route authorizes microphone capture.
public enum DeviceAudioRoute: String, Codable, CaseIterable, Sendable {
    case phone, mac, macAndPhone
}
public enum DeviceAudioPhase: String, Codable, CaseIterable, Sendable {
    case phone, starting, ready, shared, failed
}
public struct DeviceAudioStatus: Codable, Equatable, Sendable {
    public let route: DeviceAudioRoute
    public let phase: DeviceAudioPhase
    public let message: String
    public init(route: DeviceAudioRoute, phase: DeviceAudioPhase, message: String) {
        self.route=route; self.phase=phase; self.message=message
    }
}
