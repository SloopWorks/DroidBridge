import XCTest
import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import Security
@testable import DroidBridgeCore

final class CompanionBoundaryTests: XCTestCase {
    private let credential = String(repeating: "a", count: 43)
    func testHelloRequiresUUIDAndPositiveOrderedProtocolRange() async throws {
        for change in [["device_id": "fake"], ["protocol_min": 0], ["protocol_min": 2, "protocol_max": 1]] as [[String: Any]] {
            let peer = try BoundaryPeer { request in
                var hello: [String: Any] = ["device_id": UUID().uuidString, "device_name": "Owned test phone", "protocol_min": 1, "protocol_max": 1, "capabilities": []]
                hello.merge(change) { _, new in new }; return .json(hello, request)
            }; defer { peer.close() }
            let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin)
            await expect("unsupported_protocol") { try await client.hello() }
        }
    }
    func testRequestCorrelationAndMIMEAreRequired() async throws {
        let peer = try BoundaryPeer { _ in .json([:], UUID().uuidString) }; defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        await expect("request_mismatch") { try await client.diagnostics() }
        let wrongMIME = try BoundaryPeer { request in .json([:], request, mime: "text/html") }; defer { wrongMIME.close() }
        let other = try CompanionClient(baseURL: wrongMIME.url, serverPin: wrongMIME.serverPin, credential: credential)
        await expect("invalid_mime") { try await other.diagnostics() }
    }
    func testCatalogDeletedIdentityAndUTF8ByteBound() async throws {
        let peer = try BoundaryPeer { request in .json(["generation": "v1", "items": [], "deleted": ["../bad"]], request) }; defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        await expect("invalid_app") { try await client.catalogChanges(after: "v0") }
        let unicode = try BoundaryPeer { request in .json(["generation": "v1", "items": [["package_name": "dev.test.app", "label": String(repeating: "😀", count: 100)]], "next_cursor": NSNull()], request) }; defer { unicode.close() }
        let second = try CompanionClient(baseURL: unicode.url, serverPin: unicode.serverPin, credential: credential)
        await expect("invalid_app") { try await second.catalog() }
    }
    func testPNGMustActuallyDecodeAndValidPNGPasses() async throws {
        let malformed = Data([137,80,78,71,13,10,26,10, 0,0,0,13, 73,72,68,82, 0,0,0,1, 0,0,0,1])
        let peer = try BoundaryPeer { _ in .init(data: malformed, mime: "image/png") }; defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        await expect("invalid_icon") { try await client.icon(hash: CompanionClient.sha256(malformed)) }
        let color = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let png = NSMutableData(); let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let pngBytes = png as Data
        let valid = try BoundaryPeer { _ in .init(data: pngBytes, mime: "image/png") }; defer { valid.close() }
        let second = try CompanionClient(baseURL: valid.url, serverPin: valid.serverPin, credential: credential)
        let bytes = try await second.icon(hash: CompanionClient.sha256(png as Data)); XCTAssertEqual(bytes, png as Data)
    }
    func testDeepJSONAndNonUTF8AreRejectedBeforeDecoding() async throws {
        let nested = Data((String(repeating: "[", count: 25) + "0" + String(repeating: "]", count: 25)).utf8)
        for data in [nested, Data([0xff, 0xfe])] {
            let peer = try BoundaryPeer { _ in .init(data: data, mime: "application/json") }; defer { peer.close() }
            let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
            await expect("invalid_json") { try await client.diagnostics() }
        }
    }
    func testPairingAndAuthenticatedIdentityBindExpectedInstallation() async throws {
        let expected = UUID().uuidString
        let peer = try BoundaryPeer { request in .json(["device_id": UUID().uuidString, "trust_id": UUID().uuidString, "protocol": 1], request) }; defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        try await client.setExpectedDeviceID(expected)
        await expect("identity_changed") { try await client.identity() }
        let pairing = try BoundaryPeer { request in .json(["status": "approved", "credential": String(repeating: "a", count: 43), "device_id": UUID().uuidString, "trust_id": UUID().uuidString], request) }; defer { pairing.close() }
        let second = try CompanionClient(baseURL: pairing.url, serverPin: pairing.serverPin); try await second.setExpectedDeviceID(expected)
        await expect("identity_changed") { try await second.pollPair(id: UUID().uuidString, secret: credential) }
    }
    func testCancellationBeforeStartAndWhileReceivingCompletesOnce() async throws {
        for delay in [0, 10_000_000] as [UInt64] {
            for _ in 0..<12 {
                let peer = try BoundaryPeer(delay: 0.15) { request in .json([:], request) }; defer { peer.close() }
                let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
                let task = Task { try await client.diagnostics() }
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }; task.cancel()
                do { _ = try await task.value; XCTFail("Cancelled operation returned success") }
                catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
            }
        }
    }
    func testCanonicalCommandCarriesExpiryAndRejectsConflictingRetry() async throws {
        let id = UUID()
        let peer = try BoundaryPeer { request in .json(["request_id": request, "status": "applied"], request) }; defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        let receipt = try await client.sendCommand(kind: "clipboard_text", payload: ["text": .string("owned synthetic fixture")], requestID: id)
        XCTAssertEqual(receipt.requestId, id.uuidString)
        let request = peer.request
        XCTAssertTrue(request.contains("X-Request-ID: \(id.uuidString)"))
        let body = try XCTUnwrap(request.components(separatedBy: "\r\n\r\n").last?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let expiry = try XCTUnwrap(ISO8601DateFormatter().date(from: try XCTUnwrap(object["expires_at"] as? String)))
        XCTAssertGreaterThan(expiry.timeIntervalSinceNow, 25); XCTAssertLessThanOrEqual(expiry.timeIntervalSinceNow, 30)
        await expect("request_conflict") { try await client.sendCommand(kind: "clipboard_text", payload: ["text": .string("different fixture")], requestID: id) }
    }
    func testTransferReceiptAcknowledgesOnlyVerifiedWholeFileMetadata() async throws {
        let transfer = UUID().uuidString, hash = String(repeating: "a", count: 64)
        let peer = try BoundaryPeer { request in .json(["transfer_id": transfer, "next_index": 1, "accepted_bytes": 9, "committed": true], request) }; defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        let status = try await client.transferReceipt(id: transfer, acceptedBytes: 9, sha256: hash)
        XCTAssertTrue(status.committed); XCTAssertEqual(status.acceptedBytes, 9)
        let request = peer.request
        XCTAssertEqual(request.components(separatedBy: " ").dropFirst().first?.split(separator: "?").first.map(String.init), "/v1/transfers/\(transfer)/receipt")
        let body = try XCTUnwrap(request.components(separatedBy: "\r\n\r\n").last?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "downloaded"); XCTAssertEqual(object["accepted_bytes"] as? Int, 9); XCTAssertEqual(object["sha256"] as? String, hash)
        await expect("invalid_transfer") { try await client.transferReceipt(id: transfer, acceptedBytes: 9, sha256: hash, status: "downloading") }
        await expect("invalid_transfer") { try await client.transferReceipt(id: transfer, acceptedBytes: 52_428_801, sha256: hash) }
        await expect("invalid_hash") { try await client.transferReceipt(id: transfer, acceptedBytes: 9, sha256: "bad") }
    }
    func testKeychainCredentialRoundTripUsesDedicatedRandomIdentity() throws {
        let device = UUID().uuidString
        XCTAssertNil(try CompanionCredentialStore.load(deviceID: device))
        defer { try? CompanionCredentialStore.remove(deviceID: device) }
        let record = try CompanionCredentialRecord(deviceID: device, trustID: UUID().uuidString, credential: credential, serverPin: String(repeating: "a", count: 64))
        try CompanionCredentialStore.save(record)
        XCTAssertEqual(try CompanionCredentialStore.load(deviceID: device), record)
        try CompanionCredentialStore.remove(deviceID: device)
        XCTAssertNil(try CompanionCredentialStore.load(deviceID: device))
    }
    func testLegacyUnpinnedKeychainRecordRequiresPairingBeforeTransport() throws {
        let device = UUID().uuidString.lowercased()
        let service = "dev.sloopworks.DroidBridge.companion.v1" + (CompanionQAScope.current?.keychainServiceSuffix ?? "")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: device, kSecValueData as String: Data(credential.utf8)]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        defer { try? CompanionCredentialStore.remove(deviceID: device) }
        XCTAssertThrowsError(try CompanionCredentialStore.load(deviceID: device)) { XCTAssertEqual(($0 as? CompanionBoundaryError)?.code, "re_pair_required") }
    }
    func testForwardNoRebindAndExactCleanupWithOwnedFakeADB() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-forward-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("adb")
        let script = #"""
        #!/usr/bin/python3
        import sys,json,pathlib
        root=pathlib.Path(__file__).parent
        state=root/'state.json'
        args=sys.argv[1:]
        with open(root/'calls.jsonl','a') as f: f.write(json.dumps(args)+'\n')
        if args==['forward','--list']:
            if state.exists(): print(' '.join(json.loads(state.read_text())))
        elif '--no-rebind' in args: state.write_text(json.dumps([args[1],args[-2],args[-1]]))
        elif '--remove' in args: state.unlink(missing_ok=True)
        else: sys.exit(2)
        """#
        try Data(script.utf8).write(to: fake); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let forward = try CompanionForward.reserve(serial: "emulator-5580", adbPath: fake.path)
        try await forward.establish()
        XCTAssertEqual(forward.baseURL.host, "127.0.0.1")
        try await forward.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"))
        XCTAssertTrue(calls.contains("--no-rebind")); XCTAssertTrue(calls.contains("tcp:37841")); XCTAssertFalse(calls.contains("kill-server"))
        let foreign = try CompanionForward.reserve(serial: "emulator-5580", adbPath: fake.path)
        try await foreign.establish()
        let replacement = ["emulator-5554", "tcp:\(foreign.port)", "tcp:39999"]
        try JSONSerialization.data(withJSONObject: replacement).write(to: root.appendingPathComponent("state.json"))
        try await foreign.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }
    private func expect<T>(_ code: String, operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as CompanionBoundaryError { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Expected \(code), received \(error)", file: file, line: line) }
    }
}

private struct BoundaryReply {
    let data: Data; let mime: String
    static func json(_ object: Any, _ request: String, mime: String = "application/json") -> Self {
        Self(data: try! JSONSerialization.data(withJSONObject: ["protocol": 1, "request_id": request, "data": object]), mime: mime)
    }
}
private final class BoundaryPeer: @unchecked Sendable {
    private let fixture: CompanionTLSFixture
    var url: URL { fixture.url }
    var serverPin: String { fixture.serverPin }
    var request: String { fixture.request }
    init(delay: TimeInterval = 0, response: @escaping @Sendable (String) -> BoundaryReply) throws {
        fixture = try CompanionTLSFixture(delay: delay) { id in let reply = response(id); return CompanionTLSFixture.response(reply.data, mime: reply.mime) }
    }
    func close() { fixture.close() }
}
