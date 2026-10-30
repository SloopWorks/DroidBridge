import Foundation
import DroidBridgeCore

/// Shipping catalog engine with deterministic bounded peer responses. No AppKit
/// window, ADB, user state, credential, notification permission or network use.
@MainActor private final class CatalogPeer {
    let id = UUID().uuidString.lowercased()
    var trust = UUID().uuidString.lowercased(), token = UUID().uuidString.lowercased(), generation = "g1"
    var apps: [[String: CompanionJSON]] = (0..<1000).map { ["package_name": .string("dev.droidbridge.fixture.app\($0)"), "label": .string("App \($0)"), "icon_sha256": .string(String(repeating: "a", count: 64))] }
    var operations: [String] = [], deltaItems: [[String: CompanionJSON]] = [], deleted: [String] = []
    var stale = false, duplicate = false, pause = false
    var gate: CheckedContinuation<Void, Never>?
    func phone() -> CompanionDesktopDevice {
        CompanionDesktopDevice(.object(["device_id": .string(id), "serial": .string("qa-catalog"), "aliases": .array([.string("qa-catalog")]), "paired": .bool(true), "connected": .bool(true), "trust_id": .string(trust), "catalog_change_token": .string(token)]))!
    }
    func demand(_ consumer: String = "companion") -> CompanionCatalogSync.Demand { .init(phone: phone(), serial: "qa-catalog", consumer: consumer) }
    func request(_ op: String, _ payload: [String: CompanionJSON]) async throws -> [String: CompanionJSON] {
        operations.append(op)
        guard payload["device_id"]?.string == id, payload["expected_trust_id"]?.string == trust else { throw CompanionBoundaryError("wrong_trust", "Every catalog read must pin its exact original trust") }
        if op == "export_selection_get" { return ["selection": .object(["dev.droidbridge.fixture.app0": .bool(false)])] }
        let response: [String: CompanionJSON]
        if op == "catalog_changes" {
            if stale { throw CompanionBoundaryError("stale_cursor", "Generation no longer retained") }
            response = ["generation": .string(generation), "items": .array(deltaItems.map(CompanionJSON.object)), "deleted": .array(deleted.map(CompanionJSON.string))]
        } else {
            let start = Int(payload["cursor"]?.string ?? "0") ?? 0, end = min(start + 64, apps.count)
            var page = Array(apps[start..<end]); if duplicate, start > 0 { page[0] = apps[0] }
            response = ["generation": .string(generation), "items": .array(page.map(CompanionJSON.object)), "next_cursor": end < apps.count ? .string(String(end)) : .null]
        }
        if pause { pause = false; await withCheckedContinuation { gate = $0 } }
        return response
    }
    func count(_ op: String) -> Int { operations.filter { $0 == op }.count }
}

