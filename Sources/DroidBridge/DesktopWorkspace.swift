import AppKit

enum DesktopWorkspaceSection: String, CaseIterable {
    case apps, sessions, handoff, notifications, devices, deviceSettings, diagnostics, delivery
    static let primary: [Self] = [.apps, .sessions, .handoff, .notifications, .devices]
    var title: String {
        switch self {
        case .apps: return "Apps"
        case .sessions: return "Sessions"
        case .handoff: return "Handoff"
        case .notifications: return "Notifications"
        case .devices: return "Devices"
        case .deviceSettings: return "Device Settings"
        case .diagnostics: return "Diagnostics"
        case .delivery: return "Release Information"
        }
    }
    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .sessions: return "macwindow.on.rectangle"
        case .handoff: return "arrow.left.arrow.right"
        case .notifications: return "bell"
        case .devices: return "iphone"
        case .deviceSettings: return "slider.horizontal.3"
        case .diagnostics: return "stethoscope"
        case .delivery: return "info.circle"
        }
    }
    var companionPage: CompanionPage {
        switch self {
        case .apps: return .apps
        case .sessions: return .sessions
        case .handoff: return .handoff
        case .notifications: return .notifications
        case .devices: return .connection
        case .deviceSettings: return .performance
        case .diagnostics: return .diagnostics
        case .delivery: return .delivery
        }
    }
}
