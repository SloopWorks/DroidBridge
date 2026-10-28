import Foundation
import Darwin
import DroidBridgeCore

/// A receipt is written before any remote staging. It contains no command or
/// arbitrary deletion path: every cleanup target is derived from a validated
/// scrcpy session ID. Active application/wrapper owners are never reconciled.
struct SessionReceipt: Codable {
    let ownerPID: Int32
    let serial: String
    let scid: String
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge/Receipts",isDirectory:true) }
    var remote: String { "/data/local/tmp/droidbridge-\(scid).jar" }
    var socket: String { "localabstract:scrcpy_\(scid)" }
    var valid: Bool { ownerPID > 1 && serial.range(of:"^[A-Za-z0-9._:-]+$",options:.regularExpression) != nil && scid.range(of:"^[0-7][0-9a-f]{7}$",options:.regularExpression) != nil }
    func save(directory: URL = Self.directory) throws -> URL {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url = directory.appendingPathComponent(scid+".json")
        try JSONEncoder().encode(self).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        return url
    }
}

extension BridgeSession {
    /// Called before discovering devices. Offline failures retain their receipt
    /// for the next launch; cleanup never kills ADB or touches another owner.
    public static func recoverAbandonedSessions(toolchain: Toolchain) async -> [String] {
        await recoverAbandonedSessions(toolchain:toolchain,receiptsDirectory:SessionReceipt.directory)
    }
    static func recoverAbandonedSessions(toolchain: Toolchain, receiptsDirectory: URL) async -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at:receiptsDirectory,includingPropertiesForKeys:[.fileSizeKey])) ?? []
        let deadline = Date().addingTimeInterval(15)
        var messages: [String] = []
        for file in files.prefix(64) where file.pathExtension == "json" {
            if Date() >= deadline { messages.append("Deferred remaining abandoned sessions until next launch"); break }
            guard let attributes = try? file.resourceValues(forKeys:[.fileSizeKey]), (attributes.fileSize ?? 4097) <= 4096,
                  let bytes = try? Data(contentsOf:file), let receipt = try? JSONDecoder().decode(SessionReceipt.self,from:bytes), receipt.valid else { continue }
            if kill(receipt.ownerPID,0) == 0 || errno == EPERM { continue }
            do {
                let list = try await ProcessRunner.run(toolchain.adb,arguments:["forward","--list"],environment:toolchain.environment,timeout:5)
                let owned = list.output.components(separatedBy:.newlines).compactMap { line -> String? in
                    let columns = line.split(whereSeparator:{$0.isWhitespace}).map(String.init)
                    return columns.count == 3 && columns[0] == receipt.serial && columns[2] == receipt.socket ? columns[1] : nil
                }
                for endpoint in owned {
                    _ = try await ProcessRunner.run(toolchain.adb,arguments:["-s",receipt.serial,"forward","--remove",endpoint],environment:toolchain.environment,timeout:5)
                }
                _ = try await ProcessRunner.run(toolchain.adb,arguments:["-s",receipt.serial,"shell","rm","-f",receipt.remote],environment:toolchain.environment,timeout:5)
                try? FileManager.default.removeItem(at:file)
                messages.append("Recovered abandoned session \(receipt.scid) on \(receipt.serial)")
            } catch { messages.append("Deferred abandoned session \(receipt.scid): \(error.localizedDescription)") }
        }
        return messages
    }
}
