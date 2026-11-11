import Foundation
@testable import DroidBridgeCore

@main struct BonjourSmoke {
    static func publish(_ instance: String, _ type: String, _ port: UInt16, _ host: String) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        child.arguments = ["-P", instance, type, "local", String(port), host, "127.0.0.1"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        return child
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let nonce = String(UUID().uuidString.prefix(8)).lowercased()
        let guid = "adb-droidbridge-\(nonce)"
        let host = "droidbridge-\(nonce).local."
        let adb = root.appendingPathComponent("fixture-adb")
        let body = """
        #!/bin/sh
        case "$*" in
          'pair 127.0.0.1:39121')
            IFS= read -r secret || exit 1
            test "${#secret}" -eq 32 || exit 2
            case "$secret" in *[!0-9a-f]*) exit 3 ;; esac
            printf 'Enter pairing code: Successfully paired to 127.0.0.1:39121 [guid=\(guid)]\\n' ;;
          'connect 127.0.0.1:39122') printf 'connected to 127.0.0.1:39122\\n' ;;
          'devices -l') printf 'List of devices attached\\n127.0.0.1:39122 device transport_id:7\\n' ;;
          '-t 7 shell getprop persist.adb.wifi.guid') : ;;
          '-t 7 shell settings --user 0 get secure android_id') printf '11ab22bc33cd44de\\n' ;;
          *) exit 4 ;;
        esac
        """
        try Data(body.utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        let invitation = CompanionWirelessQRInvitation()
        let pairingAd = try publish(invitation.serviceInstance, "_adb-tls-pairing._tcp", 39121, host)
        defer { if pairingAd.isRunning { pairingAd.terminate() } }
        let pairing = try await CompanionWirelessADB.pair(adb: adb.path, invitation: invitation, discoveryTimeout: 8)
        precondition(pairing.serviceInstance == guid)
        print("PASS: native Bonjour resolved exact QR instance; mock ADB received QR secret through stdin")
        let connectAd = try publish(guid, "_adb-tls-connect._tcp", 39122, host)
        defer { if connectAd.isRunning { connectAd.terminate() } }
        let connection = try await CompanionWirelessADB.connectPaired(adb: adb.path, pairing: pairing, discoveryTimeout: 8)
        precondition(connection.serial == "127.0.0.1:39122")
        try CompanionWirelessADB.validateFingerprint(connection.fingerprint)
        print("PASS: native Bonjour resolved same-host TLS connect instance; exact mock transport verified with hidden shell GUID")
        let task = Task { try await CompanionWirelessBonjour.resolve(instance: "studio-\(UUID().uuidString)", kind: .pairing, timeout: 20) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancellation = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; fatalError("Expected cancellation") }
        catch is CancellationError {
            precondition(ProcessInfo.processInfo.systemUptime - cancellation < 0.75)
            print("PASS: cancellation released the native browse within the bounded interval")
        }
    }
}
