#!/usr/bin/env python3
"""Read-only product audit and isolated Swift checks; no Android/device actions."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent

def snapshot():
    paths = [ROOT / "Package.swift"]
    for directory in ("Sources", "Tests", "scripts", "AndroidCompanion/app/src", "AndroidCompanion/app/build.gradle.kts"):
        path = ROOT / directory
        paths.extend([path] if path.is_file() else [p for p in path.rglob("*") if p.is_file()])
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}

before = snapshot()
(OUT / "source-hashes-before.json").write_text(json.dumps(before, indent=2) + "\n")
commands = [
    ["git", "status", "--short"],
    ["git", "rev-parse", "HEAD"],
    ["git", "log", "-5", "--oneline"],
    ["sw_vers"],
    ["swift", "--version"],
    ["rg", "--files", "Sources", "Tests", "scripts", "AndroidCompanion/app/src/main"],
    ["rg", "-n", "codesign|signing ==|currentVersion|LSMinimumSystemVersion|sign_adhoc|notary|targetSdk|minSdk|versionCode|applicationIdSuffix", "scripts/package.sh", "scripts/create-release-manifest.py", "Sources/DroidBridge/MacAppWrapper.swift", "Sources/DroidBridgeCore/CompanionReleaseMetadata.swift", "AndroidCompanion/app/build.gradle.kts"],
    ["git", "ls-files", "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", ".github"],
    ["swift", "build", "--scratch-path", str(ROOT / ".build/product-review-2026-11-03")],
    ["swift", "test", "--scratch-path", str(ROOT / ".build/product-review-2026-11-03")],
]
environment = {k: v for k, v in os.environ.items() if not k.startswith("DROIDBRIDGE_")}
results = []
for index, argv in enumerate(commands):
    operation = argv[1] if len(argv) > 1 else "info"
    log = OUT / f"{index:02d}-{Path(argv[0]).name}-{operation}.log"
    start = datetime.datetime.now(datetime.timezone.utc)
    print(f"Running {shlex.join(argv)} -> {log.name}", flush=True)
    with log.open("w") as stream:
        stream.write(f"UTC: {start.isoformat()}\nCWD: {ROOT}\nCOMMAND: {shlex.join(argv)}\n\n")
        stream.flush()
        result = subprocess.run(argv, cwd=ROOT, env=environment, stdout=stream, stderr=subprocess.STDOUT)
        stream.write(f"\nEXIT CODE: {result.returncode}\n")
    results.append({"argv": argv, "exit_code": result.returncode, "log": log.name, "started_at": start.isoformat()})
    print(f"Exit {result.returncode}", flush=True)
after = snapshot()
(OUT / "source-hashes-after.json").write_text(json.dumps(after, indent=2) + "\n")
changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
summary = {"commands": results, "source_changed_during_checks": changed, "live_device_tests_executed": False, "release_acceptance": "not_assessed", "scope": "Review and isolated default Swift build/test only; DROIDBRIDGE_* opt-ins removed from child environment."}
(OUT / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2), flush=True)
