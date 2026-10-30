import XCTest
import Foundation
import Darwin
import DroidBridgeCore
import DroidBridgeStreaming

/// Exercises the actual session spawn path. These fake tools capture arguments;
/// they prove configuration policy, never live Android video or input behavior.
final class HiddenIMEArgumentTests:XCTestCase {
    private struct Fixture {
        let root:URL
        let tools:Toolchain
        let portDescriptor:Int32
        func remove() {close(portDescriptor);try? FileManager.default.removeItem(at:root)}
    }
    private func fixture(sdk:String="35") throws ->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("DroidBridge-IME-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        // Reserve an unlistened loopback endpoint so the native fixture cannot
        // accidentally connect to an unrelated service while its child exits.
        let fd=socket(AF_INET,SOCK_STREAM,0)
        guard fd>=0 else {throw BridgeError.message("Fixture socket failed")}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        guard withUnsafePointer(to:&address,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}})==0 else {close(fd);throw BridgeError.message("Fixture bind failed")}
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to:&address,{$0.withMemoryRebound(to:sockaddr.self,capacity:1){getsockname(fd,$0,&size)}})==0 else {close(fd);throw BridgeError.message("Fixture port failed")}
        let port=UInt16(bigEndian:address.sin_port)
        let adb=root.appendingPathComponent("adb"),scrcpy=root.appendingPathComponent("scrcpy")
        try sdk.write(to:root.appendingPathComponent("sdk"),atomically:true,encoding:.utf8)
        let adbBody="""
        #!/usr/bin/python3
        import json,pathlib,sys
        root=pathlib.Path(__file__).parent
        args=sys.argv[1:]
        with (root/'adb-commands.jsonl').open('a') as log: log.write(json.dumps(args)+'\\n')
        if 'getprop' in args:
            print((root/'sdk').read_text())
        elif 'resolve-activity' in args:
            print('dev.droidbridge.testapp/.MainActivity')
        elif 'tcp:0' in args:
            print(\(port))
        elif any(arg.startswith('CLASSPATH=') for arg in args):
            (root/'native.json').write_text(json.dumps(args))
            sys.exit(1)
        """
        let externalBody="""
        #!/usr/bin/python3
        import json,pathlib,sys,time
        args=sys.argv[1:]
        if args==['--version']:
            print('scrcpy 5.0.1')
            sys.exit(0)
        (pathlib.Path(__file__).parent/'external.json').write_text(json.dumps(args))
        print('[server] INFO: Starting app "Probe" [dev.droidbridge.testapp] on display 7...',flush=True)
        print('INFO: Texture: 720x1080',flush=True)
        time.sleep(30)
        """
        try adbBody.write(to:adb,atomically:true,encoding:.utf8)
        try externalBody.write(to:scrcpy,atomically:true,encoding:.utf8)
        for executable in [adb,scrcpy] {try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)}
        return Fixture(root:root,tools:Toolchain(adb:adb.path,scrcpy:scrcpy.path,server:root.appendingPathComponent("server").path),portDescriptor:fd)
    }
    private func descriptor(_ backend:BackendKind,decorations:Bool,restored:Bool) throws ->SessionDescriptor {
        let original=SessionDescriptor(device:AndroidDevice(serial:"qa-ime-"+UUID().uuidString,model:"Fixture"),application:AndroidApplication(packageName:"dev.droidbridge.testapp",name:"Probe"),configuration:SessionConfiguration(backend:backend,showSystemDecorations:decorations))
        guard restored else {return original}
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as? [String:Any])
        var configuration=try XCTUnwrap(json["configuration"] as? [String:Any])
        // IME placement is a runtime invariant, not a restoreable override.
        configuration["displayImePolicy"]="local"
        configuration["display_ime_policy"]="fallback"
        json["configuration"]=configuration
        return try JSONDecoder().decode(SessionDescriptor.self,from:JSONSerialization.data(withJSONObject:json))
    }
    @MainActor
    private func capturedArguments(_ backend:BackendKind,decorations:Bool,restored:Bool,api:Int?=nil) async throws ->[String] {
        let fixture=try fixture(sdk:String(api ?? (restored ? 33 : 35)));defer {fixture.remove()}
        let session=BridgeSession(descriptor:try descriptor(backend,decorations:decorations,restored:restored),toolchain:fixture.tools)
        if backend == .scrcpy {
            try await session.start()
            XCTAssertEqual(session.state,.running)
        } else {
            do {try await session.start();XCTFail("Argument fixture does not provide video; native startup must fail")} catch {}
            XCTAssertNotEqual(session.state,.running)
        }
        await session.stopAndWait()
        defer {
            try? FileManager.default.removeItem(at:session.logURL)
            try? FileManager.default.removeItem(at:session.logURL.appendingPathExtension("jsonl"))
        }
        let capture=fixture.root.appendingPathComponent(backend == .scrcpy ? "external.json" : "native.json")
        return try JSONDecoder().decode([String].self,from:Data(contentsOf:capture))
    }
    @MainActor
    func testBothActualSpawnPathsAlwaysHideIMEForNewAndRestoredSessions() async throws {
        for backend in BackendKind.allCases {
            for restored in [false,true] {
                for decorations in [false,true] {
                    let args=try await capturedArguments(backend,decorations:decorations,restored:restored)
                    let ime=args.filter{$0.contains("ime-policy=") || $0.hasPrefix("display_ime_policy=")}
                    XCTAssertEqual(ime,[backend == .scrcpy ? "--display-ime-policy=hide" : "display_ime_policy=hide"],"\(backend) restored=\(restored) decorations=\(decorations)")
                    XCTAssertFalse(args.contains{$0=="settings" || $0=="ime"},"Session policy must not change global keyboard settings")
                }
            }
        }
    }
    @MainActor
    func testFallbackHoverMitigationAppliesOnlyToAndroid15() async throws {
        for api in [33,34,35,36,37] {
            let args=try await capturedArguments(.scrcpy,decorations:true,restored:false,api:api)
            XCTAssertEqual(args.contains("--no-mouse-hover"),api==35,"API \(api)")
            XCTAssertTrue(args.contains("--display-ime-policy=hide"))
        }
    }
    @MainActor
    func testUnsupportedOrUnknownSDKFailsBeforeAppResolutionStagingOrChildLaunch() async throws {
        for backend in BackendKind.allCases {
            for sdk in ["29","30","31","32","","unknown","35\nnot-ready"] {
                let fixture=try fixture(sdk:sdk)
                let session=BridgeSession(descriptor:try descriptor(backend,decorations:false,restored:true),toolchain:fixture.tools)
                do {try await session.start();XCTFail("Unsupported or ambiguous SDK must fail closed")} catch {
                    XCTAssertTrue(error.localizedDescription.contains("Android 13 (API 33)"),error.localizedDescription)
                }
                XCTAssertEqual(session.state,.failed)
                await session.stopAndWait()
                let lines=try String(contentsOf:fixture.root.appendingPathComponent("adb-commands.jsonl")).split(separator:"\n")
                let commands=try lines.map {try JSONDecoder().decode([String].self,from:Data($0.utf8))}
                XCTAssertEqual(commands.count,1)
                XCTAssertEqual(commands.first?.suffix(3),["shell","getprop","ro.build.version.sdk"])
                XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("native.json").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath:fixture.root.appendingPathComponent("external.json").path))
                try? FileManager.default.removeItem(at:session.logURL)
                try? FileManager.default.removeItem(at:session.logURL.appendingPathExtension("jsonl"))
                fixture.remove()
            }
        }
    }

}
