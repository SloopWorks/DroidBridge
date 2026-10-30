import Foundation
import DroidBridgeCore
import DroidBridgeStreaming
@main struct Verify {
 @MainActor static func main() async {
  let session=BridgeSession(descriptor:SessionDescriptor(device:AndroidDevice(serial:"emulator-5580",model:"QA"),application:AndroidApplication(packageName:"dev.droidbridge.testapp",name:"Launch UX Probe"),configuration:SessionConfiguration(backend:.scrcpy)),toolchain:Toolchain())
  session.externalWindowFrame=CGRect(x:100,y:100,width:480,height:620)
  session.onExternalWindowFrame={print("GEOMETRY \($0)");fflush(stdout)}
  do {try await session.start();print("RUNNING",session.logURL.path);fflush(stdout);try await Task.sleep(for:.seconds(3));print("PID",session.externalApplicationPID as Any);await session.stopAndWait();print("PASS: real fallback texture gate and cleanup")} catch {await session.stopAndWait();print("FAIL:",error);exit(1)}
 }
}
