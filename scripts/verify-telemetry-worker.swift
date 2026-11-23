import Foundation
@testable import AnonymousUsage

// The real Swift transport talks directly to local workerd/D1. No identity,
// URL override, fake transport, or HTTP library adds fields to this request.
guard CommandLine.arguments.count == 3, let port = UInt16(CommandLine.arguments[2]) else { fatalError("state and loopback port required") }
let meter = UsageMeter(directory: URL(fileURLWithPath: CommandLine.arguments[1]), transport: LoopbackUsageTransport(port: port), consentScope: "worker-fixture", canChangeConsent: true)
meter.setConsent(true); meter.settle()
meter.setForeground(true); meter.recordNativeSession(); meter.sendPending(); meter.settle()
Thread.sleep(forTimeInterval: 3.5)
meter.sendPending(); meter.settle()
Thread.sleep(forTimeInterval: 0.3)
meter.setConsent(false); meter.settle()
print("Swift transport completed one capped contribution; repeated attempt was budgeted")
