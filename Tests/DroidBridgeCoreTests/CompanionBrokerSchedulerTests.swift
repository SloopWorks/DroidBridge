import XCTest
@testable import DroidBridgeCore
final class CompanionBrokerSchedulerTests:XCTestCase {
    func testCancelledQueuedControlAndBulkReturnAcquiredSlots() async throws {
        let scheduler=BrokerScheduler()
        try await scheduler.acquire(bulk:false)
        let control=Task {try await scheduler.acquire(bulk:false)}
        try await Task.sleep(nanoseconds:20_000_000);control.cancel();await scheduler.release(bulk:false)
        do {try await control.value;XCTFail("Cancelled control admitted")} catch {XCTAssertTrue(error is CancellationError)}
        try await scheduler.acquire(bulk:false);await scheduler.release(bulk:false)
        try await scheduler.acquire(bulk:true,group:"phone",limit:1)
        let bulk=Task {try await scheduler.acquire(bulk:true,group:"phone",limit:1)}
        try await Task.sleep(nanoseconds:20_000_000);bulk.cancel();await scheduler.release(bulk:true,group:"phone")
        do {try await bulk.value;XCTFail("Cancelled asset admitted")} catch {XCTAssertTrue(error is CancellationError)}
        try await scheduler.acquire(bulk:true,group:"phone",limit:1);await scheduler.release(bulk:true,group:"phone")
    }
    func testImmediateCancellationNeverConsumesSlot() async throws {
        let scheduler=BrokerScheduler()
        for isBulk in [false,true] {
            let operation=Task {while !Task.isCancelled {await Task.yield()};try await scheduler.acquire(bulk:isBulk)}
            operation.cancel()
            do {try await operation.value;XCTFail("Immediate cancellation admitted")} catch {XCTAssertTrue(error is CancellationError)}
            try await scheduler.acquire(bulk:isBulk);await scheduler.release(bulk:isBulk)
        }
    }
    func testBatteryAssetLimitDoesNotBlockAnotherPhone() async throws {
        let scheduler=BrokerScheduler()
        try await scheduler.acquire(bulk:true,group:"battery",limit:1)
        let waiting=Task {try await scheduler.acquire(bulk:true,group:"battery",limit:1)}
        try await Task.sleep(nanoseconds:20_000_000)
        try await scheduler.acquire(bulk:true,group:"other",limit:2)
        await scheduler.release(bulk:true,group:"other")
        waiting.cancel();await scheduler.release(bulk:true,group:"battery")
        do {try await waiting.value;XCTFail("Cancelled battery waiter admitted")} catch {}
        try await scheduler.acquire(bulk:true,group:"battery",limit:1);await scheduler.release(bulk:true,group:"battery")
    }
    func testFourGlobalControlLanesPreserveFIFOAmongEligibleWaiters() async throws {
        let scheduler=BrokerScheduler(),order=SchedulerOrder()
        for group in ["a","b","c","d"] {try await scheduler.acquire(bulk:false,group:group)}
        let a=Task {try await scheduler.acquire(bulk:false,group:"a");await order.append("a");await scheduler.release(bulk:false,group:"a")}
        try await Task.sleep(nanoseconds:10_000_000)
        let e=Task {try await scheduler.acquire(bulk:false,group:"e");await order.append("e");await scheduler.release(bulk:false,group:"e")}
        try await Task.sleep(nanoseconds:10_000_000)
        await scheduler.release(bulk:false,group:"b")
        try await e.value
        // a was queued first but still owns its per-device lane; unrelated e
        // must run on b's free slot without waiting for a's device.
        let first=await order.values;XCTAssertEqual(first,["e"])
        await scheduler.release(bulk:false,group:"a");try await a.value
        for group in ["c","d"] {await scheduler.release(bulk:false,group:group)}
        let final=await order.values;XCTAssertEqual(final,["e","a"])
    }
    func testControlQueueBoundAndCancelledWaitersLeaveNoGroupOwnership() async throws {
        let scheduler=BrokerScheduler()
        try await scheduler.acquire(bulk:false,group:"phone")
        var queued:[Task<Void,Error>]=[]
        for _ in 0..<64 {queued.append(Task{try await scheduler.acquire(bulk:false,group:"phone")})}
        for _ in 0..<500 {if await scheduler.waitingCount==64 {break};try await Task.sleep(nanoseconds:1_000_000)}
        let depth=await scheduler.waitingCount;XCTAssertEqual(depth,64)
        do {try await scheduler.acquire(bulk:false,group:"other");XCTFail("65th queue slot admitted")}catch{XCTAssertEqual((error as? CompanionBoundaryError)?.code,"broker_busy")}
        queued.forEach{$0.cancel()}
        for task in queued {do{try await task.value;XCTFail("Cancelled waiter resumed success")}catch{XCTAssertTrue(error is CancellationError)}}
        let drained=await scheduler.waitingCount;XCTAssertEqual(drained,0)
        await scheduler.release(bulk:false,group:"phone")
        try await scheduler.acquire(bulk:false,group:"other");await scheduler.release(bulk:false,group:"other")
        try await scheduler.acquire(bulk:false,group:"phone");await scheduler.release(bulk:false,group:"phone")
    }
}

private actor SchedulerOrder {var values:[String]=[];func append(_ value:String){values.append(value)}}
