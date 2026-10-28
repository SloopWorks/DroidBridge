import Foundation
import DroidBridgeCore

@main struct VerifyManagedAvailability {
 static func snapshot(_ label:String) throws ->(Int,Int) {
  let records=try ManagedAppCatalog().records().filter{$0.deviceSerial=="emulator-5580"}
  let active=records.filter{$0.availability == .active && FileManager.default.fileExists(atPath:$0.activeBundleURL.path)}.count
  let hidden=records.filter{$0.availability == .inactive && FileManager.default.fileExists(atPath:$0.inactiveBundleURL.path)}.count
  print("SNAPSHOT \(label) accepted=\(records.count) active=\(active) hidden=\(hidden)")
  return (active,hidden)
 }
 static func run() throws {
  switch CommandLine.arguments.dropFirst().first ?? "status" {
   case "off": try DroidBridgePreferences.update{$0.bulkWrapperOnboardingEnabled=false};print("FLAG bulkEnabled=false");return
   case "on": try DroidBridgePreferences.update{$0.bulkWrapperOnboardingEnabled=true};print("FLAG bulkEnabled=true");return
   default: break
  }
  _=try snapshot("current")
 }
 static func main() {
  do {try run()}
  catch ManagedAppCatalogError.busy {fputs("BUSY: managed catalog is completing another finite operation\n",stderr);exit(2)}
  catch {fputs("ERROR: \(error)\n",stderr);exit(1)}
 }
}
