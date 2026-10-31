# Installed build 8 — fresh scoped acceptance checkpoint

This checkpoint uses the independently inventory/signature-validated installed
`~/Applications/DroidBridge Companion QA8.app`, Android11 candidate2, and the
fresh mode700 `DroidBridge Companion Final QA Data` scope. It does not use the
production catalog, physical Pixel, or emulator5554. Runtime is emulator5582.
Hashes are recorded in `installed-identity.json`; parent package verification
binds the installed copy to the read-only DMG.

| Flow | Actual result | Evidence |
|---|---|---|
| First fresh host registration | Pass; registered before any Retry action | fresh-first-host-registration.json |
| First pinned pairing | Pass; actual phone QR/full URI, comparison and approval | actual-first-pairing.json |
| Phone Open after first main quit | Pass; validated installed host bootstrapped and created native display45 | fresh-first-bootstrap-receipt.json |
| Native input after phone bootstrap | Pass; real CUA keys `n8`, one tap, two key downs | first-bootstrap-input-raw.xml |
| Native Wi-Fi Pair/Connect | Pass; shipping native controls used real Android adbd TLS through exact emulator NAT mappings | wireless-native-gui-developer-setup/result.json |
| Changed Wi-Fi debugging endpoint | Pass; Android issued a different endpoint; native Connect reached the same owned emulator | same report |
| Wireless cleanup | Corrected and independently read verified after asynchronous toggle read initially failed | wireless-native-gui-developer-setup/cleanup-confirmed.json |
| Notification scope v2 | Pass via exact public broker request and phone opt-in; Mac Apply hit Denied-throws bug below | notification-scope-v2-actual.json |
| Real RemoteInput reply | Pass; actual CUA Reply/Send Reply; fixture delivery counter1→2 | same report plus tool action receipts |
| Public update/private replacement | Pass; action generation changed; private replacement removed old public row | same report |
| Stale reply refusal | Pass; notification_unavailable, delivery counter remained2 | same report |
| Actual CUA Dismiss | Pass; in-app row and Android active notification removed | notification-scope-v2-dismiss.json |
| Native macOS notification banners | Unverified; read-only permission check returned Denied, respected without reset | status text in notification evidence |
| Two fallback windows | Running concurrently on Android displays46/47; independent keyboard echo `s8`/`b8` | fallback-alpha-input.xml, fallback-beta-input.xml |
| Fallback pointer input after text focus | Fail; button taps remained0 despite actual supported `--no-mouse-hover` argv | same XML; Android specialist investigating transition |

The first two wireless attempts could not enter Developer Options because the
owned emulator's `development_settings_enabled` baseline was null. Normal
Settings launched. The third attempt temporarily enabled that development-only
setting, performed the real native Pair/Connect operations, and restored null.
The initial cleanup report retains `passed:false` because it read the wireless
setting before the GUI toggle settled. Supplemental cleanup explicitly restored
and read verified wireless-debug0, adb1 and developer-null, and verified no NAT
redirections/owned wireless aliases remain. This proves emulator TLS/UI behavior,
not physical LAN coverage.

Actual macOS `requestAuthorization` threw “Notifications are not allowed for
this application” while authorizationStatus was Denied. Build8 therefore failed
to reach the phone-preference RPC through normal Mac Apply. Candidate9 adds a
read-only Denied-status fallback with cancellation/intent/trust/filter/window
fences; source/component proof and actual installed candidate9 smoke remain
separate from this checkpoint. No OS permission was reset or bypassed.

Source inspection also confirmed that build8 required manual catalog Refresh.
Candidate9 introduces shared visible-window token/delta synchronization. No
automatic package-change pass is claimed for build8.

All video windows were red-closed before explicit runtime handoff to the Android
specialist. Main3941 and paired scoped broker89717 were retained; only the
companion forward tcp46000→37841 remained. Older QA trust/settings scopes were
preserved. Text/XML/JSON evidence was scanned for full pairing URIs, bearer
credentials and serialized pairing secrets; none were found. Enrollment QR and
link material remained private and was removed by the pairing helper.
