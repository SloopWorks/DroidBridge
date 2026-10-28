import Foundation
public struct AndroidDevice: Identifiable, Codable, Hashable {
    public var id: String { serial }
    public let serial: String
    public let model: String
    public let state: String
    public init(serial: String, model: String, state: String = "device") { self.serial = serial; self.model = model; self.state = state }
}
public struct AndroidApplication: Identifiable, Codable, Hashable {
    public var id: String { packageName }
    public let packageName: String
    public let name: String
    public init(packageName: String, name: String) { self.packageName = packageName; self.name = name }
}
public enum BackendKind: String, CaseIterable, Codable { case scrcpy, native }
public struct SessionConfiguration: Codable {
    public var width: Int
    public var height: Int
    public var density: Int
    public var backend: BackendKind
    public init(width: Int = 720, height: Int = 1080, density: Int = 240, backend: BackendKind = .native) { self.width = width; self.height = height; self.density = density; self.backend = backend }
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
