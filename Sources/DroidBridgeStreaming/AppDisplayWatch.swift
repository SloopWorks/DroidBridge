import DroidBridgeCore
import Foundation

/// Tracks an Android task, not frame color, frame rate, or package presence
/// alone. An idle app or a second instance on the phone is not a display move.
struct AppDisplayWatch {
    struct TaskID: Hashable {
        let user: Int32
        let id: Int32
    }

    struct Move: Equatable {
        let task: TaskID
        let display: Int32
    }

    struct Snapshot {
        let displays: Set<Int32>
        let placements: [TaskID: Set<Int32>]

        init?(_ output: String, package: String) {
            guard output.hasPrefix("ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)") else { return nil }
            var displays = Set<Int32>()
            var placements: [TaskID: Set<Int32>] = [:]
            var current: Int32?
            for line in output.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("Display #") {
                    current = Int32(line.dropFirst("Display #".count).prefix(while: \.isNumber))
                    if let current { displays.insert(current) }
                    continue
                }
                guard let current, let range = line.range(of: #"^\s*\* Hist\s+#[0-9]+: ActivityRecord\{"#, options: .regularExpression),
                      let end = line[range.upperBound...].firstIndex(of: "}") else { continue }
                let fields = line[range.upperBound..<end].split(whereSeparator: \.isWhitespace)
                guard fields.count == 4, fields[1].hasPrefix("u"), fields[3].hasPrefix("t"),
                      fields[2].hasPrefix(package + "/"),
                      let user = Int32(fields[1].dropFirst()), user >= 0,
                      let task = Int32(fields[3].dropFirst()), task >= 0 else { continue }
                placements[TaskID(user: user, id: task), default: []].insert(current)
            }
            guard !displays.isEmpty else { return nil }
            self.displays = displays
            self.placements = placements
        }
    }

    private var ownedTasks = Set<TaskID>()
    var hasObservedOwnedTask: Bool { !ownedTasks.isEmpty }
    private(set) var candidate: Move?

    mutating func observe(_ snapshot: Snapshot?, ownedDisplay: Int32) -> Move? {
        guard let snapshot, snapshot.displays.contains(ownedDisplay) else { candidate = nil; return nil }
        let here = Set(snapshot.placements.filter { $0.value.contains(ownedDisplay) }.keys)
        if !here.isEmpty { ownedTasks = here; candidate = nil; return nil }
        let moves = ownedTasks.compactMap { task -> Move? in
            guard let displays = snapshot.placements[task], displays.count == 1, let display = displays.first else { return nil }
            return Move(task: task, display: display)
        }
        let next = moves.count == 1 ? moves.first : nil
        let confirmed = candidate == next ? next : nil
        candidate = next
        return confirmed
    }

    static func probe(adb: String, environment: [String: String], serial: String, package: String) async -> Snapshot? {
        // The session validates both inputs at admission. Ask Android to scope
        // the dump to this package and retain only task/display IDs in memory.
        guard let result = try? await ProcessRunner.run(adb, arguments: ["-s", serial, "shell", "dumpsys", "activity", "-p", package, "activities"], environment: environment, timeout: 2),
              !Task.isCancelled else { return nil }
        return await Task.detached(priority: .utility) { Snapshot(result.output, package: package) }.value
    }

    static func launchOutput(_ url: URL) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024) ?? Data()
        // The client's PTY title sequence can interleave with server output.
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .components(separatedBy: .newlines)
    }

    static func launchedDisplay(_ lines: [String], package: String) -> Int32? {
        let displays = Set(lines.compactMap { line -> Int32? in
            guard line.hasPrefix("[server] INFO: Starting app "),
                  let range = line.range(of: "[\(package)] on display ", options: .backwards),
                  line.hasSuffix("..."),
                  let display = Int32(line[range.upperBound...].dropLast(3)), display > 0 else { return nil }
            return display
        })
        return displays.count == 1 ? displays.first : nil
    }
}
