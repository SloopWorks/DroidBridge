import XCTest
import Darwin
@testable import DroidBridgeCore

final class ScrcpyStartupLeaseTests:XCTestCase {
    var directory:URL!
    override func setUpWithError() throws {directory=FileManager.default.temporaryDirectory.appendingPathComponent("ScrcpyStartup-"+UUID().uuidString)}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:directory)}
    func testSameDeviceExcludesAndReleaseAdmitsNextStartup() async throws {
        var first:ScrcpyStartupLease?=try await ScrcpyStartupLease.acquire(serial:"device-a",directory:directory)
        do {_=try await ScrcpyStartupLease.acquire(serial:"device-a",directory:directory,timeout:0.08);XCTFail("Same device must wait")} catch {}
        withExtendedLifetime(first) {};first=nil
        let next=try await ScrcpyStartupLease.acquire(serial:"device-a",directory:directory,timeout:0.08)
        withExtendedLifetime(next) {}
    }
    func testDifferentDevicesDoNotBlockAndCancellationReleasesWaiter() async throws {
        let first=try await ScrcpyStartupLease.acquire(serial:"device-a",directory:directory)
        let second=try await ScrcpyStartupLease.acquire(serial:"device-b",directory:directory,timeout:0.08)
        let waiter=Task {try await ScrcpyStartupLease.acquire(serial:"device-a",directory:directory)}
        try await Task.sleep(for:.milliseconds(30));waiter.cancel()
        let start=ProcessInfo.processInfo.systemUptime
        do {_=try await waiter.value;XCTFail("Cancelled startup cannot acquire")} catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,0.5)
        withExtendedLifetime((first,second)) {}
    }
    func testSymlinkRefusedAndLockPermissionsArePrivate() async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let target=directory.appendingPathComponent("target");try Data("untouched".utf8).write(to:target)
        let lock=directory.appendingPathComponent(ScrcpyStartupLease.filename(serial:"device-a"))
        try FileManager.default.createSymbolicLink(at:lock,withDestinationURL:target)
        do {_=try await ScrcpyStartupLease.acquire(serial:"device-a",directory:directory);XCTFail("Symlink must refuse")} catch {}
        XCTAssertEqual(try String(contentsOf:target),"untouched")
        let lease=try await ScrcpyStartupLease.acquire(serial:"device-b",directory:directory)
        let path=directory.appendingPathComponent(ScrcpyStartupLease.filename(serial:"device-b")).path
        let metadata=try FileManager.default.attributesOfItem(atPath:path)
        XCTAssertEqual((metadata[.posixPermissions] as? NSNumber)?.intValue,0o600)
        withExtendedLifetime(lease) {}
    }
    func testActualChildCannotAcquireHeldDeviceAndDoesNotPinGateAfterExec() async throws {
        var lease:ScrcpyStartupLease?=try await ScrcpyStartupLease.acquire(serial:"device-a",directory:directory)
        let path=directory.appendingPathComponent(ScrcpyStartupLease.filename(serial:"device-a")).path
        let probe="import fcntl,sys\nf=open(sys.argv[1],'r+')\ntry:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);print('acquired')\nexcept BlockingIOError: print('busy')"
        let held=try await ProcessRunner.run("/usr/bin/python3",arguments:["-c",probe,path],timeout:3)
        XCTAssertEqual(held.output.trimmingCharacters(in:.whitespacesAndNewlines),"busy")
        // A real client may outlive readiness. An ordinary exec must not keep
        // the startup gate alive when the caller releases its own reference.
        let child=Task {try await ProcessRunner.run("/bin/sleep",arguments:["0.3"],timeout:2)}
        try await Task.sleep(for:.milliseconds(50))
        withExtendedLifetime(lease) {};lease=nil
        let next=try await ScrcpyStartupLease.acquire(serial:"device-a",directory:directory,timeout:0.08)
        withExtendedLifetime(next) {};_=try await child.value
    }

}
