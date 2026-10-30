import XCTest
import Darwin
@testable import DroidBridgeCore
@testable import DroidBridgeStreaming

final class DeviceAudioTests:XCTestCase {
    private func temporary() throws ->URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("audio-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    private func executable(_ url:URL,_ text:String) throws {
        try text.write(to:url,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:url.path)
    }
    func testLegacyPreferencesAndAtomicMerge() throws {
        let dir=try temporary();defer {try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("prefs")
        try Data("{\"showAndroidSystemDecorations\":false,\"screenOffDeviceSerials\":[\"device-a\"]}".utf8).write(to:url)
        XCTAssertEqual(try DroidBridgePreferences.load(url:url).audioRoute(for:"device-a"),.mac)
        let value=try DroidBridgePreferences.update(url:url) {$0.deviceAudioRoutes["device-a"] = .macAndPhone}
        XCTAssertFalse(value.showAndroidSystemDecorations)
        XCTAssertEqual(value.screenOffDeviceSerials,["device-a"])
        XCTAssertEqual(try DroidBridgePreferences.load(url:url).audioRoute(for:"device-a"),.macAndPhone)
        let accepted=try Data(contentsOf:url)
        XCTAssertThrowsError(try DroidBridgePreferences.update(url:url) {$0.deviceAudioRoutes["bad serial"] = .phone})
        XCTAssertEqual(try Data(contentsOf:url),accepted)
    }
    func testAudioArgumentsCannotCaptureMicrophoneOrControlVideo() {
        XCTAssertTrue(DeviceAudioRouter.arguments(serial:"device-a",route:.phone,port:46001).isEmpty)
        for route in [DeviceAudioRoute.mac,.macAndPhone] {
            let args=DeviceAudioRouter.arguments(serial:"device-a",route:route,port:46001)
            for flag in ["--no-video","--no-control","--no-window","--no-power-on","--require-audio","--force-adb-forward","--audio-codec=raw"] {XCTAssertTrue(args.contains(flag))}
            XCTAssertFalse(args.contains { $0.contains("mic") || $0.contains("new-display") || $0.contains("start-app") || $0.contains("record") })
            XCTAssertEqual(args.contains("--audio-dup"),route == .macAndPhone)
            XCTAssertTrue(args.contains(route == .mac ? "--audio-source=output" : "--audio-source=playback"))
        }
    }
    @MainActor private func wait(_ seconds:Double=5,_ condition:()->Bool) async throws {
        let end=ProcessInfo.processInfo.systemUptime+seconds
        while !condition() && ProcessInfo.processInfo.systemUptime<end {try await Task.sleep(for:.milliseconds(20))}
        XCTAssertTrue(condition(),"Audio fixture did not reach its expected state")
    }
    @MainActor func testPositiveReadinessSingleOwnerHandoffAndRouteRelease() async throws {
        let dir=try temporary();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client")
        let identities=dir.appendingPathComponent("identities"),removed=dir.appendingPathComponent("removed")
        try executable(adb,"#!/bin/sh\nif [ \"$4\" = rm ]; then echo \"$6\" >> '\(removed.path)'; elif [ \"$3\" = shell ]; then echo 35; fi\nexit 0\n")
        try executable(client,"#!/bin/sh\necho \"$DROIDBRIDGE_AUDIO_SCID\" >> '\(identities.path)'\necho \"INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY\"\nexec /bin/sleep 30\n")
        let toolchain=Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path)
        let supervisor=FileManager.default.currentDirectoryPath+"/.build/debug/DroidBridgeSupervisor"
        let a=DeviceAudioRouter(toolchain:toolchain,directory:dir,supervisor:supervisor,outputAvailable:{true})
        let b=DeviceAudioRouter(toolchain:toolchain,directory:dir,supervisor:supervisor,outputAvailable:{true})
        a.reconcile(activeSerials:["test-a"],connectedSerials:["test-a"],routes:[:])
        try await wait {a.status(for:"test-a").phase == .ready}
        b.reconcile(activeSerials:["test-a"],connectedSerials:["test-a"],routes:[:])
        try await wait {b.status(for:"test-a").phase == .shared}
        XCTAssertEqual(b.status(for:"test-a").route,.mac)
        let observer=DeviceAudioRouter(toolchain:toolchain,directory:dir,supervisor:supervisor,outputAvailable:{true})
        observer.reconcile(activeSerials:[],connectedSerials:["test-a"],routes:["test-a":.phone])
        XCTAssertEqual(observer.status(for:"test-a").phase,.shared,"An inactive host must not claim Phone while another owner is active")
        XCTAssertEqual(observer.status(for:"test-a").route,.mac)
        await observer.shutdown()
        await a.shutdown()
        try await wait {b.status(for:"test-a").phase == .ready}
        b.reconcile(activeSerials:["test-a"],connectedSerials:["test-a"],routes:["test-a":.phone])
        try await wait {b.status(for:"test-a").phase == .phone}
        await b.shutdown()
        let identifiers=try String(contentsOf:identities).split(separator:"\n").map(String.init)
        let removedPaths=try String(contentsOf:removed).split(separator:"\n").map(String.init)
        XCTAssertEqual(identifiers.count,2)
        XCTAssertEqual(Set(removedPaths),Set(identifiers.map {"/data/local/tmp/droidbridge-audio-\($0).jar"}))
        XCTAssertTrue(identifiers.allSatisfy {$0.range(of:"^[0-7][0-9a-f]{7}$",options:.regularExpression) != nil})
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:dir.path).contains {$0.hasSuffix(".log")})
    }
    @MainActor func testDecoderLogIsNotReadyAndFailureLatchRequiresExplicitRetry() async throws {
        let dir=try temporary();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client"),count=dir.appendingPathComponent("count")
        try executable(adb,"#!/bin/sh\nif [ \"$3\" = shell ]; then echo 35; fi\nexit 0\n")
        try executable(client,"#!/bin/sh\necho launch >> '\(count.path)'\necho \"DEBUG: Decoder 'audio': pcm_s16le\"\nexec /bin/sleep 30\n")
        let tools=Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path)
        let supervisor=FileManager.default.currentDirectoryPath+"/.build/debug/DroidBridgeSupervisor"
        let a=DeviceAudioRouter(toolchain:tools,directory:dir,supervisor:supervisor,outputAvailable:{true},startupTimeout:1.0)
        a.reconcile(activeSerials:["test-a"],connectedSerials:["test-a"],routes:[:])
        try await wait {a.status(for:"test-a").phase == .failed}
        XCTAssertTrue(FileManager.default.fileExists(atPath:count.path),a.status(for:"test-a").message)
        XCTAssertEqual(try String(contentsOf:count).split(separator:"\n").count,1)
        let b=DeviceAudioRouter(toolchain:tools,directory:dir,supervisor:supervisor,outputAvailable:{true},startupTimeout:1.0)
        b.reconcile(activeSerials:["test-a"],connectedSerials:["test-a"],routes:[:])
        try await wait {b.status(for:"test-a").phase == .failed}
        XCTAssertEqual(try String(contentsOf:count).split(separator:"\n").count,1,"Another host must respect the shared failed attempt")
        try executable(client,"#!/bin/sh\necho launch >> '\(count.path)'\necho 'INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY'\nexec /bin/sleep 30\n")
        b.retry(serial:"test-a")
        try await wait {b.status(for:"test-a").phase == .ready || a.status(for:"test-a").phase == .ready}
        XCTAssertEqual(try String(contentsOf:count).split(separator:"\n").count,2)
        await a.shutdown();await b.shutdown()
    }
    @MainActor func testPhoneRoundTripClearsFailureWithoutImplicitRestartLoop() async throws {
        let dir=try temporary();defer {try? FileManager.default.removeItem(at:dir)}
        let adb=dir.appendingPathComponent("adb"),client=dir.appendingPathComponent("client")
        try executable(adb,"#!/bin/sh\nif [ \"$3\" = shell ]; then echo 35; fi\nexit 0\n")
        try executable(client,"#!/bin/sh\nexit 1\n")
        let tools=Toolchain(adb:adb.path,scrcpy:client.path,server:client.path,audioClient:client.path)
        let router=DeviceAudioRouter(toolchain:tools,directory:dir,supervisor:FileManager.default.currentDirectoryPath+"/.build/debug/DroidBridgeSupervisor",outputAvailable:{true})
        router.reconcile(activeSerials:["test-a"],connectedSerials:["test-a"],routes:[:])
        try await wait {router.status(for:"test-a").phase == .failed}
        router.reconcile(activeSerials:[],connectedSerials:[],routes:["test-a":.phone])
        try executable(client,"#!/bin/sh\necho 'INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY'\nexec /bin/sleep 30\n")
        router.reconcile(activeSerials:["test-a"],connectedSerials:["test-a"],routes:[:])
        try await wait {router.status(for:"test-a").phase == .ready}
        await router.shutdown()
    }
    @MainActor func testMissingOutputRefusesCapture() async throws {
        let dir=try temporary();defer {try? FileManager.default.removeItem(at:dir)}
        let router=DeviceAudioRouter(toolchain:Toolchain(),directory:dir,supervisor:"/nonexistent",outputAvailable:{false})
        router.reconcile(activeSerials:["test-a"],connectedSerials:["test-a"],routes:[:])
        try await wait {router.status(for:"test-a").phase == .failed}
        XCTAssertTrue(router.status(for:"test-a").message.contains("No Mac audio output"))
        await router.shutdown()
    }
}

