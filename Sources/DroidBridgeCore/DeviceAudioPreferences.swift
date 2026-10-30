import Foundation

/// Audio intent has its own authority so older DroidBridge binaries, which
/// rewrite preferences.json with their earlier schema, cannot erase Phone intent.
/// The existing envelope provides the same bounded, locked, atomic merge rules;
/// other envelope fields in this file are unused by audio consumers.
public enum DeviceAudioPreferences {
    public static var defaultURL:URL {
        DroidBridgePreferences.defaultURL.deletingLastPathComponent().appendingPathComponent("audio-preferences.json")
    }
    private static let canonicalPrefix = "droidbridge-canonical-"
    public static func loadRoutes(url:URL = defaultURL, paths:ManagedAppsPaths = .userDefault) throws ->[String:DeviceAudioRoute] {
        var routes = try DroidBridgePreferences.load(url:url).deviceAudioRoutes
        for (identity, aliases) in try CanonicalAliasAdmission.groups(paths:paths) where !aliases.isEmpty {
            let legacy = aliases.compactMap { routes[$0] }
            let route = routes[canonicalPrefix + identity] ?? (legacy.contains(.phone) ? .phone : legacy.contains(.macAndPhone) ? .macAndPhone : legacy.first)
            if let route { for alias in aliases { routes[alias] = route }; routes.removeValue(forKey:canonicalPrefix + identity) }
        }
        return routes
    }
    public static func capacityCount(_ routes:[String:DeviceAudioRoute], paths:ManagedAppsPaths = .userDefault) ->Int {
        guard let groups = try? CanonicalAliasAdmission.groups(paths:paths) else { return DroidBridgePreferences.maximumAudioDevices }
        var byAlias:[String:String] = [:]
        for (identity, aliases) in groups { for alias in aliases { byAlias[alias] = identity } }
        return Set(routes.keys.map { key in key.hasPrefix(canonicalPrefix) ? String(key.dropFirst(canonicalPrefix.count)) : byAlias[key] ?? key }).count
    }
    @discardableResult public static func setRoute(_ route:DeviceAudioRoute,for serial:String,url:URL = defaultURL,paths:ManagedAppsPaths = .userDefault) throws ->[String:DeviceAudioRoute] {
        try AndroidDiscovery.validateSerial(serial)
        let groups = try CanonicalAliasAdmission.groups(paths:paths)
        let group = groups.first { $0.value.contains(serial) }
        _ = try DroidBridgePreferences.update(url:url) { preferences in
            // Compact all verified legacy aliases before capacity admission.
            // Keep Phone whenever prior aliases disagree; explicit new intent
            // below can then deliberately select a different route.
            for (identity,aliases) in groups {
                let legacy=aliases.compactMap {preferences.deviceAudioRoutes[$0]}
                let accepted=preferences.deviceAudioRoutes[canonicalPrefix+identity] ?? (legacy.contains(.phone) ? .phone : legacy.contains(.macAndPhone) ? .macAndPhone : legacy.first)
                if let accepted,!legacy.isEmpty {
                    for alias in aliases {preferences.deviceAudioRoutes.removeValue(forKey:alias)}
                    preferences.deviceAudioRoutes[canonicalPrefix+identity]=accepted
                }
            }
            if let (identity, aliases) = group {
                for alias in aliases { preferences.deviceAudioRoutes.removeValue(forKey:alias) }
                preferences.deviceAudioRoutes[canonicalPrefix + identity] = route
            } else { preferences.deviceAudioRoutes[serial] = route }
        }
        return try loadRoutes(url:url,paths:paths)
    }
}
