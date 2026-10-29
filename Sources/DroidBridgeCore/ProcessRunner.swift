import Foundation
import Darwin

public struct ProcessResult {
    public let output: String
    public let status: Int32
}

/// Bounded subprocess execution without a shell. Combined stdout/stderr is staged to
/// a temporary file so a verbose child cannot deadlock a pipe or exhaust memory.
public enum ProcessRunner {
    public static func run(_ executable: String, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 20, allowNonZeroExit: Bool = false) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(executable, arguments: arguments, environment: environment, timeout: timeout, allowNonZeroExit: allowNonZeroExit)
        }.value
    }

    private static func runBlocking(_ executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval, allowNonZeroExit: Bool) throws -> ProcessResult {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: path.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: path) }
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            process.standardOutput = handle
            process.standardError = handle
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(max(0.1, timeout))
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
                if let size = try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber, size.intValue > 4 * 1024 * 1024 { break }
            }
            let exceeded = process.isRunning
            if exceeded {
                process.terminate()
                let grace = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            let reader = try FileHandle(forReadingFrom: path)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 4 * 1024 * 1024) ?? Data()
            let output = String(decoding: data, as: UTF8.self)
            if exceeded { throw BridgeError.message("Command exceeded its time or output limit: \(URL(fileURLWithPath: executable).lastPathComponent). \(output.suffix(1000))") }
            guard allowNonZeroExit || process.terminationStatus == 0 else { throw BridgeError.message("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)): \(output.suffix(3000))") }
            return ProcessResult(output: output, status: process.terminationStatus)
    }
}
