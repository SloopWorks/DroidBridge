# Native Mac companion component verification

Executed with `scripts/verify-companion-gui.sh` on 2026-10-30. The script compiles
the shipping AppKit source and uses an anonymous NSXPC fixture peer. It disables
ADB/scrcpy and never installs a LaunchAgent, touches a physical phone, reads the
Mac clipboard or changes managed app policy.

Observed component checks:

- Eight native surfaces are reachable through their real navigation controls.
- Each surface was captured at 900×760 and 700×570 content sizes.
- A paginated 1,000-app catalog populates the real NSTableView; local name search
  selects the expected one-row result without an HTTP request.
- A registered independent-wrapper session's Stop action calls broker-local
  `host_command`, then resolves `command_status`; it does not equate acceptance
  with completion. The fixture supplies the applied effect.
- A 160,123-byte file traverses the production 64-KiB chunk upload and download
  controller through real anonymous NSXPC. Received bytes and complete SHA-256
  match. The saved file is not opened.
- Pairing and wireless setup have reachable alternate actions, local invalid-
  input feedback and scroll containers at their minimum sizes. No camera or
  real wireless pairing was attempted by this fixture.

Visual inspection found transparent capture backgrounds and an unreadable native
tab-strip backing layer. The shipping composition now draws its AppKit background
and uses ordinary native navigation buttons. Updated narrow captures show all
eight readable navigation choices, app labels and unchanged icon-sized slots.

`results.json` binds the fixture's measured scope. These results do not prove an
installed app, live Android connection, actual pairing consent, real Spotlight
publication, notification delivery/replies, camera capture, physical focus or
performance budgets. Those remain installed two-platform release gates.
