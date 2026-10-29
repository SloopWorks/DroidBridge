import Foundation
import CryptoKit
import Darwin

/// Serializes only a client's virtual-display/app initialization. Unlike the
/// stream-port lease, this descriptor must never be inherited by its child.
public final class ScrcpyStartupLease: @unchecked Sendable {
    private let descriptor:Int32
    private init(descriptor:Int32) {self.descriptor=descriptor}
    deinit {close(descriptor)}
    static func filename(serial:String) ->String {
        SHA256.hash(data:Data(serial.utf8)).map{String(format:"%02x",$0)}.joined()+".lock"
    }
    public static func acquire(serial:String,directory:URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge/StreamStartup.noindex"),timeout:TimeInterval=30) async throws ->ScrcpyStartupLease {
        try AndroidDiscovery.validateSerial(serial)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let fd=open(directory.appendingPathComponent(filename(serial:serial)).path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd>=0 else {throw BridgeError.message("Cannot safely open fallback startup lock")}
        var metadata=stat()
        guard fstat(fd,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==getuid() else {
            close(fd);throw BridgeError.message("Invalid fallback startup lock")
        }
        let deadline=ProcessInfo.processInfo.systemUptime+max(0.02,min(30,timeout))
        do {
            while true {
                try Task.checkCancellation()
                if flock(fd,LOCK_EX|LOCK_NB)==0 {return ScrcpyStartupLease(descriptor:fd)}
                guard errno==EWOULDBLOCK || errno==EINTR else {throw BridgeError.message("Cannot acquire fallback startup lock")}
                guard ProcessInfo.processInfo.systemUptime<deadline else {throw BridgeError.message("Another Android app is still starting on this device. Retry in a moment.")}
                try await Task.sleep(for:.milliseconds(20))
            }
        } catch {close(fd);throw error}
    }
}
