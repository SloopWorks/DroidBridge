import Foundation

public struct Toolchain {
    public let adb: String
    public let scrcpy: String
    public let server: String
    public let environment: [String: String]

    /// Bundle tools take precedence over installation-specific paths. Explicit
    /// paths and environment overrides support reproducible developer/test runs.
    public init(adb: String? = nil, scrcpy: String? = nil, server: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        let resources = Bundle.main.resourceURL?.appendingPathComponent("Runtime")
        self.adb = Self.resolve(adb ?? env["DROIDBRIDGE_ADB"], name: "adb", bundled: resources?.appendingPathComponent("bin/adb").path, extras: [NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb", NSHomeDirectory() + "/.local/bin/adb"])
        self.scrcpy = Self.resolve(scrcpy ?? env["DROIDBRIDGE_SCRCPY"], name: "scrcpy", bundled: resources?.appendingPathComponent("Player.app/Contents/MacOS/scrcpy").path, extras: [])
        let serverPaths = [server, env["DROIDBRIDGE_SERVER"], resources?.appendingPathComponent("share/scrcpy/scrcpy-server").path, "/opt/homebrew/share/scrcpy/scrcpy-server", "/usr/local/share/scrcpy/scrcpy-server"].compactMap { $0 }
        self.server = serverPaths.first { FileManager.default.fileExists(atPath: $0) } ?? serverPaths.first ?? "/opt/homebrew/share/scrcpy/scrcpy-server"
        self.environment = ["ADB": self.adb, "SCRCPY_SERVER_PATH": self.server]
    }

    private static func resolve(_ explicit: String?, name: String, bundled: String?, extras: [String]) -> String {
        if let explicit { return explicit }
        let search = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":").map { String($0) + "/" + name }
        let paths = [bundled].compactMap { $0 } + ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name] + extras + search
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/" + name
    }

    public func validate() throws {
        for path in [adb, scrcpy] where !FileManager.default.isExecutableFile(atPath: path) { throw BridgeError.message("Required tool is unavailable: \(path). Install Android platform-tools and scrcpy 5.0.1 or use the packaged application.") }
        guard FileManager.default.fileExists(atPath: server) else { throw BridgeError.message("scrcpy 5.0.1 server is unavailable: \(server)") }
    }
}
