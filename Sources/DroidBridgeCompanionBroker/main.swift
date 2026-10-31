import Foundation
import Darwin
import DroidBridgeCore

if CommandLine.arguments.contains("--version") {
    print("DroidBridgeCompanionBroker protocol 1")
    exit(0)
}
do { _ = try CompanionQAScope.parse(arguments: CommandLine.arguments) }
catch { fputs("Invalid isolated companion QA scope.\n", stderr); exit(64) }
let generationLease: AvailabilityRuntimeLease?
do {
    generationLease = try CompanionBrokerInstaller.holdRunning(executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
} catch {
    fputs("Companion runtime lease is unavailable.\n", stderr)
    exit(78)
}
let service = CompanionBrokerService()
let listener = NSXPCListener(machServiceName: CompanionBrokerIPC.serviceName)
listener.delegate = service
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
termination.setEventHandler { Task { await service.shutdown(); exit(0) } }
termination.resume()
let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interruption.setEventHandler { Task { await service.shutdown(); exit(0) } }
interruption.resume()
listener.resume()
withExtendedLifetime(generationLease) { RunLoop.current.run() }
