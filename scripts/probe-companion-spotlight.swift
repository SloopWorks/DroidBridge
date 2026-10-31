/// Isolated synthetic CoreSpotlight diagnostic. Not a production fallback or
/// evidence of launching an Android wrapper from the Spotlight UI.
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

@main struct ProbeCompanionSpotlight {
    static func main() async throws {
        guard CommandLine.arguments.count == 2, Bundle.main.bundleIdentifier?.hasPrefix("dev.droidbridge.qa.spotlight.") == true else { throw NSError(domain: "Distinct QA application bundle required", code: 1) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw NSError(domain: "Fresh evidence required", code: 2) }
        let identity = UUID().uuidString.lowercased(), name = "DroidBridgeQA-" + identity
        let index = CSSearchableIndex(name: name)
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "DroidBridge synthetic Spotlight probe " + identity
        attributes.contentDescription = "Disposable test item; no received or personal content."
        let item = CSSearchableItem(uniqueIdentifier: identity, domainIdentifier: name, attributeSet: attributes)
        item.expirationDate = Date().addingTimeInterval(120)
        var result: [String: Any] = ["scope": "Distinct temporary QA app and named CoreSpotlight index; no production index or wrapper launch; synthetic item expires in120s", "bundle_id": Bundle.main.bundleIdentifier!, "index_name": name, "indexing_available": CSSearchableIndex.isIndexingAvailable(), "spotlight_ui_launch_verified": false]
        do {
            try await index.indexSearchableItems([item]); result["index_request_succeeded"] = true
            let context = CSSearchQueryContext(); context.fetchAttributes = ["title"]
            let query = CSSearchQuery(queryString: "title == '\(attributes.title!)'", queryContext: context)
            let matches = ProbeMatches()
            query.foundItemsHandler = { items in matches.add(items.filter { $0.uniqueIdentifier == identity }.count) }
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    query.completionHandler = { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
                    query.start(); DispatchQueue.global().asyncAfter(deadline: .now() + 8) { query.cancel() }
                }
                result["query_error"] = NSNull()
            } catch { result["query_error"] = error.localizedDescription }
            result["query_matched_own_item"] = matches.count > 0
        } catch { result["index_request_succeeded"] = false; result["index_error"] = error.localizedDescription }
        do { try await index.deleteSearchableItems(withIdentifiers: [identity]); result["exact_item_cleanup_confirmed"] = true }
        catch { result["exact_item_cleanup_confirmed"] = false; result["cleanup_error"] = error.localizedDescription }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Temporary CoreSpotlight diagnostic completed; no product acceptance claim.")
    }
}
private final class ProbeMatches: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func add(_ count: Int) { lock.lock(); value += count; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
