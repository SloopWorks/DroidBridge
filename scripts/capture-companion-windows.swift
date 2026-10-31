/// Passive WindowServer evidence, excluding every foreign window. No event
/// injection, permission prompt, screen text parsing, or image composition.
import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

@main struct CaptureCompanionWindows {
    static func main() async throws {
        let companionOnly = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--companion"
        guard CommandLine.arguments.count == 3 || companionOnly,
              CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: "Existing screen-capture authorization and exact owned PID cohort required", code: 1)
        }
        let pids = Set(CommandLine.arguments[1].split(separator: ",").compactMap { Int32($0) })
        guard !pids.isEmpty, pids.count <= 3, pids.allSatisfy({ $0 > 1 }) else { throw NSError(domain: "Invalid PID cohort", code: 2) }
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw NSError(domain: "Fresh evidence directory required", code: 3) }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let expected: Set<String> = companionOnly ? ["DroidBridge Companion"] : ["Input Alpha", "Input Beta"]
        let windows = content.windows.filter { pids.contains($0.owningApplication?.processID ?? 0) && expected.contains($0.title ?? "") && $0.windowLayer == 0 }
        guard windows.count == expected.count, Set(windows.compactMap(\.title)) == expected else { throw NSError(domain: "Exact expected owned windows required", code: 4) }
        let bounds = windows.reduce(CGRect.null) { $0.union($1.frame) }
        guard let display = content.displays.first(where: { $0.frame.contains(bounds) }), bounds.width <= 4096, bounds.height <= 4096 else { throw NSError(domain: "Both windows must fit one bounded display", code: 5) }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: bounds.minX - display.frame.minX, y: bounds.minY - display.frame.minY, width: bounds.width, height: bounds.height)
        configuration.width = Int(bounds.width * 2); configuration.height = Int(bounds.height * 2); configuration.showsCursor = false
        let filter = SCContentFilter(display: display, including: windows)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 16_777_216 else { throw NSError(domain: "Bounded PNG required", code: 6) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try png.write(to: output.appendingPathComponent(companionOnly ? "companion-window.png" : "two-native-windows.png"))
        let facts: [String: Any] = ["scope": "Actual WindowServer ScreenCaptureKit capture of only exact owned windows; original desktop positions preserved; all foreign windows excluded", "pixels": [image.width, image.height], "windows": windows.map { ["pid": $0.owningApplication!.processID, "window_id": $0.windowID, "title": $0.title!, "frame": ["x": $0.frame.minX, "y": $0.frame.minY, "width": $0.frame.width, "height": $0.frame.height]] }]
        try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("capture.json"))
        print("Captured \(windows.count) exact owned WindowServer windows; no foreign content included.")
    }
}
