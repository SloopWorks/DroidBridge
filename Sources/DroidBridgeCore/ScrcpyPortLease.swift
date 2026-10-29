import Foundation
import Darwin

/// The pinned client's reverse tunnel is installed before its listening socket
/// binds. Reserve distinct host ports across DroidBridge processes so concurrent
/// fallback launches cannot connect to each other's listener during startup.
public final class ScrcpyPortLease: @unchecked Sendable {
    public let port: UInt16
    private let descriptor: Int32
    private init(port:UInt16,descriptor:Int32) {self.port=port;self.descriptor=descriptor}
    // The supervisor inherits the same open-file description as stdin. Closing
    // only this reference keeps the lock pinned through GUI crash cleanup;
    // LOCK_UN here would prematurely unlock the inherited reference too.
    deinit {close(descriptor)}
    public var inheritedInput: FileHandle {FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)}
    public static func acquire(directory:URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge/StreamPorts.noindex")) throws ->ScrcpyPortLease {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        // Avoid upstream's default 27183 range and macOS ephemeral ports. A
        // foreign listener is never replaced; exclusive bind preflight skips it.
        for port in UInt16(46000)...UInt16(46063) {
            let fd=open(directory.appendingPathComponent("\(port).lock").path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
            guard fd>=0 else {continue}
            var metadata=stat()
            guard fstat(fd,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==getuid(),flock(fd,LOCK_EX|LOCK_NB)==0 else {close(fd);continue}
            let socketFD=socket(AF_INET,SOCK_STREAM,0)
            guard socketFD>=0 else {flock(fd,LOCK_UN);close(fd);continue}
            var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET)
            address.sin_port=port.bigEndian;address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"))
            let bound=withUnsafePointer(to:&address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(socketFD,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }==0
            close(socketFD)
            if bound {return ScrcpyPortLease(port:port,descriptor:fd)}
            flock(fd,LOCK_UN);close(fd)
        }
        throw BridgeError.message("No free DroidBridge fallback stream port is available. Close an app window and retry.")
    }
}
