import Foundation

/// Payload-free scheduling hint. Authenticated broker reads still grant work;
/// periodic polling recovers missed notifications.
public enum CompanionCommandWakeup {
    public static let name = Notification.Name("dev.droidbridge.companion.commands-ready.v1")
    public static func post(ownerPID: Int32) {
        DistributedNotificationCenter.default().postNotificationName(name, object: String(ownerPID), userInfo: nil, deliverImmediately: true)
    }
}

/// Phone-selected effects are explicit, bounded, and never inferred from content.
public enum CompanionShareAction: String, Sendable {
    case send, copy, open
    public static func validated(kind: String, payload: [String: CompanionJSON]) throws -> Self {
        guard let action = Self(rawValue: payload["action"]?.string ?? "send"),
              let text = payload["text"]?.string, !text.isEmpty,
              text.utf8.count <= (kind == "share_url" ? 8192 : 65_536) else {
            throw CompanionBoundaryError("invalid_content", "Choose a supported share action and bounded text.")
        }
        if kind == "share_url" || action == .open {
            guard kind == "share_url", let url = URL(string: text),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
                  url.user == nil, url.password == nil else {
                throw CompanionBoundaryError("invalid_url", "Only HTTP and HTTPS web links without embedded credentials can be opened.")
            }
        }
        return action
    }
}

public struct CompanionDesktopPreset: Sendable {
    public let packages: [String]
    public let profile: CompanionPerformanceProfile
    public let audioRoute: String
    public let screenOff: Bool
    public init(payload: [String: CompanionJSON]) throws {
        guard let packages = payload["packages"]?.array, (1...8).contains(packages.count),
              let rawProfile = payload["profile"]?.string, let profile = CompanionPerformanceProfile(rawValue: rawProfile),
              let route = payload["audio_route"]?.string, ["mac", "phone", "mac_and_phone"].contains(route),
              let off = payload["screen_off"]?.bool else {
            throw CompanionBoundaryError("invalid_preset", "A preset needs one to eight apps and supported audio, display and performance settings.")
        }
        let names = try packages.map { value -> String in
            guard let name = value.string else { throw CompanionBoundaryError("invalid_preset", "An app package must be text.") }
            try AndroidDiscovery.validatePackage(name)
            return name
        }
        guard Set(names).count == names.count else { throw CompanionBoundaryError("invalid_preset", "A preset cannot launch the same app twice.") }
        self.packages = names; self.profile = profile; self.audioRoute = route; self.screenOff = off
    }
}
