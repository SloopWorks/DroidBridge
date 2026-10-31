import Foundation

/// Deliberate connection policy. Never changes Android global settings or
/// restarts an existing app implicitly. Encoders pin their ceiling at startup.
public enum CompanionPerformanceProfile: String, Codable, CaseIterable, Sendable {
    case balanced, responsive, battery

    public var maximumFramesPerSecond: Int {
        switch self { case .balanced: return 30; case .responsive: return 60; case .battery: return 15 }
    }
    public var statusInterval: TimeInterval {
        switch self { case .balanced: return 2; case .responsive: return 1; case .battery: return 5 }
    }
    public var assetConcurrency: Int { self == .battery ? 1 : 2 }
    public func applying(to configuration: SessionConfiguration) -> SessionConfiguration {
        var value = configuration
        value.maximumFramesPerSecond = maximumFramesPerSecond
        return value
    }
}
