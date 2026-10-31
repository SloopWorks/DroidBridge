# Source-built ADB runtime

DroidBridge's public-release runtime uses an arm64 source build of Android-tools
37.0.0. The Google SDK remains a development tool for Android builds. The runtime
recipe never starts a server, enumerates devices, or modifies ADB keys.

Run `scripts/build-adb-runtime.sh` on arm64 macOS26 with Xcode command-line tools,
Python3.12 or later, CMake, Ninja and pkg-config. Homebrew supplies dynamic libusb,
Brotli, LZ4 and Zstandard plus the configure-time PCRE2 dependency. Source inputs
for Android-tools, Protobuf36.2, Abseil20260817.0 and Googletest1.18.0 are pinned by
URL and SHA256 in the recipe. Googletest supplies only the test-friend header
required by an upstream production header; its test libraries are not linked.

The recipe uses Android-tools' already patched release source archive and then
applies three retained build patches: BoringSSL header precedence and an explicit
test-friend include; correct compression/libusb include dependencies; Android
logging macro compatibility with contemporary Protobuf/Abseil headers. The
vendored BoringSSL and fmt, plus separately source-built Protobuf and Abseil, are
static permissive dependencies. **libusb stays dynamically linked.** The release
source archive contains exact dependency inputs, recipes, patches and notices;
retaining notices alone is not the public distribution acceptance gate.

The output `.build/adb-runtime/` contains:

- `adb`, six signed `adb-lib*.dylib` siblings and `adb-runtime.json`.
- `BUILD_PROVENANCE.json`: source URLs/hashes, patch and recipe hashes, static and
  dynamic dependency inventory, architecture, deployment target and tool versions.
- `dependency-origins.json`: each copied dylib's exact Homebrew Cellar origin.
- `sources/`: all four exact source archives, patches and build recipes.
- `notices/`: Android-tools/AOSP, BoringSSL, fmt, Protobuf, Abseil and header notices.

No source-built binary or downloaded archive is committed to Git. Release tooling
validates and packages these generated inputs with the release artifacts. A clean
build plus cached repeat has been executed; byte-identical output across different
Xcode versions or absolute build paths is not promised.

## Portable runtime contract

The JSON manifest has version1 and a `files` array. Each item has a flat `name`,
positive byte `size` and lowercase64-hex `sha256`. `adb` occurs exactly once; all
other names match `adb-lib[A-Za-z0-9_.-]+.dylib`. There are at most15 entries,
64MiB per file and128MiB for the whole cohort including the manifest. The manifest
itself is bounded to16KiB. Files are regular, single-link, owned by the installer
or root at the source, with no group/world write access. Installed copies must
belong to the current user. Every Mach-O is strictly signature-verified.

Only system dependencies and exact listed `@loader_path/<sibling>` references are
allowed. Ambient `@rpath`, absolute Homebrew paths and path traversal are refused.
The supported arm64 slice is inspected explicitly, including legacy universal
SDK binaries. A missing manifest allows only a historical standalone ADB with
system dependencies. It cannot make a dynamic binary silently standalone.

`ADBPortableRuntime` is the shared inventory, copy and load-closure verifier.
Availability and companion broker installers copy the exact signed cohort
without relinking. Their generation hashes bind every file, including the
manifest. Legacy two-file generation identities remain unchanged. Availability
staging/retirement receipts include every extra file, preserving crash recovery,
partial-copy proof, running-process fencing and the eight-generation bound.
Broker generations use a checked external lifetime lease plus exact mapped-file
checks before and after retirement rename. Unknown entries count toward capacity.

Packaging must not re-sign or rewrite the cohort after its manifest is generated.
Changing a library requires regenerating the manifest and signing the resulting
cohort/application. The hashes prevent accidentally mixing releases; they are not
a prohibition on rebuilding or replacing libusb. For a modified libusb build,
install that compatible library in the build dependency prefix and rerun the
provided recipe, then package/re-sign your locally modified application. Preserve
the relevant notices and corresponding sources when redistributing changes.

## Evidence and limits

`verification/companion/core/portable-runtime-tests.log` includes actual signed
dylib/client relocation, universal legacy architecture handling, missing/absolute
dependency refusals, tampering, symlinks, and portable crash-recovery tests.
`installed-availability-migration.json` covers the actual isolated eight-generation
LaunchAgent upgrade with signed fake ADB binaries; it does not test Android.

`adb-source-isolated-runtime.json` records actual API35 emulator transport through
the first source build on owned server5038, with USB/mDNS/emulator scanning
disabled. Only emulator5580 was explicitly connected. Shell, push/hash/pull and
owned forward cleanup passed; the owned server was stopped and port closed.
The final packaged cohort still goes through installed product acceptance.

`adb-portable-performance.json` records20 offline `version` process invocations
with PATH restricted to system directories. The final portable cohort is8.91MB;
its six dylibs total1.92MB. On this host the subsequent19 invocations had median
7.91ms and p95 11.29ms. The first invocation was9.58ms. OS caches were not flushed,
so this is not evidence of a fresh-boot cold-cache latency.
