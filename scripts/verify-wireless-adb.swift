import AppKit
import CoreImage
import DroidBridgeCore
import DroidBridgeStreaming
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Production pairing, persistence and native display code, with only a
/// private emulator cohort and its isolated ADB server supplied by the driver.
@main struct VerifyWirelessADB {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        Task { @MainActor in
            do {
                let args = CommandLine.arguments
                guard let scope = CompanionQAScope.current, scope.serial == "emulator-5580",
                      scope.root.path.hasPrefix("/private/tmp/droidbridge-wireless-qa-"),
                      let socket = ProcessInfo.processInfo.environment["ADB_SERVER_SOCKET"], socket.hasPrefix("tcp:"), socket != "tcp:5037",
                      args.count >= 2 else { throw BridgeError.message("Private dedicated emulator scope and isolated ADB server required") }
                let toolchain = Toolchain()
                switch args[1] {
                case "pair", "code":
                    let pairing: CompanionWirelessPairing
                    if args[1] == "code" {
                        let input = scope.root.appendingPathComponent("pair-code.json")
                        let data = try Data(contentsOf: input)
                        try FileManager.default.removeItem(at: input)
                        let values = try JSONDecoder().decode([String: String].self, from: data)
                        guard let address = values["endpoint"], let code = values["code"],
                              let result = try await CompanionWirelessADB.pairForDiscovery(adb: toolchain.adb, endpoint: CompanionWirelessEndpoint(address), code: code) else {
                            throw BridgeError.message("Android code pairing did not return an authenticated receipt")
                        }
                        pairing = result
                    } else {
                    let invitation = CompanionWirelessQRInvitation()
                    guard let qr = CompanionWirelessSetup.pairingImage(invitation) else { throw BridgeError.message("No invitation image") }
                    // Temporary test camera input only. Never log or retain the
                    // QR image or its payload in the evidence directory.
                    let url = scope.root.appendingPathComponent("camera.png")
                    // Match the API 35 AVD's reported 1280x960 Camera1 preview.
                    // Settings scans the first square of the landscape frame.
                    let image = CIImage(cgImage: qr).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
                    let margin = (960 - image.extent.width) / 2
                    let bounds = CGRect(x: 0, y: 0, width: 1280, height: 960)
                    let backdrop = CIImage(color: .white).cropped(to: bounds)
                    let camera = image.transformed(by: CGAffineTransform(translationX: margin, y: margin)).composited(over: backdrop)
                    guard let cameraFrame = CIContext().createCGImage(camera, from: bounds) else {
                        throw BridgeError.message("No emulator camera frame")
                    }
                    try write(cameraFrame, to: url)
                    let instance = invitation.payload.split(separator: ";").first { $0.hasPrefix("S:") }!.dropFirst(2)
                    try Data(instance.utf8).write(to: scope.root.appendingPathComponent("camera-ready"), options: .atomic)
                    pairing = try await CompanionWirelessADB.pair(adb: toolchain.adb, invitation: invitation)
                    }
                    try Data(pairing.serviceInstance.utf8).write(to: scope.root.appendingPathComponent("paired-service"), options: .atomic)
                    let connection = try await CompanionWirelessReconnect.shared.connectNow(adb: toolchain.adb, pairing: pairing)
                    try Data(connection.serial.utf8).write(to: scope.root.appendingPathComponent("first-serial"), options: .atomic)
                    print("PASS: Android \(args[1] == "code" ? "code" : "QR") pairing and validated TLS ADB transport")
                case "recover":
                    let previousSerial = try String(contentsOf: scope.root.appendingPathComponent("first-serial"), encoding: .utf8)
                    let saved = try await CompanionWirelessReconnect.shared.profiles()
                    guard saved.count == 1, let profile = saved.first, profile.lastVerifiedSerial == previousSerial else {
                        throw BridgeError.message("Fresh process could not load the saved phone")
                    }
                    var automatic: CompanionWirelessConnection?
                    let deadline = ProcessInfo.processInfo.systemUptime + 32
                    while automatic == nil, ProcessInfo.processInfo.systemUptime < deadline {
                        let list = try await AndroidDiscovery(toolchain: toolchain).devices()
                        automatic = await CompanionWirelessReconnect.shared.reconnectIfDue(adb: toolchain.adb, devices: list)
                        if automatic == nil { try await Task.sleep(for: .seconds(4)) }
                    }
                    guard let connection = automatic else {
                        do { _ = try await CompanionWirelessReconnect.shared.connectNow(adb: toolchain.adb, serviceInstance: profile.serviceInstance) }
                        catch { throw BridgeError.message("Saved phone automatic reconnect did not succeed. Explicit retry: \(error.localizedDescription)") }
                        throw BridgeError.message("Only explicit retry connected the saved phone")
                    }
                    guard connection.serial != previousSerial else { throw BridgeError.message("Saved phone reused the old endpoint") }
                    let profiles = try await CompanionWirelessReconnect.shared.profiles()
                    guard profiles.count == 1, profiles[0].lastVerifiedSerial == connection.serial else { throw BridgeError.message("Verified endpoint was not recorded") }
                    try Data(connection.serial.utf8).write(to: scope.root.appendingPathComponent("recovered-serial"), options: .atomic)
                    try await video(toolchain, serial: connection.serial)
                default: throw BridgeError.message("Expected pair or recover")
                }
                fflush(stdout); exit(0)
            } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func video(_ tools: Toolchain, serial: String) async throws {
        let descriptor = SessionDescriptor(device: AndroidDevice(serial: serial, model: "Dedicated wireless AVD"),
            application: AndroidApplication(packageName: "dev.droidbridge.testapp7", name: "Wireless ADB Video Probe"),
            configuration: SessionConfiguration(backend: .native))
        let session = BridgeSession(descriptor: descriptor, toolchain: tools)
        let host = NativeWindowController(session: session)
        host.showWindow(nil)
        do {
            try await session.start()
            let deadline = ProcessInfo.processInfo.systemUptime + 14
            var displayed: CGImage?
            while session.state == .running, ProcessInfo.processInfo.systemUptime < deadline {
                if session.metrics.frames >= 20, let frame = host.video.frameImage,
                   await Task.detached(priority: .utility, operation: { containsProbeControls(frame) }).value {
                    displayed = frame; break
                }
                try await Task.sleep(for: .milliseconds(350))
            }
            guard session.state == .running, let frame = displayed else { throw BridgeError.message("Native view did not show the deterministic app controls over wireless ADB") }
            let destination = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DROIDBRIDGE_WIRELESS_EVIDENCE"]!).appendingPathComponent("wireless-decoded-frame.png")
            try write(frame, to: destination)
            print("PASS: saved phone rediscovered at a different endpoint after a fresh process; \(session.metrics.frames) decoded native frames at \(frame.width)x\(frame.height), with the Android probe controls visible")
            await session.stopAndWait()
            host.close()
        } catch {
            await session.stopAndWait(); host.close(); throw error
        }
    }

    static func containsProbeControls(_ image: CGImage) -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return false }
        return request.results?.contains { $0.topCandidates(1).first?.string.uppercased().contains("INCREMENT COUNTER") == true } ?? false
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw BridgeError.message("Unable to create test image") }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw BridgeError.message("Unable to write test image") }
    }
}
