import Foundation
import Darwin
import CoreGraphics

import DroidBridgeCore

/// A socket owns its descriptor for its entire lifetime. Shutdown interrupts
/// readers immediately; close waits for queue references to disappear, avoiding
/// descriptor reuse races between a closing session and a newly opened one.
final class SocketChannel: @unchecked Sendable {
    let fd: Int32
    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.message("Cannot create video socket") }
        _ = fcntl(fd,F_SETFD,FD_CLOEXEC)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result != 0 { Darwin.close(fd); throw BridgeError.message("Cannot connect Android video transport") }
    }
    deinit { Darwin.close(fd) }
    func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }
    func continuousReads() { var timeout = timeval(tv_sec: 0,tv_usec: 0); setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size)) }
    func read(_ size: Int) throws -> Data {
        guard size >= 0, size <= 16_777_216 else { throw BridgeError.message("Invalid video packet size") }
        var data = Data(count:size); var received = 0
        try data.withUnsafeMutableBytes { bytes in
            while received < size {
                let count = recv(fd,bytes.baseAddress!.advanced(by: received),size-received,0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BridgeError.message("Android video transport disconnected") }
                received += count
            }
        }; return data
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(fd,bytes.baseAddress!.advanced(by:sent),data.count-sent,0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BridgeError.message("Android input transport disconnected") }; sent += count
            }
        }
    }
}

final class NativeTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var video: SocketChannel?
    private var control: SocketChannel?
    private let inputQueue = DispatchQueue(label:"DroidBridge.input")
    var onFrame: ((CGImage,Int) -> Void)?
    var onSize: ((Int,Int) -> Void)?
    var onFailure: ((Error) -> Void)?
    func stop() { lock.lock(); stopped = true; video?.shutdown(); control?.shutdown(); lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func send(_ data: Data) {
        inputQueue.async { [self] in
            lock.lock(); let channel = stopped ? nil : control; lock.unlock()
            do { try channel?.write(data) } catch { if !isStopped { onFailure?(error) } }
        }
    }
    func start(port: UInt16, package: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            DispatchQueue.global(qos:.userInitiated).async { [self] in
                do {
                    var connected: SocketChannel?
                    for _ in 0..<40 {
                        if isStopped { throw CancellationError() }
                        do { let socket = try SocketChannel(port:port); let dummy = try socket.read(1); if dummy.first == 0 { connected = socket; break } } catch {}
                        Thread.sleep(forTimeInterval:0.15)
                    }
                    guard let video = connected else { throw BridgeError.message("scrcpy server did not open video socket; inspect session log") }
                    let control = try SocketChannel(port:port)
                    lock.lock()
                    if stopped { lock.unlock(); video.shutdown(); control.shutdown(); throw CancellationError() }
                    self.video = video; self.control = control; lock.unlock()
                    _ = try video.read(64)
                    guard try video.read(4).number(0,4) == 0x68323634 else { throw BridgeError.message("Expected pinned H.264 video codec") }
                    video.continuousReads(); control.continuousReads()
                    send(ScrcpyControl.startApp(package))
                    continuation.resume()
                    // Device messages are drained so clipboard notifications can never
                    // fill the control socket and stall Android input processing.
                    DispatchQueue.global(qos:.utility).async { [self,control] in
                        do { while !isStopped { _ = try control.read(1) } } catch {}
                    }
                    let decoder = H264Decoder()
                    var packetBytes = 0
                    decoder.output = { [weak self] frame in self?.onFrame?(frame,packetBytes) }
                    do {
                        while !isStopped {
                            let header = try video.read(12)
                            if header[0] & 0x80 != 0 {
                                let width = Int(header.number(4,4)); let height = Int(header.number(8,4))
                                guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw BridgeError.message("Invalid Android frame dimensions") }
                                onSize?(width,height); continue
                            }
                            let size = Int(header.number(8,4)); let packet = try video.read(size); packetBytes = size
                            try decoder.decode(packet,pts: header.number(0,8) & 0x1fff_ffff_ffff_ffff)
                        }
                    } catch { if !isStopped { onFailure?(error) } }
                    decoder.finish()
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
}
