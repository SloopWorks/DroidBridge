import Foundation
import Darwin
import DroidBridgeCore

/// Audio diagnostics contain no PCM. Bound both scan work and retained bytes;
/// never unlink a stable lease inode or an attempt with a live owner.
enum DeviceAudioArtifacts {
    private struct Owner:Decodable {let ownerPID:Int32,supervisorPID:Int32}
    static func prepare(_ directory:URL) throws {
        try locked(directory) {
            let files=try entries(directory)
            var held=Set<String>()
            var unknownHeld=false
            for name in files where name.hasSuffix(".lock") && name.count==69 {
                let fd=open(directory.appendingPathComponent(name).path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
                guard fd>=0 else {continue};defer {close(fd)}
                var metadata=stat()
                guard fstat(fd,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==getuid() else {continue}
                if flock(fd,LOCK_EX|LOCK_NB)==0 {flock(fd,LOCK_UN);continue}
                guard errno==EWOULDBLOCK else {throw BridgeError.message("Cannot verify audio artifact ownership")}
                var bytes=[UInt8](repeating:0,count:37)
                if pread(fd,&bytes,37,0)==36,let token=String(bytes:bytes.prefix(36),encoding:.utf8),UUID(uuidString:token) != nil {held.insert(token)}
                else {unknownHeld=true}
            }
            for name in files {
                let url=directory.appendingPathComponent(name)
                let token=url.deletingPathExtension().lastPathComponent
                guard !unknownHeld,UUID(uuidString:token) != nil,!held.contains(token),["json","log"].contains(url.pathExtension) else {continue}
                let receipt=directory.appendingPathComponent(token+".json")
                if let data=try? read(receipt,4096),let owner=try? JSONDecoder().decode(Owner.self,from:data) {
                    guard owner.ownerPID>1,kill(owner.ownerPID,0) != 0,errno==ESRCH else {continue}
                    if owner.supervisorPID>1 {
                        guard kill(owner.supervisorPID,0) != 0,errno==ESRCH else {continue}
                    } else if owner.supervisorPID != 0 {continue}
                    try? FileManager.default.removeItem(at:receipt)
                    try? FileManager.default.removeItem(at:directory.appendingPathComponent(token+".log"))
                } else {
                    var metadata=stat()
                    if lstat(url.path,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==getuid(),Date().timeIntervalSince1970-Double(metadata.st_mtimespec.tv_sec)>60 {
                        try? FileManager.default.removeItem(at:url)
                    }
                }
            }
            try trimFailures(directory,leaving:32)
        }
    }
    static func saveFailure(_ directory:URL,token:String,text:String) throws {
        guard UUID(uuidString:token) != nil else {throw BridgeError.message("Invalid audio diagnostic identity")}
        try locked(directory) {
            try trimFailures(directory,leaving:31)
            let destination=directory.appendingPathComponent(token+".failed.log")
            try Data(text.utf8.prefix(65_536)).write(to:destination,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
        }
    }
    private static func trimFailures(_ directory:URL,leaving:Int) throws {
        let failures=try entries(directory).filter {name in
            name.hasSuffix(".failed.log") && UUID(uuidString:String(name.dropLast(11))) != nil
        }.compactMap {name ->(URL,Int)? in
            let url=directory.appendingPathComponent(name);var metadata=stat()
            guard lstat(url.path,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==getuid() else {return nil}
            return (url,Int(metadata.st_mtimespec.tv_sec))
        }.sorted {$0.1 > $1.1}
        for (url,_) in failures.dropFirst(leaving) {try FileManager.default.removeItem(at:url)}
    }
    private static func locked(_ directory:URL,_ operation:() throws ->Void) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=open(directory.appendingPathComponent(".artifacts.lock").path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd>=0 else {throw BridgeError.message("Cannot open audio diagnostic lock")}
        defer {close(fd)}
        var metadata=stat()
        guard fstat(fd,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==getuid(),metadata.st_mode&0o777==0o600 else {throw BridgeError.message("Invalid audio diagnostic lock")}
        let deadline=ProcessInfo.processInfo.systemUptime+0.1
        while flock(fd,LOCK_EX|LOCK_NB) != 0 {
            guard errno==EWOULDBLOCK,ProcessInfo.processInfo.systemUptime<deadline else {throw BridgeError.message("Audio diagnostics are busy. Retry shortly.")}
            usleep(1_000)
        }
        try operation()
    }
    private static func entries(_ directory:URL) throws ->[String] {
        guard let stream=opendir(directory.path) else {throw BridgeError.message("Cannot inspect audio diagnostics")}
        defer {closedir(stream)}
        var result=[String]()
        while let item=readdir(stream) {
            let name=withUnsafePointer(to:&item.pointee.d_name) {ptr in ptr.withMemoryRebound(to:CChar.self,capacity:Int(item.pointee.d_namlen)+1) {String(cString:$0)}}
            if name=="." || name==".." {continue}
            result.append(name)
            guard result.count<=512 else {throw BridgeError.message("Audio ownership directory reached its safety limit. Collect diagnostics and reinstall or contact support; choose Phone meanwhile.")}
        }
        return result
    }
    private static func read(_ url:URL,_ limit:Int) throws ->Data {
        let fd=open(url.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
        guard fd>=0 else {throw BridgeError.message("Missing audio receipt")}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer {try? file.close()}
        var metadata=stat()
        guard fstat(fd,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==getuid(),metadata.st_size<=limit else {throw BridgeError.message("Invalid audio receipt")}
        let bytes=try file.read(upToCount:limit+1) ?? Data()
        guard bytes.count<=limit else {throw BridgeError.message("Audio receipt changed during read")}
        return bytes
    }
}
