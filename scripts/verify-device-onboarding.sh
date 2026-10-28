#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=$(swift build --show-bin-path)
swiftc -parse-as-library -I "$BIN/Modules" Sources/DroidBridge/DeviceOnboarding.swift Sources/DroidBridge/DeviceOnboardingAgent.swift Sources/DroidBridge/MacAppWrapper.swift scripts/verify-device-onboarding.swift "$BIN"/DroidBridgeCore.build/*.o -o .build/verify-device-onboarding
swiftc -parse-as-library -I "$BIN/Modules" scripts/verify-managed-availability.swift "$BIN"/DroidBridgeCore.build/*.o -o .build/verify-managed-availability
.build/verify-device-onboarding 2>&1 | tee verification/onboarding/cohort.log
