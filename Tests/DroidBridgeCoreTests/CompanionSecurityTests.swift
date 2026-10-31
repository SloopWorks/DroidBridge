import XCTest
import Foundation
import Darwin
@testable import DroidBridgeCore

/// Negative protocol tests use a local hostile pinned-TLS peer, never an Android device.
/// They establish parser/transport properties, not two-platform end-to-end success.
final class CompanionSecurityTests: XCTestCase {
    private let credential = String(repeating: "a", count: 43)

    func testEndpointCannotRedirectAuthorityToNetworkOrUserInfo() throws {
        for endpoint in [
            "http://127.0.0.1:1234", "http://localhost:1234", "http://[::1]:1234",
            "http://192.168.1.1:1234", "http://127.0.0.1", "http://user@127.0.0.1:1234",
            "http://127.0.0.1:1234/path", "http://127.0.0.1:1234/?secret=x",
            "http://127.0.0.1:1234/#fragment"
        ] {
            XCTAssertThrowsError(try CompanionClient(baseURL: XCTUnwrap(URL(string: endpoint))), endpoint)
        }
        _ = try CompanionClient(baseURL: XCTUnwrap(URL(string: "https://127.0.0.1:1234")), serverPin: String(repeating: "a", count: 64))
    }

    func testFixtureWaitsForCompletePortPublicationBeforeSendingTLSRequest() async throws {
        // Former code stopped at file existence and parsed an empty port once.
        // A 50ms incomplete publication deterministically covers that window.
        let peer = try CompanionTLSFixture(portPublicationDelay: 0.05) { requestID in
            let body = try! JSONSerialization.data(withJSONObject: ["protocol": 1, "request_id": requestID, "data": ["ready": true]])
            return CompanionTLSFixture.response(body)
        }
        defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        let result = try await client.diagnostics()
        XCTAssertEqual(result["ready"], .bool(true))
        XCTAssertTrue(peer.request.contains("GET /v1/diagnostics"))
    }

