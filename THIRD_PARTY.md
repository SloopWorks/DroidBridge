# Dependencies and distribution

DroidBridge is an original Swift/AppKit application. Android runs applications on the attached device; no APK translation is provided.

| Component | Tested version | License / upstream |
|---|---|---|
| scrcpy client/server | 5.0.1, commit a60891a | Apache-2.0, https://github.com/Genymobile/scrcpy/tree/v5.0.1 |
| Source-built AOSP ADB through android-tools | 37.0.0 | Apache-2.0; exact AOSP/BoringSSL/fmt source and notices in the pinned android-tools archive |
| Static protobuf / Abseil | 36.2 / 20260817.0 | BSD-3-Clause / Apache-2.0; exact source archives and build flags retained |
| FFmpeg (external scrcpy dependency) | Homebrew 9.0.2_1 | GPL-3.0-or-later enabled build, https://ffmpeg.org/legal.html |
| SDL3 | 3.4.18 | zlib, https://github.com/libsdl-org/SDL |
| libusb | 1.0.30 | LGPL-2.1-or-later, https://libusb.info/ |
| VideoToolbox, CoreMedia, AppKit | macOS system | Apple system frameworks, not redistributed |

The packaging script recursively discovers additional Mach-O dependencies. Its generated dependency manifest and bundled license files are authoritative for the exact artifact. FFmpeg's Homebrew build includes GPL codecs (x264/x265); upstream scrcpy's Apache license does not remove those obligations. A separate executable boundary keeps these dependencies out of the native Swift renderer, but does not remove the obligations of distributing their binaries.

For public binary redistribution, preserve notices, retain license texts, provide the exact corresponding source and build configuration/patches where required, and bind every binary to its actual source/build inputs. This repository delivers a local installable artifact, not a legal assertion that a public download is ready. Native rendering uses Apple VideoToolbox and the Apache-licensed scrcpy server, without linking FFmpeg into the Swift application.

DroidBridgeAudioClient is a separately compiled, modified scrcpy5.0.1 client.
Its five modified upstream files carry a modification notice. The exact source
commit and tracked patch are bound by `scripts/build-audio-client.sh`; the patch,
Apache-2.0 text and modification notice are included in the app bundle under
`licenses/droidbridge-audio-client`. It shares the bundled SDL/FFmpeg runtime and
its corresponding redistribution obligations. The upstream video Player is
unmodified by the audio client patch.


The companion APK additionally includes ZXing core3.5.3, Kotlin standard
library2.3.21 and IntelliJ annotations13.0, under Apache License2.0. Its offline
Settings license viewer retains the license and upstream notices. Exact texts,
source URLs and hashes are in `AndroidCompanion/app/src/main/assets/licenses`;
packaging copies those bytes from the bundled APK into
`Contents/Resources/licenses/android-companion`. The Android framework and
instrumentation dependencies are not redistributed as APK runtime libraries.
The actual Gradle release runtime dependency report is retained under
`verification/companion/android/release-runtime-dependencies.txt`.


The 0.2.0 packaging default builds ADB from pinned android-tools37 source, rather
than copying Google's SDK executable. Vendored BoringSSL/fmt and pinned
protobuf/Abseil are linked into ADB; libusb and six total compression/USB dylibs
remain dynamically linked. `scripts/build-adb-runtime.sh` emits a signed flat
runtime inventory, exact source/archive/patch/recipe provenance and notices.
Private broker and availability generations retain the entire verified cohort,
including the independently replaceable libusb library.

`Contents/Resources/licenses/adb-source-runtime` retains those upstream texts and
BUILD_PROVENANCE.json. The source release script requires all four exact source
archives, three patches and both build recipes, compares recipe bytes against
the committed candidate and binds the same runtime manifest/provenance present
in the packaged app. Historical SDK notices retained in the repository do not
mean the SDK ADB binary is part of this new default cohort. A developer ADB_PATH
override is not evidence that corresponding-source review passed.
