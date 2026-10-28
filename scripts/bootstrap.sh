#!/bin/bash
set -euo pipefail
# Official Homebrew registry and Android SDK tools only. No destructive cleanup.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v swift >/dev/null || { echo 'Install Xcode command-line tools first.' >&2; exit 1; }
command -v brew >/dev/null || { echo 'Homebrew is required for the upstream scrcpy runtime.' >&2; exit 1; }
if ! command -v scrcpy >/dev/null; then HOMEBREW_NO_AUTO_UPDATE=1 brew install scrcpy; fi
scrcpy --version | head -1 | /usr/bin/grep -q 'scrcpy 5.0.1' || { echo 'The native protocol is pinned to scrcpy 5.0.1; do not substitute an untested server.' >&2; exit 1; }
if [ ! -d "$ROOT/Vendor/scrcpy" ]; then
  mkdir -p "$ROOT/Vendor"
  git clone --depth 1 --branch v5.0.1 https://github.com/Genymobile/scrcpy.git "$ROOT/Vendor/scrcpy"
fi
cd "$ROOT"
swift build