    func testCredentialsRejectHeaderInjectionAndWrongLength() throws {
        try CompanionClient.validateSecret(credential)
        for value in ["", String(repeating: "a", count: 42), String(repeating: "a", count: 44),
                      String(repeating: "a", count: 41) + "\r\n", String(repeating: "é", count: 43),
                      String(repeating: "a", count: 42) + ";"] {
            XCTAssertThrowsError(try CompanionClient.validateSecret(value))
        }
    }
    func testMissingMalformedPinsFailBeforeTransport() throws {
        let url = try XCTUnwrap(URL(string: "https://127.0.0.1:1234"))
        XCTAssertThrowsError(try CompanionClient(baseURL: url)) { XCTAssertEqual(($0 as? CompanionBoundaryError)?.code, "missing_server_pin") }
        for pin in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63), String(repeating: "a", count: 65), "../../cert"] {
            XCTAssertThrowsError(try CompanionClient(baseURL: url, serverPin: pin)) { XCTAssertEqual(($0 as? CompanionBoundaryError)?.code, "invalid_server_pin") }
        }
    }
    func testDifferentTLSLeafCannotHarvestPairingSecretOrSavedBearer() async throws {
        for pairing in [false, true] {
            let peer = try HostileCompanionPeer(json: #"{"protocol":1,"data":{}}"#); defer { peer.close() }
            let client = try CompanionClient(baseURL: peer.url, serverPin: String(repeating: "0", count: 64), credential: pairing ? nil : credential)
            if pairing { await assertBoundary("server_pin_mismatch") { try await client.beginPair(secret: credential, macID: UUID(), name: "Owned test Mac") } }
            else { await assertBoundary("server_pin_mismatch") { try await client.diagnostics() } }
            XCTAssertEqual(peer.request, "", "Untrusted TLS peer received application request bytes")
        }
    }
    func testPinnedCertificateMustAlsoMatchExpectedLoopbackHost() async throws {
        let peer = try CompanionTLSFixture(certificateIP: "127.0.0.2") { _ in CompanionTLSFixture.response(Data("{}".utf8)) }; defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        await assertBoundary("server_authentication_failed") { try await client.diagnostics() }
        XCTAssertEqual(peer.request, "")
    }
    func testCancellationDuringTLSHandshakeSendsNoApplicationBytes() async throws {
        for _ in 0..<4 {
            let peer = try CompanionTLSFixture(handshakeDelay: 0.25) { _ in CompanionTLSFixture.response(Data("{}".utf8)) }; defer { peer.close() }
            let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
            let task = Task { try await client.diagnostics() }
            try await Task.sleep(nanoseconds: 20_000_000); task.cancel()
            do { _ = try await task.value; XCTFail("Handshake cancellation succeeded") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
            XCTAssertEqual(peer.request, "")
        }
    }

    func testDynamicPathsAndCommandNamesRejectBeforeNetwork() async throws {
        let client = try CompanionClient(baseURL: XCTUnwrap(URL(string: "https://127.0.0.1:1")), serverPin: String(repeating: "a", count: 64), credential: credential)
        await assertBoundary("invalid_id") { try await client.transferStatus(id: "../trust") }
        await assertBoundary("invalid_hash") { try await client.icon(hash: String(repeating: "A", count: 64)) }
        await assertBoundary("unsupported_command") { try await client.sendCommand(kind: "exec", payload: ["command": .string("anything")]) }
        await assertBoundary("invalid_chunk") { try await client.uploadChunk(id: UUID().uuidString, index: 0, data: Data(count: 65_537)) }
        await assertBoundary("invalid_chunk") { try await client.downloadChunk(id: UUID().uuidString, index: -1) }
        await assertBoundary("invalid_transfer") {
            try await client.beginTransfer(CompanionTransfer(direction: "to_phone", displayName: "file", mimeType: "application/octet-stream", size: 52_428_801, sha256: String(repeating: "0", count: 64)))
        }
    }

    func testUnauthenticatedProtectedRequestDoesNotAttemptNetwork() async throws {
        let client = try CompanionClient(baseURL: XCTUnwrap(URL(string: "https://127.0.0.1:1")), serverPin: String(repeating: "a", count: 64))
        await assertBoundary("not_paired") { try await client.diagnostics() }
    }

    func testRedirectIsRefusedRatherThanForwardingBearerCredential() async throws {
        let peer = try HostileCompanionPeer(response: "HTTP/1.1 302 Found\r\nLocation: http://192.0.2.1:4444/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        await assertBoundary("redirect_refused") { try await client.diagnostics() }
        XCTAssertTrue(peer.request.contains("Authorization: Bearer \(credential)"))
    }

    func testDeclaredAndStreamedOversizeAreRejected() async throws {
        let declared = try HostileCompanionPeer(body: Data(repeating: 120, count: 262_145), type: "application/json")
        defer { declared.close() }
        let client = try CompanionClient(baseURL: declared.url, serverPin: declared.serverPin, credential: credential)
        await assertBoundary("response_too_large") { try await client.diagnostics() }
        let streamed = try HostileCompanionPeer(response: "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" + String(repeating: "x", count: 262_145))
        defer { streamed.close() }
        let second = try CompanionClient(baseURL: streamed.url, serverPin: streamed.serverPin, credential: credential)
        await assertBoundary("response_too_large") { try await second.diagnostics() }
    }

    func testUnknownProtocolCannotBeDecodedAsSuccess() async throws {
        let data = #"{"protocol":2,"request_id":"C013244A-E611-4D69-995C-BFE9B844BEF8","data":{}}"#
        let peer = try HostileCompanionPeer(json: data)
        defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        await assertBoundary("unsupported_protocol") { try await client.diagnostics() }
    }

    func testMalformedPNGIntegrityAndDimensionsRejected() async throws {
        // Deliberately not a valid image: header declares >512 pixels. No decoder
        // should be called before the fixed dimension and hash checks reject it.
        var bytes = Data([137,80,78,71,13,10,26,10] + Array(repeating: UInt8(0), count: 8))
        bytes.append(contentsOf: [0,0,2,1, 0,0,0,1])
        let peer = try HostileCompanionPeer(body: bytes, type: "image/png")
        defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: credential)
        await assertBoundary("invalid_icon") { try await client.icon(hash: CompanionClient.sha256(bytes)) }
    }

    private func assertBoundary<T>(_ code: String, operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as CompanionBoundaryError { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Expected \(code), got \(error)", file: file, line: line) }
    }
}

private final class HostileCompanionPeer: @unchecked Sendable {
    private let fixture: CompanionTLSFixture
    var url: URL { fixture.url }
    var serverPin: String { fixture.serverPin }
    var request: String { fixture.request }
    convenience init(json: String) throws { try self.init(body: Data(json.utf8), type: "application/json") }
    convenience init(body: Data, type: String) throws { try self.init(responseData: CompanionTLSFixture.response(body, mime: type)) }
    convenience init(response: String) throws { try self.init(responseData: Data(response.utf8)) }
    init(responseData: Data) throws { fixture = try CompanionTLSFixture { _ in responseData } }
    func close() { fixture.close() }
}
