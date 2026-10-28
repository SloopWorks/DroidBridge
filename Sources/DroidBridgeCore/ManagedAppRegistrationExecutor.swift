import Foundation

/// Run outside the catalog lock. Registration/unregistration use the macOS bundled utility in a bounded
/// subprocess, so an unresponsive LaunchServices service cannot stall a cycle.
public enum ManagedAppRegistrationExecutor {
    public static func perform(_ action: ManagedAppRegistrationAction) async throws {
        let executable = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = try await ProcessRunner.run(executable, arguments: [action.register ? "-f" : "-u", action.bundleURL.path], timeout: 3)
    }
}
