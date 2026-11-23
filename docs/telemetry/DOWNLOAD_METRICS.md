# Aggregate download reporting

Use GitHub's existing release-asset `download_count`, without adding a download
redirect, browser cookie, tracking pixel, customer identifier, or download callback
to DroidBridge. The [official release API](https://docs.github.com/en/rest/releases/releases#list-releases)
returns cumulative asset counters. No author/uploader details are required.

## Operator interface

```sh
python3 scripts/telemetry-downloads.py --output /private/tmp/downloads-today.json
python3 scripts/telemetry-downloads.py --previous /private/tmp/downloads-yesterday.json --output /private/tmp/downloads-today.json
python3 -B scripts/test-telemetry-downloads.py
```

The script uses an operator's existing `gh api` authentication for read-only
GitHub requests. Credentials do not ship in DroidBridge, enter its telemetry, or
appear in reports. The implementation paginates both releases and each release's
assets, bounds input, excludes drafts, includes explicitly labeled prereleases,
and writes only a sanitized report through atomic replacement. It retains public
release/asset IDs, channel, artifact kind, cumulative count, and known deltas.
It discards release bodies, author/uploader objects, asset names and URLs.

For offline processing, `--input FILE` accepts
`{"releases":[...],"inventory_complete":true}` with the original API-shaped
release and asset records. Set `inventory_complete` false if the input is partial.
The complete flag is an explicit operator assertion for offline input; live
fetches set it only after every bounded page succeeds.

## Interpret the output

- `mac_installer` (`.dmg`), `mac_archive` (DroidBridge architecture `.zip`),
  `android_package`, `metadata`, and `other` remain separate. A release manifest
  fetch is not an app download. A customer fetching both the DMG and ZIP must not
  become two claimed customers.
- `counters_available: false` means no published asset counters were observed;
  numeric empty-category sums do not establish zero downloads or users.
- A comparable unchanged asset ID with a nondecreasing counter yields a delta.
  New, missing, replaced, or decreasing counters make the full interval delta
  unknown (`null`), rather than inventing a count or returning a negative number.
  Partial inventories also make the interval total unknown.
- Downloads include repeat transfers, automation and internal verification.
  They are not unique people, installed copies, activation, usage, or retention.
  Do not join them to anonymous usage contributions or report an install
  conversion rate with an incompatible denominator.

The current authenticated read on 2026-11-21 returned an empty published-release
list. Its sanitized receipt and report are under
`verification/telemetry-2026-11-21/`; this is **unavailable asset inventory**, not
evidence that nobody downloaded or used DroidBridge.

Retain modest administrator snapshots (for example, 13 weekly observations) if
trend reporting is useful. No schedule, service, GitHub write, upload, or release
publication is installed by this tool. Running it once per day is sufficient;
there is no reason to query for each customer's activity.
