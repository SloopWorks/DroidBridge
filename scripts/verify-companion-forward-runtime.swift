import Foundation
import DroidBridgeCore
import Darwin

/// Actual ADB allocation/teardown probe; only an explicitly owned QA emulator.
@main struct ForwardRuntime {
    static func main() async throws {
        guard let scope = CompanionQAScope.current,
              let index = CommandLine.arguments.firstIndex(of: "--adb"), index + 1 < CommandLine.arguments.count else {
            throw CompanionBoundaryError("qa_required", "An owned QA emulator, private root and explicit ADB executable are required.")
        }
        let adb = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
        let link = scope.root.appendingPathComponent("owned-adb")
        let parked = scope.root.appendingPathComponent("owned-adb.parked")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: link.path), !fm.fileExists(atPath: parked.path) else {
            throw CompanionBoundaryError("qa_collision", "Use a fresh QA root.")
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: adb.path)
        defer { try? fm.removeItem(at: link); try? fm.removeItem(at: parked) }
        func run(_ arguments: [String]) async throws -> String {
            try await ProcessRunner.run(adb.path, arguments: arguments, timeout: 5).output
        }
        func tuples() async throws -> [[String]] {
            try await run(["forward", "--list"]).split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        }
        let initial = try await tuples()
        let first = try CompanionForward.reserve(serial: scope.serial, adbPath: link.path)
        try await first.establish()
        let firstTuple = [scope.serial, "tcp:\(first.port)", "tcp:37841"]
        guard try await tuples().contains(firstTuple) else { throw CompanionBoundaryError("qa_missing_forward", "Real ADB did not publish the owned mapping.") }
        let receipts = scope.root.appendingPathComponent("CompanionForwards.noindex")
        let countBefore = try fm.contentsOfDirectory(atPath: receipts.path).count
        try fm.moveItem(at: link, to: parked)
        var failureObserved = false
        do { try await first.close() } catch { failureObserved = true }
        guard failureObserved, try fm.contentsOfDirectory(atPath: receipts.path).count == countBefore,
              try await tuples().contains(firstTuple) else { throw CompanionBoundaryError("qa_lost_ownership", "Failed cleanup lost its receipt or real mapping.") }
        try fm.moveItem(at: parked, to: link)
        try await first.close()
        guard try await !tuples().contains(firstTuple), try fm.contentsOfDirectory(atPath: receipts.path).isEmpty else { throw CompanionBoundaryError("qa_cleanup_failed", "Retry did not remove the owned real mapping and receipt.") }
        let second = try CompanionForward.reserve(serial: scope.serial, adbPath: link.path)
        try await second.establish()
        let secondLocal = "tcp:\(second.port)"
        _ = try await run(["-s", scope.serial, "forward", secondLocal, "tcp:37842"])
        let replacement = [scope.serial, secondLocal, "tcp:37842"]
        guard try await tuples().contains(replacement) else { throw CompanionBoundaryError("qa_missing_rebind", "ADB did not replace the test mapping.") }
        try await second.close()
        guard try await tuples().contains(replacement), try fm.contentsOfDirectory(atPath: receipts.path).isEmpty else { throw CompanionBoundaryError("qa_foreign_removed", "Companion teardown removed a replacement mapping.") }
        // This probe owns the replacement too, so delete it only after proving
        // production close preserved the foreign-to-that-owner tuple.
        _ = try await run(["-s", scope.serial, "forward", "--remove", secondLocal])
        let final = try await tuples()
        guard Set(initial.map { $0.joined(separator: " ") }) == Set(final.map { $0.joined(separator: " ") }) else { throw CompanionBoundaryError("qa_baseline_changed", "Real ADB forward inventory differs after cleanup.") }
        let result: [String: Any] = ["passed": true, "serial": scope.serial,
            "actual_adb_executable_unavailable_failure_observed": failureObserved,
            "receipt_and_mapping_retained_after_failure": true,
            "same_owner_retry_removed_exact_mapping": true,
            "actual_adb_replacement_mapping_preserved": true,
            "final_forward_inventory_matches_baseline": true,
            "scope": "Production Core objects; actual ADB transport. No broker retry, crash or physical USB/Wi-Fi claim."]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
    }
}
