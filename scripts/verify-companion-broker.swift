/// Test-only public broker IPC caller. Requires an explicit owned QA scope.
import Foundation
import DroidBridgeCore
@main struct Probe { static func main() async throws {
 _ = try CompanionQAScope.parse(arguments: CommandLine.arguments)
 guard CompanionQAScope.current != nil else { throw NSError(domain: "Explicit QA scope required", code: 1) }
 let input = try FileHandle.standardInput.read(upToCount: CompanionBrokerIPC.maximumBytes + 1) ?? Data()
 guard input.count <= CompanionBrokerIPC.maximumBytes else { throw NSError(domain: "Bounded QA request required", code: 3) }
 let request = try JSONDecoder().decode([String: CompanionJSON].self, from: input)
 guard let operation = request["operation"]?.string else { throw NSError(domain:"Missing operation",code:2) }
 let client = CompanionBrokerIPCClient()
 let reply = try await client.request(operation: operation, payload: request["payload"]?.object ?? [:])
 try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(reply))
 await client.invalidate()
} }
