import Foundation

/// Separate physical devices cannot monopolize each other's short control lane.
/// FIFO among eligible requests, four global controls, one per installation,
/// two global assets and the profile's per-device asset ceiling. No unbounded
/// producer tasks: at most 64 requests can wait across both queues.
actor BrokerScheduler {
    private struct Waiter {let id:UUID;let group:String;let limit:Int;let continuation:CheckedContinuation<Bool,Never>}
    private var controls=0,bulk=0
    private var controlGroups=Set<String>()
    private var bulkGroups:[String:Int]=[:]
    private var controlWaiters:[Waiter]=[],bulkWaiters:[Waiter]=[]
    func acquire(bulk isBulk:Bool,group:String="default",limit:Int=2) async throws {
        try Task.checkCancellation()
        guard controlWaiters.count+bulkWaiters.count<64 else {throw CompanionBoundaryError("broker_busy","Companion request queue is full.",retryable:true)}
        let id=UUID()
        let granted:Bool
        if isBulk {
            let limit=max(1,min(2,limit))
            if bulkWaiters.isEmpty && bulk<2 && controlWaiters.isEmpty && bulkGroups[group,default:0]<limit {bulk+=1;bulkGroups[group,default:0]+=1;return}
            granted=await withTaskCancellationHandler(operation:{
                await withCheckedContinuation {bulkWaiters.append(.init(id:id,group:group,limit:limit,continuation:$0));drain()}
            },onCancel:{Task{await self.cancel(id)}})
        } else {
            if controlWaiters.isEmpty && controls<4 && !controlGroups.contains(group) {controls+=1;controlGroups.insert(group);return}
            granted=await withTaskCancellationHandler(operation:{
                await withCheckedContinuation {controlWaiters.append(.init(id:id,group:group,limit:1,continuation:$0));drain()}
            },onCancel:{Task{await self.cancel(id)}})
        }
        guard granted else {throw CancellationError()}
        do {try Task.checkCancellation()} catch {release(bulk:isBulk,group:group);throw error}
    }
    func release(bulk isBulk:Bool,group:String="default") {
        if isBulk {bulk=max(0,bulk-1);let remaining=max(0,bulkGroups[group,default:0]-1);if remaining==0{bulkGroups.removeValue(forKey:group)}else{bulkGroups[group]=remaining}}
        else if controlGroups.remove(group) != nil {controls=max(0,controls-1)}
        drain()
    }
    #if DEBUG
    var waitingCount:Int {controlWaiters.count+bulkWaiters.count}
    #endif
    private func cancel(_ id:UUID) {
        if let index=controlWaiters.firstIndex(where:{$0.id==id}) {controlWaiters.remove(at:index).continuation.resume(returning:false)}
        else if let index=bulkWaiters.firstIndex(where:{$0.id==id}) {bulkWaiters.remove(at:index).continuation.resume(returning:false)}
        drain()
    }
    private func drain() {
        while controls<4,let index=controlWaiters.firstIndex(where:{!controlGroups.contains($0.group)}) {
            let waiter=controlWaiters.remove(at:index);controls+=1;controlGroups.insert(waiter.group);waiter.continuation.resume(returning:true)
        }
        // A blocked lane does not stall unrelated asset work, but every eligible
        // control gets its slot before another queued bulk request is resumed.
        let eligibleControl=controlWaiters.contains{!controlGroups.contains($0.group)}
        if !eligibleControl {
            while bulk<2,let index=bulkWaiters.firstIndex(where:{bulkGroups[$0.group,default:0]<$0.limit}) {
                let waiter=bulkWaiters.remove(at:index);bulk+=1;bulkGroups[waiter.group,default:0]+=1;waiter.continuation.resume(returning:true)
            }
        }
    }
}
