import XCTest
import Darwin
@testable import DroidBridgeCore

final class ScrcpyPortLeaseTests:XCTestCase {
    private func isUnlocked(_ port:UInt16,in directory:URL)->Bool {
        let fd=open(directory.appendingPathComponent("\(port).lock").path,O_RDWR|O_CLOEXEC|O_NOFOLLOW)
        guard fd>=0 else{return false};defer{close(fd)}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else{return false}
        flock(fd,LOCK_UN);return true
    }
    func testInheritedLeaseSurvivesHostReferenceReleaseWithoutListeningSocket() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("PortLease-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var first:ScrcpyPortLease?=try ScrcpyPortLease.acquire(directory:root)
        let port=first!.port,child=Process()
        child.executableURL=URL(fileURLWithPath:"/bin/sleep");child.arguments=["0.5"];child.standardInput=first!.inheritedInput
        try child.run();first=nil
        XCTAssertFalse(isUnlocked(port,in:root),"The child's inherited open-file description must retain the exact lock")
        let peer=try ScrcpyPortLease.acquire(directory:root)
        XCTAssertNotEqual(peer.port,port,"Inherited child reference must pin lease even before socket bind")
        let deadline=Date().addingTimeInterval(4)
        while child.isRunning && Date()<deadline {try await Task.sleep(for:.milliseconds(20))}
        XCTAssertFalse(child.isRunning)
        XCTAssertTrue(isUnlocked(port,in:root),"The exact lease must become reusable when its final inherited owner exits")
        let successor=try ScrcpyPortLease.acquire(directory:root)
        XCTAssertNotEqual(successor.port,peer.port)
        // A real app can bind the old TCP port while this test waits for its
        // child. Releasing the file lease does not authorize replacing it.
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
        XCTAssertTrue(isUnlocked(initial,in:root))
        let successor=try ScrcpyPortLease.acquire(directory:root)
        XCTAssertNotEqual(successor.port,second.port)
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
