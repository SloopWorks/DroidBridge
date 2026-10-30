import Foundation
import Security
import CryptoKit
import Darwin

/// A phone never supplies a path. Only an already running, signed main host may
/// register its exact executable; every subsequent bootstrap revalidates bytes.
public struct CompanionBrokerHostApplication: Codable, Sendable {
    public let path: String
    public let executableSHA256: String
    public let bundleIdentifier: String
    public static func register(path: String, owner: CompanionBrokerOwner) throws -> Self {
        let value = try validate(path: path)
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard owner.isAlive, proc_pidpath(owner.pid, &buffer, UInt32(buffer.count)) > 0 else { throw CompanionBoundaryError("host_identity_unavailable", "The running Mac host identity is unavailable.") }
        let actual = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        guard actual == URL(fileURLWithPath: value.path).appendingPathComponent("Contents/MacOS/DroidBridge").path else { throw CompanionBoundaryError("host_identity_mismatch", "Only the running DroidBridge main application can register its installed path.") }
        return value
    }
    public static func validate(path: String) throws -> Self {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.utf8.count <= 2048, path.hasPrefix("/"), url.path == path, url.pathExtension == "app", url.resolvingSymlinksInPath().path == path else { throw CompanionBoundaryError("invalid_host_path", "DroidBridge must be installed at a canonical application path.") }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, [geteuid(), 0].contains(info.st_uid), info.st_mode & 0o022 == 0 else { throw CompanionBoundaryError("unsafe_host_path", "The installed DroidBridge application has unsafe ownership or permissions.") }
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL), data.count <= 65_536,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "app.droidbridge.desktop", plist["CFBundleExecutable"] as? String == "DroidBridge", plist["CFBundlePackageType"] as? String == "APPL" else { throw CompanionBoundaryError("invalid_host_bundle", "Only the installed DroidBridge main application can be started.") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw CompanionBoundaryError("invalid_host_signature", "The installed DroidBridge signature could not be verified. Reinstall DroidBridge.") }
        let executable = url.appendingPathComponent("Contents/MacOS/DroidBridge")
        guard lstat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 134_217_728, [geteuid(), 0].contains(info.st_uid), info.st_mode & 0o022 == 0 else { throw CompanionBoundaryError("invalid_host_executable", "The installed DroidBridge executable is unavailable.") }
        let hash = SHA256.hash(data: try Data(contentsOf: executable, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        return .init(path: path, executableSHA256: hash, bundleIdentifier: "app.droidbridge.desktop")
    }
    public func revalidate() throws {
        let current = try Self.validate(path: path)
        guard current.executableSHA256 == executableSHA256, current.bundleIdentifier == bundleIdentifier else { throw CompanionBoundaryError("host_updated", "Open the updated DroidBridge application once before launching from the phone.") }
    }
    public func openArguments(scope: CompanionQAScope? = .current) -> [String] {
        var arguments = ["-n", path]
        if let scope { arguments += ["--args", "--companion-qa-root", scope.root.path, "--serial", scope.serial] }
        return arguments
    }
}
