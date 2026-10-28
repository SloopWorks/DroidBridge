import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import DroidBridgeCore
import DroidBridgeStreaming

/// Real Android17-emulator smoke. Does not claim physical Pixel/ChatGPT coverage.
@main struct API37NativeVerification {
    @MainActor static func main() async throws {
        let tools = Toolchain()
        let serial = ProcessInfo.processInfo.environment["DROIDBRIDGE_TEST_SERIAL"] ?? "emulator-5582"
        let device = AndroidDevice(serial:serial,model:"Android17 QA emulator")
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("verification/launcher-fix/qa/api37")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let api = try await ProcessRunner.run(tools.adb,arguments:["-s",serial,"shell","getprop","ro.build.version.sdk"])
        guard api.output.trimmingCharacters(in:.whitespacesAndNewlines) == "37" else { throw BridgeError.message("Requires API37 test emulator") }
        let session = BridgeSession(descriptor:SessionDescriptor(device:device,application:AndroidApplication(packageName:"com.android.settings",name:"API37 Settings"),configuration:SessionConfiguration(backend:.native)),toolchain:tools)
        var latest:CGImage?
        session.onFrame = { latest = $0 }
        session.onState = { state,error in print("API37 Settings \(state.rawValue): \(error ?? "")") }
        do {
            try await session.start()
            for _ in 0..<80 { if session.metrics.frames > 10 { break }; try await Task.sleep(nanoseconds:100_000_000) }
            guard session.state == .running, session.metrics.frames > 10, latest != nil else { throw BridgeError.message("No actual live native Settings video") }
            session.sendInput(.scroll(x:360,y:540,width:720,height:1080,horizontal:0,vertical:1))
            session.resize(width:896,height:640)
            for _ in 0..<100 { if latest?.width == 896 && latest?.height == 640 { break }; try await Task.sleep(nanoseconds:100_000_000) }
            // Android Settings recreates on geometry changes; capture settled
            // content rather than the first compositor transition at new size.
            try await Task.sleep(nanoseconds:1_500_000_000)
            guard session.state == .running else { throw BridgeError.message("Session failed after resize") }
            guard let image = latest, image.width == 896, image.height == 640 else { throw BridgeError.message("Actual stream resize not observed") }
            guard let png = CGImageDestinationCreateWithURL(output.appendingPathComponent("settings-resized.png") as CFURL,UTType.png.identifier as CFString,1,nil) else { throw BridgeError.message("Cannot save actual frame") }
            CGImageDestinationAddImage(png,image,nil); guard CGImageDestinationFinalize(png) else { throw BridgeError.message("Cannot finalize frame") }
            let json:[String:Any] = ["serial":serial,"api":37,"package":"com.android.settings","decoded_frames":session.metrics.frames,"width":image.width,"height":image.height,"input_note":"Sent native scroll control; Settings receipt not independently asserted", "physical_pixel":false,"chatgpt_reproduction":false]
            try JSONSerialization.data(withJSONObject:json,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("results.json"))
            await session.stopAndWait()
            for source in [session.logURL,session.logURL.appendingPathExtension("jsonl")] { if FileManager.default.fileExists(atPath:source.path) { try FileManager.default.copyItem(at:source,to:output.appendingPathComponent(source.lastPathComponent)) } }
            print("PASS: API37 Settings actual decoded live frames and 896x640 stream resize; stopAndWait completed")
        } catch { await session.stopAndWait(); throw error }
    }
}
