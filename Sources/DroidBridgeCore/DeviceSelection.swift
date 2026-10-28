import Foundation

public enum DeviceSelection {
    /// An explicit launch target must never silently fall back to another phone.
    /// A later user selection takes precedence while that device remains present.
    public static func index(in devices: [AndroidDevice], currentSerial: String?, preferredSerial: String?) -> Int? {
        if let currentSerial, let index = devices.firstIndex(where: { $0.serial == currentSerial }) { return index }
        if let preferredSerial { return devices.firstIndex(where: { $0.serial == preferredSerial }) }
        return devices.isEmpty ? nil : 0
    }
}