@main struct VerifyCatalogSync {
    @MainActor static func main() async throws {
        func require(_ value: Bool, _ text: String) throws { if !value { throw CompanionBoundaryError("fixture_failed", text) } }
        func wait(_ value: () -> Bool) async throws { for _ in 0..<300 { if value() { return }; try await Task.sleep(nanoseconds: 5_000_000) }; throw CompanionBoundaryError("fixture_timeout", "Catalog engine did not settle") }
        let peer = CatalogPeer(); var delivered: [(String, CompanionCatalogSync.Snapshot)] = [], progress: [Int] = [], errors: [String] = [], tick = 0.0
        let sync = CompanionCatalogSync(request: peer.request, deliver: { demand, snapshot in delivered.append((demand.phone.trustID!, snapshot)) }, report: { _, text in errors.append(text) }, progress: { _, snapshot in progress.append(snapshot.apps.count) }, now: { tick })
        sync.reconcile([peer.demand(), peer.demand("launcher")]); try await wait { delivered.count == 2 }
        try require(peer.count("catalog") == 16 && progress.first == 64 && progress.last == 960 && delivered.last?.1.apps.count == 1000, "First-page progress or shared bounded full load failed")
        let idle = peer.operations.count; for _ in 0..<100 { sync.reconcile([peer.demand(), peer.demand("launcher")]) }
        try require(peer.operations.count == idle && delivered.count == 2, "Unchanged local token caused catalog traffic or UI churn")
        peer.generation = "g2"; peer.token = UUID().uuidString.lowercased(); peer.deltaItems = [["package_name": .string("dev.droidbridge.fixture.app0"), "label": .string("Renamed App"), "icon_sha256": .string(String(repeating: "b", count: 64))], ["package_name": .string("dev.droidbridge.fixture.newapp"), "label": .string("New App")]]; peer.deleted = ["dev.droidbridge.fixture.app1"]
        sync.reconcile([peer.demand(), peer.demand("launcher")]); try await wait { delivered.count == 4 }
        let changed = delivered.last!.1
        try require(peer.count("catalog_changes") == 1 && peer.count("catalog") == 16 && changed.apps.count == 1000 && changed.apps.contains { $0.label == "Renamed App" } && !changed.apps.contains { $0.packageName == "dev.droidbridge.fixture.app1" }, "Atomic rename/add/delete delta failed")
        try require(changed.apps.first(where: { $0.packageName == "dev.droidbridge.fixture.app2" })?.iconSha256 == String(repeating: "a", count: 64), "Unchanged icon identity was discarded")
        peer.stale = true; peer.generation = "g3"; peer.token = UUID().uuidString.lowercased()
        sync.reconcile([peer.demand()]); try await wait { delivered.last?.1.generation == "g3" }
        try require(peer.count("catalog") == 32 && peer.count("catalog_changes") == 2, "Stale delta did not use exactly one bounded full fallback")
        peer.stale = false; peer.pause = true; peer.generation = "hidden"; peer.token = UUID().uuidString.lowercased()
        sync.reconcile([peer.demand()]); try await wait { peer.gate != nil }; let beforeHidden = delivered.count
        sync.reconcile([]); peer.gate?.resume(); peer.gate = nil; try await Task.sleep(nanoseconds: 30_000_000)
        let hiddenOps = peer.operations.count; for _ in 0..<100 { sync.reconcile([]) }
        try require(delivered.count == beforeHidden && peer.operations.count == hiddenOps, "A hidden UI published late data or started phone traffic")
        peer.pause = true; peer.generation = "old-trust"; peer.token = UUID().uuidString.lowercased(); sync.reconcile([peer.demand()]); try await wait { peer.gate != nil }
        let oldTrust = peer.trust, oldGate = peer.gate; peer.gate = nil; peer.trust = UUID().uuidString.lowercased(); peer.generation = "new-trust"; peer.token = UUID().uuidString.lowercased()
        sync.reconcile([peer.demand()]); try await wait { delivered.last?.1.generation == "new-trust" }
        let beforeOld = delivered.count; oldGate?.resume(); try await Task.sleep(nanoseconds: 30_000_000)
        try require(delivered.count == beforeOld && delivered.last?.0 != oldTrust, "Late old-trust response crossed a re-pair")
        peer.duplicate = true; peer.token = UUID().uuidString.lowercased(); peer.stale = true
        let beforeBad = delivered.count, beforeBadFull = peer.count("catalog")
        sync.reconcile([peer.demand()]); try await wait { errors.last?.contains("Retrying") == true }
        for _ in 0..<3 { tick += 10_000; sync.reconcile([peer.demand()]); try await Task.sleep(nanoseconds: 30_000_000) }
        let capped = peer.operations.count; for _ in 0..<100 { tick += 10_000; peer.token = UUID().uuidString.lowercased(); sync.reconcile([peer.demand()]) }
        try require(delivered.count == beforeBad && peer.operations.count == capped && peer.count("catalog") - beforeBadFull == 6, "Duplicate pages committed or retry budget was unbounded")
        peer.duplicate = false; peer.generation = "recovered"; sync.refresh(deviceID: peer.id); try await wait { delivered.last?.1.generation == "recovered" }
        sync.shutdown(); let afterShutdown = peer.operations.count; sync.reconcile([peer.demand()]); try require(peer.operations.count == afterShutdown, "Stopped sync started work")
        let stormPeer = CatalogPeer(); stormPeer.apps = Array(stormPeer.apps.prefix(3)); stormPeer.pause = true
        var stormDeliveries: [String] = []
        let storm = CompanionCatalogSync(request: stormPeer.request, deliver: { _, snapshot in stormDeliveries.append(snapshot.generation) }, report: { _, _ in })
        storm.reconcile([stormPeer.demand()]); try await wait { stormPeer.gate != nil }
        for _ in 0..<100 { stormPeer.token = UUID().uuidString.lowercased(); storm.reconcile([stormPeer.demand()]) }
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(stormPeer.count("catalog") == 1 && stormPeer.count("export_selection_get") == 1, "Catalog hints restarted or overlapped the blocked pass")
        stormPeer.generation = "storm-successor"; stormPeer.deltaItems = [["package_name": .string("dev.droidbridge.fixture.app0"), "label": .string("Newest storm app")]]
        stormPeer.gate?.resume(); stormPeer.gate = nil
        try await wait { stormDeliveries.last == "storm-successor" }
        try require(stormDeliveries == ["g1", "storm-successor"] && stormPeer.count("catalog") == 1 && stormPeer.count("catalog_changes") == 1, "Token storm did not finish exactly one newest successor")
        storm.shutdown()
        let visiblePeer = CatalogPeer(); visiblePeer.apps = Array(visiblePeer.apps.prefix(3)); visiblePeer.pause = true
        var stillVisible = true, hiddenDeliveries = 0
        let dynamicVisibility = CompanionCatalogSync(request: visiblePeer.request, deliver: { _, _ in hiddenDeliveries += 1 }, report: { _, _ in }, isVisible: { _ in stillVisible })
        dynamicVisibility.reconcile([visiblePeer.demand()]); try await wait { visiblePeer.gate != nil }
        stillVisible = false; visiblePeer.gate?.resume(); visiblePeer.gate = nil
        try await Task.sleep(nanoseconds: 30_000_000); let noVisibleOps = visiblePeer.operations.count
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(hiddenDeliveries == 0 && visiblePeer.operations.count == noVisibleOps, "Visibility loss without another poll caused a successor loop")
        dynamicVisibility.shutdown()

        let report: [String: Any] = ["passed": true, "scope": "Shipping catalog engine with deterministic peer; no installed/device acceptance", "full_1000_pages": 16, "shared_visible_consumers": 2, "initial_progress_first": progress.first!, "automatic_delta": true, "blocked_pass_100_token_storm_one_successor": true, "unchanged_token_http_reads": 0, "stale_fallback": true, "hidden_and_repair_late_response_fenced": true, "duplicate_pages_rejected": true, "retry_attempts_max": 3, "explicit_retry_recovered": true, "operations": peer.operations]
        let path = CommandLine.arguments.dropFirst().first ?? ".build/catalog-sync-fixture.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path)); print("PASS: shared bounded catalog synchronization and lifecycle fences")
    }
}
