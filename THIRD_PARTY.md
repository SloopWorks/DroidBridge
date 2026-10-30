# Dependencies and distribution

DroidBridge is an original Swift/AppKit application. Android runs applications on the attached device; no APK translation is provided.

| Component | Tested version | License / upstream |
|---|---|---|
| scrcpy client/server | 5.0.1, commit a60891a | Apache-2.0, https://github.com/Genymobile/scrcpy/tree/v5.0.1 |
| Android SDK platform-tools / ADB | 37.0.0 | Android SDK license and Android Open Source Project notices included with SDK |
| FFmpeg (external scrcpy dependency) | Homebrew 9.0.2_1 | GPL-3.0-or-later enabled build, https://ffmpeg.org/legal.html |
| SDL3 | 3.4.18 | zlib, https://github.com/libsdl-org/SDL |
| libusb | 1.0.30 | LGPL-2.1-or-later, https://libusb.info/ |
| VideoToolbox, CoreMedia, AppKit | macOS system | Apple system frameworks, not redistributed |

The packaging script recursively discovers additional Mach-O dependencies. Its generated dependency manifest and bundled license files are authoritative for the exact artifact. FFmpeg's Homebrew build includes GPL codecs (x264/x265); upstream scrcpy's Apache license does not remove those obligations. A separate executable boundary keeps these dependencies out of the native Swift renderer, but does not remove the obligations of distributing their binaries.

For public binary redistribution, preserve notices, retain license texts, provide the exact corresponding source and build configuration/patches where required, and review Android SDK redistribution terms. This repository delivers a local installable artifact, not a legal assertion that a public download is ready. Native rendering uses Apple VideoToolbox and the Apache-licensed scrcpy server, without linking FFmpeg into the Swift application.

DroidBridgeAudioClient is a separately compiled, modified scrcpy5.0.1 client.
Its five modified upstream files carry a modification notice. The exact source
commit and tracked patch are bound by `scripts/build-audio-client.sh`; the patch,
Apache-2.0 text and modification notice are included in the app bundle under
`licenses/droidbridge-audio-client`. It shares the bundled SDL/FFmpeg runtime and
its corresponding redistribution obligations. The upstream video Player is
unmodified by the audio client patch.
