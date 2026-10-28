import Foundation
import CoreGraphics

struct FrameDelivery {
    let image: CGImage
    let frames: Int
    let bytes: Int
}

/// A slow or temporarily blocked AppKit thread retains only the newest decoded
/// image. Counters include overwritten frames; scheduling captures the mailbox,
/// never a historical image. One delivery is pending or executing at a time.
final class FrameMailbox: @unchecked Sendable {
    typealias Scheduler = (@escaping @MainActor () -> Void) -> Void
    private let lock = NSLock()
    private let scheduler: Scheduler
    private let delivery: @MainActor (FrameDelivery) -> Void
    private var latest: CGImage?
    private var frames = 0
    private var bytes = 0
    private var scheduled = false
    private var closed = false

    init(scheduler: @escaping Scheduler = { action in Task { @MainActor in action() } }, delivery: @escaping @MainActor (FrameDelivery) -> Void) {
        self.scheduler = scheduler; self.delivery = delivery
    }
    func publish(_ image: CGImage, bytes packetBytes: Int) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        latest = image; frames += 1; bytes += packetBytes
        let needsSchedule = !scheduled
        scheduled = true; lock.unlock()
        if needsSchedule { scheduler { [self] in drain() } }
    }
    func cancel() {
        lock.lock(); closed = true; latest = nil; frames = 0; bytes = 0; lock.unlock()
    }
    @MainActor private func drain() {
        lock.lock()
        guard !closed, let image = latest else { scheduled = false; lock.unlock(); return }
        let value = FrameDelivery(image:image,frames:frames,bytes:bytes)
        latest = nil; frames = 0; bytes = 0; lock.unlock()
        delivery(value)
        lock.lock()
        let needsSchedule = !closed && latest != nil
        if !needsSchedule { scheduled = false }
        lock.unlock()
        if needsSchedule { scheduler { [self] in drain() } }
    }
}
