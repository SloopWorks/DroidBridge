# Persistent companion broker: callable IPC contract

Implementation: `CompanionBrokerIPCClient`, `CompanionBrokerService`,
`CompanionBrokerRegistry`, `CompanionBrokerInstaller` in Core; executable
`DroidBridgeCompanionBroker`. This service is separate from Spotlight onboarding.
It runs without AppKit and is the only phone HTTP and Keychain owner.

```swift
try await CompanionBrokerInstaller.ensureInstalled(executable: brokerURL, adb: bundledADBURL)
let broker = CompanionBrokerIPCClient()
let reply = try await broker.request(operation: "status")
// reply.data is [String: CompanionJSON], requestID UUID is correlated.
```

Calls are Codable JSON `Data` over public NSXPC MachServices. Both sides cap bytes
at 262144; dictionaries below use literal snake_case keys. Success reply contains
`requestID`, `status`, `data`, no credentials. Errors throw CompanionBoundaryError
with stable code and bounded message. Retrying a mutating call must retain its
requestID and identical payload; conflicting identities fail closed. The receiver
checks the connection's effective UID and kernel process-start identity plus an
owned mode600 random IPC nonce in a mode700 directory. This is a per-user trust
boundary, not isolation from malicious software already running as that user.

## Operations

| Operation | Payload | Reply data |
|---|---|---|
| host_register | app_path (main host only) | registered after exact kernel process path, strict signature and executable hash verification |
| status | none | devices[], sessions[], broker_version |
| connect / retry | serial | device_id, paired, hello |
| disconnect | device_id | status |
| begin_pair | serial, secret, expected_device_id, server_pin (all required) | pairing_id, status, device_id, comparison_code, mac_name, expires_at |
| poll_pair | pairing_id | pairing_id, status, device_id (credential never returned) |
| trust_list | device_id | items[] |
| revoke | device_id, trust_id | status |
| catalog | device_id, cursor optional | generation, items[], next_cursor |
| catalog_changes | device_id, after | generation, items[], deleted[] |
| icon | device_id, hash, offset optional | bytes (base64 <=64KiB decoded), total_bytes, next_offset; IPCClient.icon assembles and verifies <=256KiB PNG |
| export_selection_get | device_id | selection {package:Bool} |
| export_selection_set | device_id, package_name, selected | status accepted; actual wrapper result arrives through owner acknowledgement |
| profile_get / profile_set | device_id, profile for set | profile, status |
| command_status | device_id,request_id | request_id,status accepted/applied/rejected,result (accepted is not completion) |
| diagnostics | device_id | bounded remote counters/permissions/status |
| inbox_list | device_id,after_id optional | items[] max16/176KiB, next_cursor (pass as after_id); each id,device_id,kind,created,payload |
| inbox_clear | device_id, item_id optional | status |
| clipboard_send | device_id, payload {text} | command receipt |
| share_send | device_id, kind share_text/share_url, payload {text} | command receipt |
| notification_reply | device_id,payload {notification_key,action_id,text} | command receipt |
| notification_dismiss | device_id,payload {notification_key,action_id} | command receipt |
| notification_preferences | device_id,payload {enabled,...} | command receipt |
| command | device_id,kind,payload | typed allowed remote Android command receipt |
| host_command | device_id,kind,payload | typed Mac owner action; includes stop_all aggregated across exact session owners |
| transfer_begin | device_id,transfer_id,direction,display_name,mime_type,size,sha256 | bounded transfer status |
| transfer_chunk | device_id,transfer_id,index,bytes base64 <=65536 decoded | transfer status |
| transfer_download | device_id,transfer_id,index | bytes base64 <=65536 decoded |
| transfer_receipt | device_id,transfer_id,accepted_bytes,sha256,status downloaded | verified whole-file completion receipt; call only after local atomic save + full hash/length verification |
| transfer_status/transfer_commit/transfer_cancel | device_id,transfer_id | status |
| delivery | device_id | official release_url, installation explanation |
| cancel | request_id | cancellation_requested |

The current local IPC chunk representation uses base64 (at most87384 bytes for a
64KiB chunk); remote HTTP uses raw bytes. At most two bulk requests, one short
control request and one separate event long-poll per selected phone are allowed.
Control waiters take priority over queued bulk requests. Downloaded files are
never automatically opened or executed. Mac UI chooses destination and verifies
full hash/length before presenting a received file. Received text stays in the
private bounded inbox until the user explicitly copies/saves it.

## Independent host registration and commands

