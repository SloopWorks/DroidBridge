#!/usr/bin/env python3
"""Build the actual Core-linked companion probe and bind its source/object hashes."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

if not __debug__:
    raise SystemExit('Probe source binding requires Python assertions; remove -O/PYTHONOPTIMIZE.')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(".build/verify-companion-client"))
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    files = sorted((repo / "Sources/DroidBridgeCore").glob("*.swift")) + [repo / "Package.swift", repo / "scripts/verify-companion-client.swift", Path(__file__).resolve()]
    before = {str(p.relative_to(repo)): digest(p) for p in files}
    subprocess.run(["swift", "build", "--target", "DroidBridgeCore"], cwd=repo, check=True)
    binary_dir = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=repo, text=True).strip())
    objects = sorted((binary_dir / "DroidBridgeCore.build").glob("*.swift.o"))
    assert objects and all(p.stat().st_size > 0 for p in objects)
    target = args.output.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", "-I", str(binary_dir / "Modules"),
                    str(repo / "scripts/verify-companion-client.swift"), *map(str, objects), "-o", str(target)], cwd=repo, check=True)
    after = {str(p.relative_to(repo)): digest(p) for p in files}
    assert before == after, "Core source changed during probe build; discard candidate and rebuild"
    manifest = {"scope": "Actual production DroidBridgeCore objects linked with stdin-only verification driver",
                "source_sha256": after, "object_sha256": {p.name: digest(p) for p in objects},
                "probe_path": str(target.relative_to(repo)), "probe_sha256": digest(target)}
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"probe_sha256": manifest["probe_sha256"], "sources": len(after), "objects": len(objects)}))

if __name__ == "__main__": main()
