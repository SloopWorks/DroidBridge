import XCTest
@testable import DroidBridgeCore

final class DeviceAudioPreferencesTests:XCTestCase {
    private func temporary() throws ->URL {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("audio-preferences-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        return directory
    }
    func testConcurrentIndependentChoicesMergeAndKeepAcceptedPhone() async throws {
        let directory=try temporary();defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("audio-preferences.json")
        try DeviceAudioPreferences.setRoute(.phone,for:"phone-kept",url:url)
        async let first: [String:DeviceAudioRoute] = Task.detached {try DeviceAudioPreferences.setRoute(.mac,for:"device-first",url:url)}.value
        async let second: [String:DeviceAudioRoute] = Task.detached {try DeviceAudioPreferences.setRoute(.macAndPhone,for:"device-second",url:url)}.value
        _ = try await (first,second)
        XCTAssertEqual(try DeviceAudioPreferences.loadRoutes(url:url),["phone-kept":.phone,"device-first":.mac,"device-second":.macAndPhone])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? Int,0o600)
    }
    func testMissingStoreStartsEmptyAndMalformedStoreNeverFallsBackToGlobal() throws {
        let directory=try temporary();defer {try? FileManager.default.removeItem(at:directory)}
        let audio=directory.appendingPathComponent("audio-preferences.json")
        let global=directory.appendingPathComponent("preferences.json")
        try DroidBridgePreferences.update(url:global) {$0.deviceAudioRoutes["device-a"] = .mac}
        XCTAssertEqual(try DeviceAudioPreferences.loadRoutes(url:audio),[:])
        let invalid=Data("{\"deviceAudioRoutes\":{\"device-a\":\"unsupported-future-route\"}}".utf8)
        try invalid.write(to:audio)
        XCTAssertThrowsError(try DeviceAudioPreferences.loadRoutes(url:audio))
        XCTAssertThrowsError(try DeviceAudioPreferences.setRoute(.phone,for:"device-a",url:audio))
        XCTAssertEqual(try Data(contentsOf:audio),invalid)
        XCTAssertEqual(try DroidBridgePreferences.load(url:global).deviceAudioRoutes,["device-a":.mac])
    }
    func testInvalidSerialNeverCreatesOrChangesAudioStore() throws {
        let directory=try temporary();defer {try? FileManager.default.removeItem(at:directory)}
        let audio=directory.appendingPathComponent("audio-preferences.json")
        XCTAssertThrowsError(try DeviceAudioPreferences.setRoute(.phone,for:"bad serial",url:audio))
        XCTAssertFalse(FileManager.default.fileExists(atPath:audio.path))
        try DeviceAudioPreferences.setRoute(.phone,for:"accepted",url:audio)
        let accepted=try Data(contentsOf:audio)
        XCTAssertThrowsError(try DeviceAudioPreferences.setRoute(.mac,for:"bad serial",url:audio))
        XCTAssertEqual(try Data(contentsOf:audio),accepted)
    }
}
