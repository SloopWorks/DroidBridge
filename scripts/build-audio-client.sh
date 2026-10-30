#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PIN=a60891aea193d92e7e5c3942700eca63f9d19a5f
CACHE="$ROOT/Vendor/scrcpy"
OUT="$ROOT/.build/audio-client"
export PATH="/opt/homebrew/bin:$PATH"
for tool in git meson ninja pkg-config; do
  command -v "$tool" >/dev/null || { echo "Missing $tool; run brew install meson ninja pkg-config" >&2; exit 1; }
done
if [ ! -d "$CACHE/.git" ]; then
  mkdir -p "$ROOT/Vendor"
  git clone --depth 1 --branch v5.0.1 https://github.com/Genymobile/scrcpy.git "$CACHE"
fi
[ "$(git -C "$CACHE" rev-parse v5.0.1^{commit})" = "$PIN" ] || { echo 'Unexpected scrcpy tag identity' >&2; exit 1; }
mkdir -p "$OUT"
STAMP=$(shasum -a 256 "$ROOT/scripts/patches/audio-output-ready.patch" | cut -d ' ' -f 1)
if [ ! -f "$OUT/source-stamp" ] || [ "$(cat "$OUT/source-stamp")" != "$PIN:$STAMP" ]; then
  if [ -d "$OUT/source" ]; then mv "$OUT/source" "$OUT/source.previous.$(date +%s)"; fi
  if [ -d "$OUT/build" ]; then mv "$OUT/build" "$OUT/build.previous.$(date +%s)"; fi
  mkdir -p "$OUT/source"
  git -C "$CACHE" archive "$PIN" | tar -x -C "$OUT/source"
  (cd "$OUT/source" && patch -p1 < "$ROOT/scripts/patches/audio-output-ready.patch")
  printf '%s\n' "$PIN:$STAMP" > "$OUT/source-stamp"
fi
if [ ! -f "$OUT/build/build.ninja" ]; then
  meson setup "$OUT/build" "$OUT/source" --buildtype=release -Dcompile_server=false -Dusb=false
fi
meson compile -C "$OUT/build"
cp "$OUT/build/app/scrcpy" "$OUT/DroidBridgeAudioClient"
"$OUT/DroidBridgeAudioClient" --version
printf 'Pinned source %s; audio readiness patch %s\n' "$PIN" "$STAMP"
