#!/usr/bin/env python3
"""Read aggregate GitHub release-asset counters, without customer tracking.

Network reads use the operator's gh authentication, never an application secret.
No author/uploader objects, URLs, release bodies, or asset names enter reports.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

FORMAT = "sloopworks.aggregate-downloads.v1"
MAX_BYTES = 2 * 1024 * 1024
MAX_RECORDS = 10000
KINDS = {"mac_installer", "mac_archive", "android_package", "metadata", "other"}


def natural(value, name):
    if type(value) is not int or not 0 <= value <= 2**63 - 1:
        raise ValueError(f"Invalid {name}")
    return value


def repository_name(value):
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}", value):
        raise ValueError("Expected an owner/repository name")
    return value


def read_json(path):
    with Path(path).open("rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("Input exceeds the supported size")
    return json.loads(data)


def asset_kind(name):
    if not isinstance(name, str) or len(name) > 1024:
        raise ValueError("Invalid asset name")
    name = name.lower()
    if name.endswith(".dmg"):
        return "mac_installer"
    if name.endswith(".zip") and name.startswith("droidbridge-") and re.search(r"-(?:arm64|x86_64|universal)\.zip$", name):
        return "mac_archive"
    if name.endswith(".apk"):
        return "android_package"
    if name.endswith((".json", ".txt", ".sha256", ".sha256sum")):
        return "metadata"
    return "other"


def validate_previous(value, repository):
    if not isinstance(value, dict) or value.get("format") != FORMAT or value.get("repository") != repository:
        raise ValueError("Previous report must use the same format and repository")
    assets = value.get("assets")
    if not isinstance(assets, list) or len(assets) > MAX_RECORDS:
        raise ValueError("Invalid previous asset inventory")
    previous = {}
    for asset in assets:
        if not isinstance(asset, dict):
            raise ValueError("Invalid previous asset")
        identity = natural(asset.get("asset_id"), "previous asset identity")
        count = natural(asset.get("download_count"), "previous counter")
        if identity in previous:
            raise ValueError("Duplicate previous asset identity")
        previous[identity] = count
    return previous


def summarize(inventory, repository, previous=None, day=None):
    repository = repository_name(repository)
    if not isinstance(inventory, dict) or set(inventory) != {"releases", "inventory_complete"} or type(inventory["inventory_complete"]) is not bool:
        raise ValueError("Inventory requires releases and explicit inventory_complete")
    releases = inventory["releases"]
    if not isinstance(releases, list) or len(releases) > MAX_RECORDS:
        raise ValueError("Invalid release inventory")
    old = validate_previous(previous, repository) if previous is not None else None
    assets, seen_releases, seen_assets = [], set(), set()
    published = 0
    for release in releases:
        if not isinstance(release, dict) or type(release.get("draft")) is not bool or type(release.get("prerelease")) is not bool:
            raise ValueError("Invalid release state")
        if release["draft"]:
            continue
        release_id = natural(release.get("id"), "release identity")
        if release_id in seen_releases:
            raise ValueError("Duplicate release identity")
        seen_releases.add(release_id)
        published += 1
        release_assets = release.get("assets")
        if not isinstance(release_assets, list) or len(assets) + len(release_assets) > MAX_RECORDS:
            raise ValueError("Invalid asset inventory")
        for asset in release_assets:
            if not isinstance(asset, dict) or asset.get("state") != "uploaded":
                raise ValueError("Asset is not a complete uploaded asset")
            identity = natural(asset.get("id"), "asset identity")
            if identity in seen_assets:
                raise ValueError("Duplicate asset identity")
            seen_assets.add(identity)
            count = natural(asset.get("download_count"), "download counter")
            delta = None
            status = "no_baseline" if old is None else "first_seen"
            if old is not None and identity in old:
                status = "counter_decreased" if count < old[identity] else "comparable"
                if status == "comparable":
                    delta = count - old[identity]
            assets.append({"asset_id": identity, "release_id": release_id, "channel": "prerelease" if release["prerelease"] else "stable", "kind": asset_kind(asset.get("name")), "download_count": count, "delta": delta, "delta_status": status})
    missing = sorted(set(old or {}) - seen_assets)
    comparable = old is not None and not missing and all(a["delta"] is not None for a in assets) and inventory["inventory_complete"] and previous.get("inventory_complete") is True
    totals = {kind: sum(a["download_count"] for a in assets if a["kind"] == kind) for kind in sorted(KINDS)}
    return {"format": FORMAT, "repository": repository, "observed_utc_day": day or datetime.now(timezone.utc).date().isoformat(), "source": "github_release_asset_counters", "inventory_complete": inventory["inventory_complete"], "published_releases": published, "asset_count": len(assets), "counters_available": bool(assets), "cumulative_downloads_by_kind": totals, "interval_delta_complete": comparable, "interval_download_delta": sum(a["delta"] for a in assets) if comparable else None, "missing_previous_asset_ids": missing, "assets": sorted(assets, key=lambda a: a["asset_id"]), "limitations": ["Counts asset transfers, not unique people, installations, completed installations, or active users.", "Repeated downloads, bots, CI, and multiple package formats can increase counters.", "Absent releases/assets are unavailable inventory, not proof of zero downloads.", "New, missing, or decreased asset counters make the total interval delta unknown."]}


def gh_page(path):
    # Disk staging bounds retained process output; stderr is never copied into a
    # report because operator tooling can print authentication diagnostics.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        result = subprocess.run(["gh", "api", "--method", "GET", "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2026-03-10", path], stdout=stdout, stderr=stderr, timeout=30)
        if result.returncode:
            raise ValueError("GitHub read failed; check operator gh access locally")
        if stdout.tell() > MAX_BYTES:
            raise ValueError("GitHub page exceeds the supported size")
        stdout.seek(0)
        value = json.load(stdout)
    if not isinstance(value, list) or len(value) > 100:
        raise ValueError("GitHub returned an invalid collection page")
    return value


def github_inventory(repository):
    repository = repository_name(repository)
    def pages(resource):
        values = []
        for page in range(1, 101):
            result = gh_page(f"repos/{repository}/{resource}?per_page=100&page={page}")
            values.extend(result)
            if len(values) > MAX_RECORDS:
                raise ValueError("GitHub inventory exceeds the supported limit")
            if len(result) < 100:
                return values
        raise ValueError("GitHub pagination limit reached; refusing partial inventory")
    releases = pages("releases")
    count = 0
    for release in releases:
        if not isinstance(release, dict):
            raise ValueError("Invalid release")
        if release.get("draft") is True:
            continue
        identity = natural(release.get("id"), "release identity")
        # Nested release.assets arrays are not used as a pagination guarantee.
        release["assets"] = pages(f"releases/{identity}/assets")
        count += len(release["assets"])
        if count > MAX_RECORDS:
            raise ValueError("Asset inventory exceeds the supported limit")
    return {"releases": releases, "inventory_complete": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="SloopWorks/DroidBridge")
    parser.add_argument("--input", type=Path, help="Offline inventory: {releases:[...], inventory_complete:bool}")
    parser.add_argument("--previous", type=Path, help="Previous sanitized report for conservative interval deltas")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        inventory = read_json(args.input) if args.input else github_inventory(args.repository)
        result = summarize(inventory, args.repository, read_json(args.previous) if args.previous else None)
        encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            fd, name = tempfile.mkstemp(prefix=".download-metrics-", dir=args.output.parent)
            try:
                with os.fdopen(fd, "w") as stream:
                    stream.write(encoded)
                os.replace(name, args.output)
            finally:
                if os.path.exists(name):
                    os.unlink(name)
        else:
            print(encoded, end="")
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"Download report unavailable: {error}\n")


if __name__ == "__main__":
    main()