final class DeviceAudioArtifactTests:XCTestCase {
    private func directory() throws ->URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    func testDeadAttemptRemovedAndLiveAttemptPreserved() throws {
        let dir=try directory();defer {try? FileManager.default.removeItem(at:dir)}
        let dead=UUID().uuidString,live=UUID().uuidString,pending=UUID().uuidString
        try Data("{\"ownerPID\":\(getpid()),\"supervisorPID\":0}".utf8).write(to:dir.appendingPathComponent(pending+".json"))
        let pendingLog=dir.appendingPathComponent(pending+".log")
        try Data("pending producer".utf8).write(to:pendingLog)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-3600)],ofItemAtPath:pendingLog.path)
        try Data("{\"ownerPID\":2147483647,\"supervisorPID\":2147483647}".utf8).write(to:dir.appendingPathComponent(dead+".json"))
        try Data("old diagnostic".utf8).write(to:dir.appendingPathComponent(dead+".log"))
        try Data("{\"ownerPID\":\(getpid()),\"supervisorPID\":\(getpid())}".utf8).write(to:dir.appendingPathComponent(live+".json"))
        try Data("live diagnostic".utf8).write(to:dir.appendingPathComponent(live+".log"))
        try DeviceAudioArtifacts.prepare(dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath:pendingLog.path),"Live GUI pending startup must survive cleanup")
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent(dead+".log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent(dead+".json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:dir.appendingPathComponent(live+".log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:dir.appendingPathComponent(live+".json").path))
    }
    func testHeldOwnerTokenPreservesUnpublishedLog() throws {
        let dir=try directory();defer {try? FileManager.default.removeItem(at:dir)}
        let token=UUID().uuidString
        let lock=dir.appendingPathComponent(String(repeating:"a",count:64)+".lock")
        let fd=open(lock.path,O_CREAT|O_RDWR|O_CLOEXEC,0o600);defer {close(fd)}
        XCTAssertGreaterThanOrEqual(fd,0);XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0)
        let bytes=Array(token.utf8);_ = bytes.withUnsafeBytes {write(fd,$0.baseAddress,$0.count)}
        let log=dir.appendingPathComponent(token+".log")
        try Data("live unpublished".utf8).write(to:log)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-3600)],ofItemAtPath:log.path)
        try DeviceAudioArtifacts.prepare(dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath:log.path))
        flock(fd,LOCK_UN)
        try DeviceAudioArtifacts.prepare(dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath:log.path))
    }
    func testFailureDiagnosticsBoundedTo32FilesAnd64KiB() throws {
        let dir=try directory();defer {try? FileManager.default.removeItem(at:dir)}
        for _ in 0..<35 {try DeviceAudioArtifacts.saveFailure(dir,token:UUID().uuidString,text:String(repeating:"diagnostic",count:10_000))}
        let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter {$0.lastPathComponent.hasSuffix(".failed.log")}
        XCTAssertEqual(files.count,32)
        for file in files {XCTAssertLessThanOrEqual(try Data(contentsOf:file).count,65_536)}
    }
}
