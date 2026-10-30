import XCTest
@testable import DroidBridgeStreaming

final class DeviceAudioReadinessTests:XCTestCase {
    private let marker="INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY"
    func testActualPinnedClientOSCWindowTitleBeforeOutputReady() {
        let actual="\u{1b}]0;scrcpy - Android SDK built for arm64\u{7}"+marker+"\n"
        XCTAssertTrue(DeviceAudioRouter.hasInitializedOutput(actual))
        XCTAssertTrue(DeviceAudioRouter.hasInitializedOutput("\u{1b}]0;window title\u{1b}\\"+marker+"\n"))
        XCTAssertTrue(DeviceAudioRouter.hasInitializedOutput(marker+"\n"))
        XCTAssertTrue(DeviceAudioRouter.hasInitializedOutput("\u{1b}[32m"+marker+"\u{1b}[0m\n"))
    }
    func testIncompleteOrPayloadMarkersNeverClaimReadiness() {
        for value in [marker, "\u{1b}]0;"+marker+"\n", "\u{1b}[31", "\u{1b}",
                      "\u{1b}]0;"+marker+"\u{7}\n", "\u{1b}]0;"+marker+"\u{1b}\\\n",
                      "[server] "+marker+"\n", "prefix "+marker+"\n",marker+" extra\n",
                      "DEBUG: Decoder 'audio': pcm_s16le\n"] {
            XCTAssertFalse(DeviceAudioRouter.hasInitializedOutput(value),String(reflecting:value))
        }
    }
    func testBoundedInputAndCompleteLineRequirement() {
        XCTAssertFalse(DeviceAudioRouter.hasInitializedOutput(String(repeating:"x",count:262_145)+"\n"+marker+"\n"))
        XCTAssertFalse(DeviceAudioRouter.hasInitializedOutput("\u{1b}["+marker+"\n"))
        XCTAssertTrue(DeviceAudioRouter.hasInitializedOutput("other diagnostics\n"+marker+"\r\nmore diagnostics\n"))
    }
}
