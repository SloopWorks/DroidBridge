import XCTest
import Foundation
import Darwin
@testable import DroidBridgeCore
@testable import DroidBridgeStreaming

/// Failure-oriented process fixtures only; no emulator/audio-device claims.
final class DeviceAudioQATests: XCTestCase {
    private func temp() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("qa-audio-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    private func executable(_ url:URL,_ source:String) throws {
        try source.write(to:url,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:url.path)
    }
    @MainActor private func wait(_ description:String,seconds:Double=6,_ predicate:()->Bool) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+seconds
        while !predicate() && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(for:.milliseconds(20))}
        guard predicate() else {throw NSError(domain:"DeviceAudioQA",code:1,userInfo:[NSLocalizedDescriptionKey:"Timed out: "+description])}
    }
    private var supervisor:String {FileManager.default.currentDirectoryPath+"/.build/debug/DroidBridgeSupervisor"}
    private func count(_ url:URL)->Int {(try? String(contentsOf:url).split(separator:"\n").count) ?? 0}

    func testQAPreferenceCapacityUnknownRouteAndAtomicRefusal() throws {
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("preferences.json")
        let accepted=try DroidBridgePreferences.update(url:url) { value in
            value.bulkWrapperOnboardingEnabled=false;value.showAndroidSystemDecorations=false
            value.screenOffDeviceSerials=["test-primary"]
            for index in 0..<32 {value.deviceAudioRoutes["test-\(index)"] = .macAndPhone}
        }
        XCTAssertEqual(accepted.deviceAudioRoutes.count,32)
        let bytes=try Data(contentsOf:url)
        XCTAssertThrowsError(try DroidBridgePreferences.update(url:url) {$0.deviceAudioRoutes["test-33"] = .phone})
        XCTAssertEqual(try Data(contentsOf:url),bytes)
        var malformed=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        malformed["deviceAudioRoutes"]=["test-primary":"microphone"]
        XCTAssertThrowsError(try JSONDecoder().decode(DroidBridgePreferences.self,from:JSONSerialization.data(withJSONObject:malformed)))
        let restored=try DroidBridgePreferences.load(url:url)
        XCTAssertFalse(restored.bulkWrapperOnboardingEnabled);XCTAssertFalse(restored.showAndroidSystemDecorations)
        XCTAssertEqual(restored.screenOffDeviceSerials,["test-primary"])
    }

    @MainActor func testQAPhoneIntentDuringSDKProbeNeverSpawnsClient() async throws {
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client"),probe=dir.appendingPathComponent("probe"),launches=dir.appendingPathComponent("launches")
        try executable(adb,"#!/bin/sh\nif [ \"$4\" = getprop ]; then echo probe >> '\(probe.path)'; /bin/sleep 0.4; echo 35; fi\n")
        try executable(client,"#!/bin/sh\necho launched >> '\(launches.path)'\necho 'INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY'\nexec /bin/sleep 30\n")
        let router=DeviceAudioRouter(toolchain:Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path),directory:dir,supervisor:supervisor,outputAvailable:{true})
        addTeardownBlock { await router.shutdown() }
        router.reconcile(activeSerials:["qa-device"],connectedSerials:["qa-device"],routes:[:])
        try await wait("SDK probe entered") {self.count(probe)==1}
        router.reconcile(activeSerials:["qa-device"],connectedSerials:["qa-device"],routes:["qa-device":.phone])
        try await wait("Phone settles") {router.status(for:"qa-device").phase == .phone}
        XCTAssertEqual(count(launches),0,"Late preflight must not admit superseded Mac capture")
        await router.shutdown()
    }

    @MainActor func testQADisconnectDuringSDKProbeDrainsWithoutLateCapture() async throws {
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client"),probe=dir.appendingPathComponent("probe"),launches=dir.appendingPathComponent("launches")
        try executable(adb,"#!/bin/sh\nif [ \"$4\" = getprop ]; then echo probe >> '\(probe.path)'; /bin/sleep 0.4; echo 35; fi\n")
        try executable(client,"#!/bin/sh\necho launch >> '\(launches.path)'\nexec /bin/sleep 30\n")
        let router=DeviceAudioRouter(toolchain:Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path),directory:dir,supervisor:supervisor,outputAvailable:{true})
        addTeardownBlock { await router.shutdown() }
        router.reconcile(activeSerials:["qa-device"],connectedSerials:["qa-device"],routes:[:])
        try await wait("SDK probe entered") {self.count(probe)==1}
        router.reconcile(activeSerials:["qa-device"],connectedSerials:[],routes:[:])
        await router.shutdown()
        XCTAssertEqual(count(launches),0)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:dir.path).contains {$0.hasSuffix(".json") || $0.hasSuffix(".log")})
    }

    @MainActor func testQATwoSerialsHaveIndependentOwnershipAndPhoneRelease() async throws {
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client"),launches=dir.appendingPathComponent("launches")
        try executable(adb,"#!/bin/sh\nif [ \"$4\" = getprop ]; then echo 35; fi\n")
        try executable(client,"#!/bin/sh\necho \"$2\" >> '\(launches.path)'\necho 'INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY'\nexec /bin/sleep 30\n")
        let router=DeviceAudioRouter(toolchain:Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path),directory:dir,supervisor:supervisor,outputAvailable:{true})
        addTeardownBlock { await router.shutdown() }
        router.reconcile(activeSerials:["qa-first","qa-second"],connectedSerials:["qa-first","qa-second"],routes:[:])
        try await wait("both independent devices ready") {router.status(for:"qa-first").phase == .ready && router.status(for:"qa-second").phase == .ready}
        router.reconcile(activeSerials:["qa-first","qa-second"],connectedSerials:["qa-first","qa-second"],routes:["qa-first":.phone])
        try await wait("first Phone release") {router.status(for:"qa-first").phase == .phone}
        XCTAssertEqual(router.status(for:"qa-second").phase,.ready)
        XCTAssertEqual(count(launches),2,"Releasing one device must not restart another")
        await router.shutdown()
    }

    @MainActor func testQAInvalidOwnershipSymlinkFailsWithoutLaunchingOrOverwritingTarget() async throws {
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client"),launches=dir.appendingPathComponent("launches"),target=dir.appendingPathComponent("foreign")
        try executable(adb,"#!/bin/sh\nif [ \"$4\" = getprop ]; then echo 35; fi\n")
        try executable(client,"#!/bin/sh\necho launch >> '\(launches.path)'\nexec /bin/sleep 30\n")
        try Data("preserve foreign bytes".utf8).write(to:target)
        let lockName=sha256("qa-device")+".lock"
        try FileManager.default.createSymbolicLink(at:dir.appendingPathComponent(lockName),withDestinationURL:target)
        let router=DeviceAudioRouter(toolchain:Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path),directory:dir,supervisor:supervisor,outputAvailable:{true},startupTimeout:0.5)
        addTeardownBlock { await router.shutdown() }
        router.reconcile(activeSerials:["qa-device"],connectedSerials:["qa-device"],routes:[:])
        try await wait("invalid ownership refused") {router.status(for:"qa-device").phase == .failed}
        XCTAssertEqual(count(launches),0);XCTAssertEqual(try Data(contentsOf:target),Data("preserve foreign bytes".utf8))
        await router.shutdown()
    }
    @MainActor func testQAReadyClientFailureLatchesAndRetryLeavesOtherDeviceRunning() async throws {
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client"),launches=dir.appendingPathComponent("launches"),fail=dir.appendingPathComponent("fail-first")
        try executable(adb,"#!/bin/sh\nif [ \"$4\" = getprop ]; then echo 35; fi\n")
        try executable(client,"#!/bin/sh\necho \"$2\" >> '\(launches.path)'\necho 'INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY'\nwhile true; do if [ \"$2\" = qa-first ] && [ -f '\(fail.path)' ]; then echo 'ERROR: fixture output lost'; exit 7; fi; /bin/sleep 0.05; done\n")
        let router=DeviceAudioRouter(toolchain:Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path),directory:dir,supervisor:supervisor,outputAvailable:{true})
        addTeardownBlock { await router.shutdown() }
        router.reconcile(activeSerials:["qa-first","qa-second"],connectedSerials:["qa-first","qa-second"],routes:[:])
        try await wait("both output markers") {router.status(for:"qa-first").phase == .ready && router.status(for:"qa-second").phase == .ready}
        try Data().write(to:fail)
        try await wait("post-ready output failure") {router.status(for:"qa-first").phase == .failed}
        XCTAssertTrue(router.status(for:"qa-first").message.contains("fixture output lost"))
        try await Task.sleep(for:.milliseconds(1250))
        XCTAssertEqual(count(launches),2,"A failed ready client must not endlessly restart")
        XCTAssertEqual(router.status(for:"qa-second").phase,.ready)
        try FileManager.default.removeItem(at:fail)
        router.retry(serial:"qa-first")
        try await wait("explicit Retry output") {router.status(for:"qa-first").phase == .ready}
        XCTAssertEqual(count(launches),3)
        XCTAssertEqual(router.status(for:"qa-second").phase,.ready)
        await router.shutdown()
    }

    @MainActor func testQAFullPreferenceCapacityKeepsKnownRouteAndUnknownPhoneEscape() async throws {
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client"),launches=dir.appendingPathComponent("launches")
        try executable(adb,"#!/bin/sh\nif [ \"$4\" = getprop ]; then echo 35; fi\n")
        try executable(client,"#!/bin/sh\necho \"$2\" >> '\(launches.path)'\necho 'INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY'\nexec /bin/sleep 30\n")
        var routes=Dictionary(uniqueKeysWithValues:(0..<32).map {("qa-known\($0)",DeviceAudioRoute.phone)})
        routes["qa-known0"] = .mac
        let prefs=DroidBridgePreferences(deviceAudioRoutes:routes)
        XCTAssertEqual(prefs.audioRoute(for:"qa-unknown"),.phone)
        XCTAssertEqual(prefs.audioRoute(for:"qa-known0"),.mac)
        let router=DeviceAudioRouter(toolchain:Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path),directory:dir,supervisor:supervisor,outputAvailable:{true})
        addTeardownBlock { await router.shutdown() }
        router.reconcile(activeSerials:["qa-known0","qa-unknown"],connectedSerials:["qa-known0","qa-unknown"],routes:routes)
        try await wait("known capture and unknown Phone") {router.status(for:"qa-known0").phase == .ready && router.status(for:"qa-unknown").phase == .phone}
        XCTAssertEqual(router.status(for:"qa-unknown").route,.phone)
        XCTAssertEqual(count(launches),1)
        router.retry(serial:"qa-unknown")
        try await Task.sleep(for:.milliseconds(1200))
        XCTAssertEqual(count(launches),1,"Retry must not bypass full-capacity Phone admission")
        routes["qa-known0"] = .phone
        router.reconcile(activeSerials:["qa-known0","qa-unknown"],connectedSerials:["qa-known0","qa-unknown"],routes:routes)
        try await wait("known device Phone remains available") {router.status(for:"qa-known0").phase == .phone}
        XCTAssertEqual(count(launches),1)
        await router.shutdown()
    }

    @MainActor func testQACapacityGrowthStopsPreviouslyDefaultMacCapture() async throws {
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client"),launches=dir.appendingPathComponent("launches")
        try executable(adb,"#!/bin/sh\nif [ \"$4\" = getprop ]; then echo 35; fi\n")
        try executable(client,"#!/bin/sh\necho \"$2\" >> '\(launches.path)'\necho 'INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY'\nexec /bin/sleep 30\n")
        var routes=Dictionary(uniqueKeysWithValues:(0..<31).map {("qa-history\($0)",DeviceAudioRoute.phone)})
        let router=DeviceAudioRouter(toolchain:Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path),directory:dir,supervisor:supervisor,outputAvailable:{true})
        addTeardownBlock { await router.shutdown() }
        router.reconcile(activeSerials:["qa-unknown"],connectedSerials:["qa-unknown"],routes:routes)
        try await wait("31-entry default Mac ready") {router.status(for:"qa-unknown").phase == .ready}
        routes["qa-history31"] = .phone
        router.reconcile(activeSerials:["qa-unknown"],connectedSerials:["qa-unknown"],routes:routes)
        try await wait("32-entry capacity fences existing default capture") {router.status(for:"qa-unknown").phase == .phone}
        XCTAssertEqual(router.status(for:"qa-unknown").route,.phone)
        XCTAssertEqual(count(launches),1)
        await router.shutdown()
    }

    func testQASeparateAudioAuthoritySurvivesLegacyGlobalPreferenceRewrite() throws {
        struct LegacyPreferences:Codable {
            var bulkWrapperOnboardingEnabled=true
            var showAndroidSystemDecorations=true
            var screenOffDeviceSerials=Set<String>()
        }
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let global=dir.appendingPathComponent("preferences.json"),audio=dir.appendingPathComponent("audio-preferences.json")
        _=try DroidBridgePreferences.update(url:global) {$0.showAndroidSystemDecorations=false}
        try DeviceAudioPreferences.setRoute(.phone,for:"qa-phone",url:audio)
        try DeviceAudioPreferences.setRoute(.macAndPhone,for:"qa-duplicate",url:audio)
        let acceptedAudio=try Data(contentsOf:audio)
        // Mirrors the old Codable writer: decode/re-encode only old known keys.
        var legacy=try JSONDecoder().decode(LegacyPreferences.self,from:Data(contentsOf:global))
        legacy.screenOffDeviceSerials=["qa-phone"];legacy.bulkWrapperOnboardingEnabled=false
        try JSONEncoder().encode(legacy).write(to:global,options:.atomic)
        XCTAssertEqual(try Data(contentsOf:audio),acceptedAudio)
        XCTAssertEqual(try DeviceAudioPreferences.loadRoutes(url:audio),["qa-phone":.phone,"qa-duplicate":.macAndPhone])
        // A conflicting prototype field in the unrelated global file is no authority.
        _=try DroidBridgePreferences.update(url:global) {$0.deviceAudioRoutes["qa-phone"] = .mac}
        XCTAssertEqual(try DeviceAudioPreferences.loadRoutes(url:audio)["qa-phone"],.phone)
        XCTAssertEqual(try Data(contentsOf:audio),acceptedAudio)
    }

    func testQASeparateAudioStoreBoundsAndBusyRefusalPreserveAcceptedBytes() throws {
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let audio=dir.appendingPathComponent("audio-preferences.json")
        for index in 0..<DroidBridgePreferences.maximumAudioDevices {try DeviceAudioPreferences.setRoute(.phone,for:"qa-\(index)",url:audio)}
        XCTAssertEqual(try DeviceAudioPreferences.loadRoutes(url:audio).count,32)
        let bytes=try Data(contentsOf:audio)
        XCTAssertThrowsError(try DeviceAudioPreferences.setRoute(.mac,for:"qa-33",url:audio))
        XCTAssertEqual(try Data(contentsOf:audio),bytes)
        let fd=open(audio.appendingPathExtension("lock").path,O_RDWR|O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd,0);guard fd>=0 else {return};defer {close(fd)}
        XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0)
        let start=ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try DeviceAudioPreferences.setRoute(.mac,for:"qa-0",url:audio))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,0.5,"Busy audio preferences must not block the GUI indefinitely")
        XCTAssertEqual(try Data(contentsOf:audio),bytes)
    }

    @MainActor func testQAObservedPTYTitlePrefixDoesNotHideInitializedAudioReceipt() async throws {
        let dir=try temp();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client")
        try executable(adb,"#!/bin/sh\nif [ \"$4\" = getprop ]; then echo 35; fi\n")
        // Exact structure observed from the real pinned client under the PTY.
        try executable(client,"#!/bin/sh\nprintf '\\033]0;scrcpy - Android SDK built for arm64\\007INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY\\n'\nexec /bin/sleep 30\n")
        let router=DeviceAudioRouter(toolchain:Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path),directory:dir,supervisor:supervisor,outputAvailable:{true},startupTimeout:0.5)
        addTeardownBlock { await router.shutdown() }
        router.reconcile(activeSerials:["qa-pty"],connectedSerials:["qa-pty"],routes:[:])
        try await wait("PTY-prefixed output state") {router.status(for:"qa-pty").phase == .ready || router.status(for:"qa-pty").phase == .failed}
        XCTAssertEqual(router.status(for:"qa-pty").phase,.ready,"A supported terminal title before the exact successful SDL receipt must not cause a false audio timeout")
        await router.shutdown()
    }

}

import CryptoKit
private func sha256(_ value:String)->String {SHA256.hash(data:Data(value.utf8)).map {String(format:"%02x",$0)}.joined()}
