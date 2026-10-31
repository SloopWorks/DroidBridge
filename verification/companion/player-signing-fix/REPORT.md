# Nested Player signing repair — offline verification

The QA11 nested Player was rejected independently: both `Player.app` and its `Contents/MacOS/scrcpy` failed `codesign --verify --strict` with `invalid destination for symbolic link in bundle`. Its `Contents/lib -> ../../lib` link escaped the nested signing boundary. The existing outer deep verification did not detect that failure. Original outputs are preserved in `qa11-bundle-failed.log` and `qa11-executable-failed.log`.

## Implemented boundary

`scripts/package.sh` now copies the actual transitive scrcpy dependency closure into a real `Player.app/Contents/lib`, writes a signed resource inventory and signs the nested Player afterward. Existing loader commands and copied dylib bytes/signatures remain unchanged. Assembly fails closed above 64 libraries or 256 MiB; these are new explicit assembly bounds, not relaxed existing payload limits. Count, stat-size and cumulative-byte admission precede staging hashes/copies and inventory hashes. Digests stream in 1 MiB chunks. Portable ADB files and their signing cohort are untouched.

`scripts/verify-package.py` independently verifies each Mach-O strict signature, resolves active local loader/executable/rpath dependencies inside its jail, and independently verifies the nested Player. Player's executable and libraries use the narrower Player jail. Unresolved, external, ambiguous or escaping non-system dependencies fail closed. The exact inventory includes each duplicate filename, source, size and SHA-256. A reachability check rejects extra unrelated Mach-O code. Apple dyld-cache system paths remain permitted. The pinned closure uses loader-relative references; staging refuses unsupported relocation tokens rather than rewriting signed code. When an @rpath dependency is active, every search entry must be supported and jailed; external entries fail even when a later local candidate exists. System exceptions require canonical paths and reject prefix traversal.

The packaging script executes these signature/dependency gates before publishing. `--player-only` and `--signatures-only` are offline validation modes and execute no bundled binaries; the existing full validator retains version and APK/notice checks.

## Executed proof

Private fixture: `.build/player-signing-proof`, derived from the installed QA11 bundle. Installed QA11 and dist were not modified. No application, UI, ADB, emulator, phone, broker or runtime binary was launched. System `codesign`, `otool`, `install_name_tool` and Python operated on private copies only.

- Fixed nested Player: strict bundle, executable and all 17 libraries pass.
- Full copied application: outer deep/strict plus **48 independent Mach-O strict signature checks** pass. Previous cohort had 31; 17 copied libraries account for the increase.
- Every copied library SHA matches its original `Runtime/lib` file.
- Seven negative regression fixtures reject the original escaping directory link, missing required library, modified signed code, external rpath, an executable-relative dependency escaping Player, an external-first/local-later rpath chain, and system-prefix traversal. Mutation fixtures were re-signed at their bundle boundary where applicable so the checks exercise more than an obsolete outer seal.
- Two focused cap regressions refuse a sparse 268,435,457-byte library before any digest call: staging records zero hash calls and zero copies; an isolated inventory unit test stubs already-separately-tested signature operations and records zero hash calls. The seven signed negative cases and full 48-code-file verification were rerun afterward.
- `python3 -m py_compile scripts/verify-package.py`, `bash -n scripts/package.sh`, and `git diff --check` pass.

Machine-readable evidence: `assembly.json`, `player-fixed.json`, `all-macho-fixed.json`, `regression-results.json`, and individual negative logs. `offline-regression.py` records the executed offline regression commands. It expects the initial repaired private fixture; repeat whole assembly from the production staging command first when preparing a new directory. Initial fixture preparation encountered a source-vs-nested executable signature mismatch and read-only copied executable mode; these private setup errors were corrected by reproducing production's Runtime/bin/scrcpy copy step, without changing any product code to accept them.

## Payload and wrapper effects

The 17 identical copied dylibs add **37,129,056 logical bytes (35.41 MiB)**. Comparable private ZIP-deflate9 fixtures containing Runtime/lib plus old/new Player measure 16,103,152 versus 32,027,375 bytes: **15,924,223 bytes (15.19 MiB)** additional compressed payload, including inventory/signature differences. These are fixture measurements, not final DMG/ZIP measurements; root must measure rebuilt candidate12.

ManagedAppCloneCopy already copies the entire Runtime and wrappers already update/sign the nested Player; no path, launch API or wrapper changes are needed. APFS clone copies may share extents; fallback copies on other filesystems incur the added logical bytes. No startup, resident-memory or CPU improvement is claimed. Existing dependency notices cover these unchanged duplicate library bytes; no upstream component/version changed. Each generated wrapper carries the same additional logical closure and inventory.

## Remaining release gates

Independent Security review, root's fresh candidate12 build and final artifact validation/size measurements remain required. An actual fallback/wrapper launch smoke is still required after the Mac is unlocked; offline codesign checks are not evidence of rendered video or successful UI launch. This report does not close whole-program acceptance or Gatekeeper/notarization requirements.