`session_publish`: device_id, explicit verified serial, role launcher|wrapper,
generation positive Int64 and sessions[] (at most32 per phone globally). A session
contains session_id UUID, package_name, label, backend native|scrcpy, phase
starting|running|reconnecting|stopping|stopped|failed. PID and process-start time
come from NSXPC, not payload. Generation must never decrease for a live process.
The launcher must register an empty sessions array too, so it can receive Open.
Registration is asynchronous and cannot block video/wrapper startup. Optional audio_status is {route mac|phone|mac_and_phone, phase phone|starting|ready|shared|failed|unavailable,message <=512 characters}; it is bound to that owner/generation, expires after10seconds and never substitutes a saved preference for actual output readiness.

`command_poll`: generation -> commands[] (at most16), each id, device_id, kind,
payload, owner, generation, expires, status. Call while alive every500ms; stop
on shutdown. Commands are assigned to exact owner generation, expire within
30seconds, and persist before event-cursor advancement. Hosts must keep bounded
request receipts and never rerun an applied/unknown request after restart.

`command_ack`: command_id,generation,status applied|rejected,result -> status.
A dead or superseded owner cannot acknowledge or take another owner's command.
Dispatch through existing typed launch/readiness/audio/screen/profile/export
admission. Never interpret a command payload as a shell or accept another serial.
`open_app` requires a registered launcher. If it has quit, the broker starts only
the previously registered main application after revalidating its signature and
exact executable hash, using `/usr/bin/open` with fixed arguments and inherited
isolated QA scope. It waits at most20seconds for a live registered launcher before
delivering the typed command. An unregistered/changed host fails explicitly and
requires opening the installed application once. A phone never supplies a path. Stop selects the session's
exact owner; other device commands prefer the launcher then a registered wrapper.

## Identity and lifecycle

An unauthenticated hello only selects which Keychain item to try. Authenticated
`identity()` must prove the same installation ID and trust before an alias is
saved. Credentials never enter IPC/status/state files. USB and Wi-Fi aliases for
the same verified installation share one selected phone connection; switching
while any live session exists returns transport_in_use. Existing video stays
pinned, and companion failure never stops video. Reconnect uses capped jittered
2/4/8/16/30second backoff. Event cursor commits only after durable delivery or
rejection. On broker shutdown exact-owned forwards are released; abrupt-crash
recovery is delegated to CompanionForward's leased identity checks.

Installer generations are content-addressed over broker+ADB, bounded to four,
and protected by held shared flock leases. A generation still running is never
removed. Admission refuses rather than deleting a live generation. LaunchAgent
updates use a private stage and user-owned plist, and do not change the existing
Spotlight helper's cap or flag. Installer does not request root.

## Authoritative export revisions

Only an authenticated phone/trust binds the managed catalog's alias/selection
authority. Before changing a selection the broker requires verified policy-aware
availability helper authority through CoreAvailabilityAuthority. A legacy helper
cannot be allowed to restore wrappers under an older policy. Initial pairing is
independent of this gate; selection changes return availability_update_required
until the actual helper is updated and running.

Android set_export results, phone set_export commands and catalog_preferences
events contain selection_revision and original request_id. Broker reduces them
to identical {package_name,selected,selection_revision} owner payloads, applies the
per-package monotonic policy before wrapper mutation, reloads its cache from that
authority and deduplicates by the origin UUID. Older revisions receive an explicit
stale_selection receipt; equal conflicting choices fail closed. Local commands
never send acknowledgements to Android's unrelated phone-command receipt store.

## Security release blocker under review

ADB loopback forwarding alone does not authenticate the Android server app UID.
Another Android app could claim the fixed port while the companion is stopped.
The current initial HTTP identity/pairing flow must not ship until an independent
security review establishes and verifies server possession of the pairing/shared
secret before the Mac transmits a pairing secret or stored bearer. The isolated
interim APK/Mac integration is not public release acceptance.

## Recovery and current protocol additions

`status.data.pending_pairings` contains bounded metadata only:
`{device_id,serial,phase:staged|committed,expires:ReferenceDateDouble}`. It includes
approved first admissions that have not yet reached `devices[]`.

`recover_pairing {device_id}` is an explicit user action. It returns
`{status:approved,device_id}` after fresh pinned TLS candidate authentication and
admission finalization. It is never called automatically. `forget {device_id}`
returns `status:forgotten`, `cleanup_pending`, `needs_phone_revoke:true` and a
bounded explanation of retained settings/apps. It also accepts a pending-only
installation. A stale/expired candidate requires Forget plus fresh phone consent.

State heartbeat is capability-negotiated using `state_heartbeat`; old protocol1
peers receive full state. A heartbeat body contains only generated request_id and
`unchanged:true`. A409 `snapshot_required` causes a full snapshot retry. The
broker never tests an unknown peer optimistically with an empty state body.
