import XCTest
import Darwin
@testable import DroidBridgeCore

final class ScrcpyPortLeaseTests:XCTestCase {
    func testInheritedLeaseSurvivesHostReferenceReleaseWithoutListeningSocket() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("PortLease-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var first:ScrcpyPortLease?=try ScrcpyPortLease.acquire(directory:root)
        let port=first!.port,child=Process()
        child.executableURL=URL(fileURLWithPath:"/bin/sleep");child.arguments=["0.5"];child.standardInput=first!.inheritedInput
        try child.run();first=nil
        let peer=try ScrcpyPortLease.acquire(directory:root)
        XCTAssertNotEqual(peer.port,port,"Inherited child reference must pin lease even before socket bind")
        let deadline=Date().addingTimeInterval(4)
        while child.isRunning && Date()<deadline {try await Task.sleep(for:.milliseconds(20))}
        XCTAssertFalse(child.isRunning)
        let successor=try ScrcpyPortLease.acquire(directory:root)
        XCTAssertEqual(successor.port,port)
        withExtendedLifetime(peer) {};withExtendedLifetime(successor) {}
    }
    func testConcurrentLeasesAreDistinctAndReleaseIsReusable() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("PortLease-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var first:ScrcpyPortLease?=try ScrcpyPortLease.acquire(directory:root)
        let second=try ScrcpyPortLease.acquire(directory:root)
        let initial=first!.port
        XCTAssertNotEqual(initial,second.port)
        first=nil
        let successor=try ScrcpyPortLease.acquire(directory:root)
        XCTAssertEqual(successor.port,initial)
        withExtendedLifetime(second) {};withExtendedLifetime(successor) {}
    }
    func testForeignListenerIsSkippedWithoutReplacement() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("PortLease-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var first:ScrcpyPortLease?=try ScrcpyPortLease.acquire(directory:root)
        let port=first!.port,socketFD=socket(AF_INET,SOCK_STREAM,0)
        guard socketFD>=0 else {throw XCTSkip("No local socket available")}
        defer {close(socketFD)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET)
        address.sin_port=port.bigEndian;address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"))
        let result=withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(socketFD,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        XCTAssertEqual(result,0)
        first=nil
        let next=try ScrcpyPortLease.acquire(directory:root)
        XCTAssertNotEqual(next.port,port)
        withExtendedLifetime(next) {}
    }
}
