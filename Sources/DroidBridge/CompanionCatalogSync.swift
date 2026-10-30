import Foundation
import DroidBridgeCore

/// One host-owned catalog reader serves the visible launcher and companion UI.
/// Cached local broker status is the only poll; Android is read after an opaque
/// authenticated change token advances, or an explicit Refresh. No hidden UI or
/// immutable wrapper launch starts catalog traffic.
@MainActor final class CompanionCatalogSync {
    struct Demand {
        let phone: CompanionDesktopDevice
        let serial: String
        let consumer: String
        var origin: String { phone.id + ":" + (phone.trustID ?? "") }
    }
    struct Snapshot {
        let generation: String
        let apps: [CompanionApp]
        let selection: [String: Bool]
    }
    typealias Request = (String, [String: CompanionJSON]) async throws -> [String: CompanionJSON]
    private struct Entry {
        var snapshot: Snapshot?
        var token: String?
        var delivered = Set<String>()
        var task: Task<Void, Never>?
        var ticket = UUID()
        var needsFull = false
        var attempts = 0
        var retryAt: Double = 0
    }
    private let request: Request
    private let deliver: (Demand, Snapshot) -> Void
    private let report: (Demand, String) -> Void
    private let progress: (Demand, Snapshot) -> Void
    private let isVisible: (Demand) -> Bool
    private let now: () -> Double
    private var entries: [String: Entry] = [:]
    private var demands: [Demand] = []
    private var stopped = false
    init(request: @escaping Request, deliver: @escaping (Demand, Snapshot) -> Void, report: @escaping (Demand, String) -> Void, progress: @escaping (Demand, Snapshot) -> Void = { _, _ in }, isVisible: @escaping (Demand) -> Bool = { _ in true }, now: @escaping () -> Double = CompanionClock.nowMS) {
        self.request = request; self.deliver = deliver; self.report = report; self.progress = progress; self.isVisible = isVisible; self.now = now
    }
    func reconcile(_ values: [Demand]) {
        guard !stopped else { return }
        demands = Array(values.filter { $0.phone.connected && $0.phone.paired && $0.phone.trustID != nil && $0.phone.aliases.contains($0.serial) && isVisible($0) }.prefix(2))
        let active = Set(demands.map(\.origin))
        // Forget/re-pair can never reuse the former trust's catalog.
        let identities = Dictionary(grouping: demands, by: { $0.phone.id })
        for key in Array(entries.keys) where !active.contains(key) {
            entries[key]?.task?.cancel(); entries[key]?.task = nil; entries[key]?.ticket = UUID(); entries[key]?.delivered.removeAll(); entries[key]?.attempts = 0; entries[key]?.retryAt = 0
            if identities.keys.contains(where: { key.hasPrefix($0 + ":") }) { entries.removeValue(forKey: key) }
        }
        // At most two visible origins plus two recently hidden snapshots.
        if entries.count > 4 { for key in entries.keys.sorted() where !active.contains(key) { entries.removeValue(forKey: key); if entries.count <= 4 { break } } }
        for origin in active {
            guard let demand = demands.first(where: { $0.origin == origin }) else { continue }
            var entry = entries[origin] ?? Entry()
            entry.delivered.formIntersection(Set(demands.filter { $0.origin == origin }.map { $0.consumer + ":" + $0.serial }))
            let token = demand.phone.catalogChangeToken
            entries[origin] = entry
            if let snapshot = entry.snapshot {
                for demand in demands.filter({ $0.origin == origin }) where !(entries[origin]?.delivered.contains(demand.consumer + ":" + demand.serial) ?? true) {
                    entries[origin]?.delivered.insert(demand.consumer + ":" + demand.serial); deliver(demand, snapshot)
                }
            }
            if entry.snapshot == nil || entry.token != token || entry.needsFull { start(origin) }
        }
        if entries.count > 4 { for key in entries.keys.sorted() where !active.contains(key) { entries.removeValue(forKey: key); if entries.count <= 4 { break } } }
    }
    func refresh(deviceID: String) {
        for key in entries.keys where key.hasPrefix(deviceID + ":") {
            entries[key]?.task?.cancel(); entries[key]?.task = nil; entries[key]?.ticket = UUID()
            entries[key]?.needsFull = true; entries[key]?.attempts = 0; entries[key]?.retryAt = 0; entries[key]?.delivered.removeAll()
        }
        reconcile(demands)
    }
    private func current(_ origin: String, _ ticket: UUID) -> Bool {
        !stopped && !Task.isCancelled && entries[origin]?.ticket == ticket && demands.contains { $0.origin == origin && isVisible($0) }
    }
    private func start(_ origin: String) {
        guard var entry = entries[origin], entry.task == nil, entry.attempts < 3,
              now() >= entry.retryAt, let demand = demands.first(where: { $0.origin == origin }) else { return }
        for demand in demands.filter({ $0.origin == origin }) { report(demand, entry.snapshot == nil ? "Reading first app page…" : "Updating app catalog…") }
        let ticket = UUID(), token = demand.phone.catalogChangeToken, prior = entry.needsFull ? nil : entry.snapshot
        entry.ticket = ticket; entry.attempts += 1
        entry.task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.entries[origin]?.ticket == ticket {
                    self.entries[origin]?.task = nil
                    // A newer hint never cancels valid work. Only the captured
                    // token is settled; one successor reads the newest hint.
                    self.reconcile(self.demands)
                }
            }
            do {
                let selectionReply = try await self.request("export_selection_get", ["device_id": .string(demand.phone.id), "expected_trust_id": .string(demand.phone.trustID!)])
                guard self.current(origin, ticket) else { return }
                let selection = selectionReply["selection"]?.object?.compactMapValues(\.bool) ?? [:]
                let snapshot: Snapshot
                if let prior {
                    do {
                        let response = try await self.request("catalog_changes", ["device_id": .string(demand.phone.id), "expected_trust_id": .string(demand.phone.trustID!), "after": .string(prior.generation)])
                        guard self.current(origin, ticket) else { return }
                        let delta = try Self.decode(CompanionCatalogDelta.self, response)
                        guard delta.items.count + delta.deleted.count <= 64 else { throw CompanionBoundaryError("catalog_too_large", "The app delta exceeded its bound.") }
                        var map = Dictionary(uniqueKeysWithValues: prior.apps.map { ($0.packageName, $0) })
                        guard Set(delta.items.map(\.packageName)).count == delta.items.count, Set(delta.deleted).count == delta.deleted.count, Set(delta.items.map(\.packageName)).isDisjoint(with: Set(delta.deleted)) else { throw CompanionBoundaryError("invalid_catalog", "Duplicate app identities in catalog delta.") }
                        for package in delta.deleted { try AndroidDiscovery.validatePackage(package); map.removeValue(forKey: package) }
                        for app in delta.items { try Self.validate(app); map[app.packageName] = app }
                        snapshot = try Self.snapshot(generation: delta.generation, apps: Array(map.values), selection: selection)
                    } catch let error as CompanionBoundaryError where ["stale_cursor", "stale_catalog"].contains(error.code) {
                        guard self.current(origin, ticket) else { return }
                        snapshot = try await self.full(deviceID: demand.phone.id, trustID: demand.phone.trustID!, origin: origin, ticket: ticket, token: token, selection: selection)
                    }
                } else { snapshot = try await self.full(deviceID: demand.phone.id, trustID: demand.phone.trustID!, origin: origin, ticket: ticket, token: token, selection: selection) }
                guard self.current(origin, ticket) else { return }
                self.entries[origin]?.needsFull = false; self.entries[origin]?.snapshot = snapshot; self.entries[origin]?.token = token; self.entries[origin]?.attempts = 0; self.entries[origin]?.delivered.removeAll()
                for demand in self.demands.filter({ $0.origin == origin }) {
                    self.entries[origin]?.delivered.insert(demand.consumer + ":" + demand.serial); self.deliver(demand, snapshot)
                }
            } catch {
                guard self.current(origin, ticket) else { return }
                let attempts = self.entries[origin]?.attempts ?? 3
                self.entries[origin]?.retryAt = self.now() + Double(attempts * 1000)
                for demand in self.demands.filter({ $0.origin == origin }) { self.report(demand, String(error.localizedDescription.prefix(350)) + (attempts >= 3 ? " Choose Refresh Catalog to retry." : " Retrying catalog update…")) }
            }
        }
        entries[origin] = entry
    }
    private func full(deviceID: String, trustID: String, origin: String, ticket: UUID, token: String?, selection: [String: Bool]) async throws -> Snapshot {
        var cursor: String?, generation: String?, apps: [CompanionApp] = [], pages = 0
        repeat {
            var payload: [String: CompanionJSON] = ["device_id": .string(deviceID), "expected_trust_id": .string(trustID)]
            if let cursor { payload["cursor"] = .string(cursor) }
            guard current(origin, ticket) else { throw CancellationError() }
            let response = try await request("catalog", payload)
            guard current(origin, ticket) else { throw CancellationError() }
            let page = try Self.decode(CompanionCatalogPage.self, response)
            guard generation == nil || generation == page.generation else { throw CompanionBoundaryError("stale_catalog", "Apps changed during discovery.") }
            guard page.items.count <= 64, pages < 64, apps.count + page.items.count <= 4096 else { throw CompanionBoundaryError("catalog_too_large", "The app catalog exceeded its bound.") }
            generation = page.generation; apps += page.items; pages += 1; cursor = page.nextCursor
            let partial = try Self.snapshot(generation: page.generation, apps: apps, selection: selection)
            if cursor != nil, entries[origin]?.snapshot == nil { for demand in demands.filter({ $0.origin == origin }) { progress(demand, partial) } }
        } while cursor != nil
        return try Self.snapshot(generation: generation ?? "", apps: apps, selection: selection)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ data: [String: CompanionJSON]) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: JSONEncoder().encode(data))
    }
    private static func validate(_ app: CompanionApp) throws {
        try AndroidDiscovery.validatePackage(app.packageName)
        guard app.label.utf8.count <= 256, app.activityName?.utf8.count ?? 0 <= 512 else { throw CompanionBoundaryError("invalid_catalog", "Invalid app metadata.") }
    }
    private static func snapshot(generation: String, apps: [CompanionApp], selection: [String: Bool]) throws -> Snapshot {
        guard !generation.isEmpty, generation.utf8.count <= 256, apps.count <= 4096, Set(apps.map(\.packageName)).count == apps.count else { throw CompanionBoundaryError("invalid_catalog", "The app catalog contains invalid or duplicate identities.") }
        for app in apps { try validate(app) }
        return Snapshot(generation: generation, apps: apps.sorted { $0.packageName < $1.packageName }, selection: selection)
    }
    func shutdown() { stopped = true; for entry in entries.values { entry.task?.cancel() }; entries.removeAll(); demands.removeAll() }
}
