#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
clang -dynamiclib -Wall -Wextra -I/opt/homebrew/include -undefined dynamic_lookup verification/desktop-mode/desktop-sdl.c -o .build/desktop-sdl.dylib
codesign --force --sign - .build/desktop-sdl.dylib
DROIDBRIDGE_TEST_SERIAL=${DROIDBRIDGE_TEST_SERIAL:-emulator-5580} python3 verification/desktop-mode/verify-external.py
