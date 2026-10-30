import Foundation

/// An outbound diagnostic schema, not an open-ended remote object with a few
/// guessed secret keys removed. Unknown nested fields never enter an export.
public enum CompanionDiagnostics {
    public static func sanitized(_ input: [String: CompanionJSON]) -> [String: CompanionJSON] {
        var result: [String: CompanionJSON] = [:]
        let numeric: [String: ClosedRange<Double>] = ["protocol": 0...100, "protocol_version": 0...100, "sdk": 0...1000, "battery_percent": 0...100, "thermal_status": 0...6, "active_transfers": 0...4, "uptime_seconds": 0...315_576_000]
        for (key, range) in numeric where input[key] != nil {
            if let value = input[key]?.number, value.isFinite, range.contains(value), key == "uptime_seconds" || value.rounded() == value { result[key] = .number(value) }
            else { result[key] = .null }
        }
        for key in ["charging", "power_save", "service_running"] where input[key] != nil { result[key] = input[key]?.bool.map(CompanionJSON.bool) ?? .null }
        let enums: [String: Set<String>] = ["network_class": ["none", "wifi", "cellular", "ethernet", "vpn", "other"], "profile": ["balanced", "responsive", "battery"], "phone_command_journal": ["available", "unavailable"], "received_text_journal": ["available", "unavailable"]]
        for (key, values) in enums where input[key] != nil { result[key] = input[key]?.string.flatMap { values.contains($0) ? .string($0) : nil } ?? .null }
        if let date = input["observed_at"]?.string, date.utf8.count <= 40, date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$", options: .regularExpression) != nil { result["observed_at"] = .string(date) }
        if let permissions = input["permissions"]?.object {
            var accepted: [String: CompanionJSON] = [:]
            for key in ["notifications", "clipboard", "notification_access", "notification_listener", "post_notifications", "service"] {
                if let value = permissions[key]?.bool { accepted[key] = .bool(value) }
                else if let value = permissions[key]?.string, ["granted", "denied", "true", "false", "enabled", "disabled", "unavailable", "unknown"].contains(value) { accepted[key] = .string(value) }
            }
            result["permissions"] = .object(accepted)
        }
        if let values = input["capabilities"]?.array {
            let allowed: Set<String> = ["catalog", "icons", "commands", "sessions", "share", "clipboard", "notifications", "notification_replies", "profiles", "diagnostics", "delivery"]
            result["capabilities"] = .array(values.compactMap(\.string).filter { allowed.contains($0) }.prefix(16).map(CompanionJSON.string))
        }
        if let values = input["counters"]?.object {
            let keys = ["requests", "errors", "bytes_received", "bytes_sent", "reconnects", "catalog_reads", "icon_cache_hits", "icon_cache_misses"]
            result["counters"] = .object(values.filter { keys.contains($0.key) && $0.value.number.map { $0.isFinite && $0 >= 0 && $0 <= 9_007_199_254_740_991 && $0.rounded() == $0 } == true })
        }
        return result
    }
    public static func healthSummary(_ input: [String: CompanionJSON]) -> String {
        let values = sanitized(input)
        let battery = values["battery_percent"]?.number.map { "\(Int($0))%" } ?? "unknown"
        let charging = values["charging"]?.bool.map { $0 ? "charging" : "not charging" } ?? "charging unknown"
        let thermal = values["thermal_status"]?.number.map { ["normal", "light", "moderate", "severe", "critical", "emergency", "shutdown"][Int($0)] } ?? "unknown"
        return "Battery \(battery) · \(charging)\nThermal \(thermal) · Network \(values["network_class"]?.string ?? "unknown")\nPhone observed: \(values["observed_at"]?.string ?? "unknown")"
    }
}
