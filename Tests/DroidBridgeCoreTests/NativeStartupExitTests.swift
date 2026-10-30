import XCTest
import Foundation
import Darwin
import DroidBridgeCore
@testable import DroidBridgeStreaming

final class NativeStartupExitTests: XCTestCase {
    @MainActor func testCleanProcessExitBeforeFirstFramePreservesActionableFailure() async throws {
        // Own a loopback listener without sending the scrcpy handshake. This
        // keeps startup pending while the real supervisor observes child exit.
        let listener = socket(AF_INET,SOCK_STREAM,0)
        XCTAssertGreaterThanOrEqual(listener,0)
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to:&address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound,0); XCTAssertEqual(listen(listener,4),0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to:&address) { pointer in pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(listener,$0,&length) } },0)
        let port = UInt16(bigEndian:address.sin_port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-clean-exit-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let tool = directory.appendingPathComponent("fixture-tool")
        let script = """
        #!/bin/sh
        if [ "$4" = getprop ] && [ "$5" = ro.build.version.sdk ]; then printf '35\\n'; exit 0; fi
        if [ "$1" = --version ]; then printf 'scrcpy 5.0.1\\n'; exit 0; fi
        if [ "$3" = forward ] && [ "$4" = tcp:0 ]; then printf '\(port)\\n'; exit 0; fi
        if [ "$3" = shell ] && [ "$4" = cmd ]; then printf 'dev.droidbridge.testapp/.MainActivity\\n'; fi
        exit 0
        """
        try script.write(to:tool,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:tool.path)
        let session = BridgeSession(descriptor:SessionDescriptor(device:AndroidDevice(serial:"qa-owned-loopback",model:"No Android device"),application:AndroidApplication(packageName:"dev.droidbridge.testapp",name:"Fixture"),configuration:SessionConfiguration(backend:.native)),toolchain:Toolchain(adb:tool.path,scrcpy:tool.path,server:tool.path))
        do { try await session.start(); XCTFail("An exited server cannot start a native video session") }
        catch {
            XCTAssertFalse(error is CancellationError)
            XCTAssertTrue(error.localizedDescription.contains("before the first decoded video frame"),error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("exit status 0"),error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(session.logURL.path))
        }
        XCTAssertEqual(session.state,.failed)
        await session.stopAndWait()
    }
}
