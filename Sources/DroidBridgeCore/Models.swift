import Foundation
public struct AndroidDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: String { serial }
    public let serial: String
    public let model: String
    public let state: String
    public init(serial: String, model: String, state: String = "device") { self.serial = serial; self.model = model; self.state = state }
}
public struct AndroidApplication: Identifiable, Codable, Hashable, Sendable {
    public var id: String { packageName }
    public let packageName: String
    public let name: String
    public init(packageName: String, name: String) { self.packageName = packageName; self.name = name }
}
public enum BackendKind: String, CaseIterable, Codable, Sendable { case scrcpy, native }
public struct SessionConfiguration: Codable {
    public var width: Int
    public var height: Int
    public var density: Int
    public var backend: BackendKind
    /// Applies only to this virtual display. App-drawn controls are separate;
    /// the session always hides Android's software keyboard on this display.
    /// The phone's system UI and global keyboard settings are never changed.
    public var showSystemDecorations: Bool
    public init(width: Int = 720, height: Int = 1080, density: Int = 240, backend: BackendKind = .native, showSystemDecorations: Bool = true) {
        self.width = width; self.height = height; self.density = density; self.backend = backend
        self.showSystemDecorations = showSystemDecorations
    }
    private enum CodingKeys: String, CodingKey { case width, height, density, backend, showSystemDecorations }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        density = try values.decode(Int.self, forKey: .density)
        backend = try values.decode(BackendKind.self, forKey: .backend)
        // Existing persisted sessions retain the previous decorated behavior.
        showSystemDecorations = try values.decodeIfPresent(Bool.self, forKey: .showSystemDecorations) ?? true
    }
}
public enum SessionState: String, Codable { case starting, running, stopping, stopped, failed }
public struct SessionDescriptor: Identifiable, Codable {
    public let id: UUID
    public let device: AndroidDevice
    public let application: AndroidApplication
    public var configuration: SessionConfiguration
    public init(id: UUID = UUID(), device: AndroidDevice, application: AndroidApplication, configuration: SessionConfiguration) { self.id = id; self.device = device; self.application = application; self.configuration = configuration }
}
public enum BridgeError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
