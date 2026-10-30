import Foundation

/// Audio intent has its own authority so older DroidBridge binaries, which
/// rewrite preferences.json with their earlier schema, cannot erase Phone intent.
/// The existing envelope provides the same bounded, locked, atomic merge rules;
/// other envelope fields in this file are unused by audio consumers.
public enum DeviceAudioPreferences {
    public static var defaultURL:URL {
        DroidBridgePreferences.defaultURL.deletingLastPathComponent().appendingPathComponent("audio-preferences.json")
    }
    public static func loadRoutes(url:URL = defaultURL) throws ->[String:DeviceAudioRoute] {
        try DroidBridgePreferences.load(url:url).deviceAudioRoutes
    }
    @discardableResult public static func setRoute(_ route:DeviceAudioRoute,for serial:String,url:URL = defaultURL) throws ->[String:DeviceAudioRoute] {
        try AndroidDiscovery.validateSerial(serial)
        return try DroidBridgePreferences.update(url:url) {$0.deviceAudioRoutes[serial]=route}.deviceAudioRoutes
    }
}
