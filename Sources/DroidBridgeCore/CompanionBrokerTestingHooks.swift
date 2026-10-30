#if DEBUG
import Foundation
/// Internal deterministic scheduling and fault seams. No argv/environment hook;
/// release builds contain neither this type nor the test forward case. TLS pin,
/// installation identity and all secret/credential guards remain unchanged.
struct CompanionBrokerTestingHooks: Sendable {
    let endpoint: (@Sendable (String) async throws -> URL)?
    let qaAdditionalSerials:Set<String>
    let checkpoint: @Sendable (String,String) async throws -> Void
    let fault: @Sendable (String) throws -> Void
    init(endpoint:(@Sendable(String)async throws->URL)? = nil,qaAdditionalSerials:Set<String> = [],checkpoint:@escaping @Sendable(String,String)async throws->Void={_,_ in},fault:@escaping @Sendable(String)throws->Void={_ in}) {self.endpoint=endpoint;self.qaAdditionalSerials=qaAdditionalSerials;self.checkpoint=checkpoint;self.fault=fault}
}
#endif
