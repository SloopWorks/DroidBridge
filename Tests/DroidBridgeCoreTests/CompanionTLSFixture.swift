import Foundation
import XCTest
import Darwin
@testable import DroidBridgeCore

/// Real loopback TLS endpoint with a fixture-only EC P256 key. The Python
/// standard library owns the server key; no test keys enter macOS Keychain.
final class CompanionTLSFixture: @unchecked Sendable {
    let url: URL
    let serverPin: String
    private let process: Process
    private let directory: URL
    private let lock = NSLock()
    private var stopped = false
    var request: String { (try? String(contentsOf: directory.appendingPathComponent("request.bin"), encoding: .utf8)) ?? "" }
    init(delay: TimeInterval = 0, handshakeDelay: TimeInterval = 0, portPublicationDelay: TimeInterval = 0, certificateIP: String = "127.0.0.1", response: @escaping @Sendable (String) -> Data) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("companion-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func openssl(_ arguments: [String]) throws {
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); child.arguments = arguments
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit()
            guard child.terminationStatus == 0 else { throw NSError(domain: "TLSFixture", code: Int(child.terminationStatus)) }
        }
        let key = directory.appendingPathComponent("key.pem"), cert = directory.appendingPathComponent("cert.pem"), der = directory.appendingPathComponent("cert.der")
        let configuration = directory.appendingPathComponent("certificate.cnf")
        try Data("[req]\ndistinguished_name=dn\nx509_extensions=server\nprompt=no\n[dn]\nCN=DroidBridge Owned TLS Fixture\n[server]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:\(certificateIP)\n".utf8).write(to: configuration)
        try openssl(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-sha256", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "1", "-config", configuration.path])
        try openssl(["x509", "-in", cert.path, "-outform", "DER", "-out", der.path])
        serverPin = CompanionClient.sha256(try Data(contentsOf: der))
        let source = #"""
        import pathlib,socket,ssl,sys,time
        root=pathlib.Path(sys.argv[1])
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version=ssl.TLSVersion.TLSv1_2
        context.set_ecdh_curve('prime256v1')
        context.load_cert_chain(str(root/'cert.pem'),str(root/'key.pem'))
        server=socket.socket();server.bind(('127.0.0.1',0));server.listen(1);server.settimeout(5)
        if float(sys.argv[3]) > 0:
            # Deterministic reproduction of the former exists-before-write race.
            (root/'port').touch(); time.sleep(float(sys.argv[3]))
        (root/'port.tmp').write_text(str(server.getsockname()[1]))
        (root/'port.tmp').replace(root/'port')
        try:
            client,_=server.accept();client.settimeout(5)
            time.sleep(float(sys.argv[2]))
            with context.wrap_socket(client,server_side=True) as stream:
                data=b''
                while len(data)<278528:
                    block=stream.recv(16384)
                    if not block: break
                    data+=block
                    if b'\r\n\r\n' in data:
                        headers,body=data.split(b'\r\n\r\n',1)
                        length=next((int(line.split(b':',1)[1]) for line in headers.split(b'\r\n') if line.lower().startswith(b'content-length:')),0)
                        if len(body)>=length: break
                if data:
                    (root/'request.bin').write_bytes(data)
                    deadline=time.monotonic()+5
                    while not (root/'response.bin').exists() and time.monotonic()<deadline: time.sleep(.002)
                    if (root/'response.bin').exists(): stream.sendall((root/'response.bin').read_bytes())
        except (ssl.SSLError,OSError,ValueError) as exc: (root/'error.txt').write_text(repr(exc))
        finally: server.close()
        """#
        let script = directory.appendingPathComponent("server.py"); try Data(source.utf8).write(to: script)
        process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["python3", script.path, directory.path, String(handshakeDelay), String(portPublicationDelay)]
        let stderrURL = directory.appendingPathComponent("startup-error.txt")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = FileHandle.nullDevice; process.standardError = stderrHandle
        try process.run()
        let deadline = Date().addingTimeInterval(3), portFile = directory.appendingPathComponent("port")
        var readyPort: UInt16?
        while Date() < deadline {
            if let text = try? String(contentsOf: portFile), text.utf8.count <= 5,
               text.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt16(text), value > 0 {
                readyPort = value; break
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.003)
        }
        try? stderrHandle.close()
        guard let port = readyPort else {
            let pid = process.processIdentifier
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                Darwin.kill(pid, SIGKILL)
                let reapDeadline = Date().addingTimeInterval(0.5)
                while Date() < reapDeadline, waitpid(pid, &status, WNOHANG) == 0 { Thread.sleep(forTimeInterval: 0.005) }
            }
            let detail = String(decoding: ((try? Data(contentsOf: stderrURL)) ?? Data()).prefix(4096), as: UTF8.self)
            try? FileManager.default.removeItem(at: directory)
            throw NSError(domain: "TLSFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "TLS fixture did not publish a complete port within its startup bound. \(detail)"])
        }
        url = URL(string: "https://127.0.0.1:\(port)")!
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let requestFile = self.directory.appendingPathComponent("request.bin"), deadline = Date().addingTimeInterval(7)
            while !FileManager.default.fileExists(atPath: requestFile.path), self.process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.003) }
            guard let bytes = try? Data(contentsOf: requestFile) else { return }
            let headers = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
            let id = headers.first { $0.lowercased().hasPrefix("x-request-id:") }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? UUID().uuidString
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            try? response(id).write(to: self.directory.appendingPathComponent("response.bin"), options: .atomic)
        }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }; guard !stopped else { return }; stopped = true
        // Foundation waitUntilExit can wait for a run-loop notification already
        // consumed by the concurrent fixture reader. Reap only this owned child
        // with a finite deadline; never use a process-name kill.
        let pid = process.processIdentifier
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == 0 {
            Darwin.kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(0.5)
            while Date() < deadline, waitpid(pid, &status, WNOHANG) == 0 { Thread.sleep(forTimeInterval: 0.005) }
            if waitpid(pid, &status, WNOHANG) == 0 { Darwin.kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { close() }
    static func response(_ body: Data, mime: String = "application/json") -> Data {
        var bytes = Data("HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8); bytes.append(body); return bytes
    }
}
