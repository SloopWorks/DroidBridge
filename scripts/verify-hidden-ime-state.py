#!/usr/bin/env python3
"""Read-only, fail-closed oracle for display-scoped Android IME snapshots.

Does not execute ADB, infer current state from input_method history, alter Android
settings, or treat a screenshot/CLI success as hidden-keyboard evidence. Real
acceptance additionally requires display-bound text/raw-key receipts and sampled
snapshots throughout editing/resizing/panel transitions.
"""
import argparse
import json
import pathlib
import re


def unique_bool(block, pattern, description):
    values = re.findall(pattern, block, re.MULTILINE)
    if len(set(values)) != 1:
        raise ValueError(f"Missing or ambiguous {description}: {values}")
    return values[0] == "true"


def chunks(text, pattern):
    matches = list(re.finditer(pattern, text, re.MULTILINE))
    return [(match, text[match.start():matches[index + 1].start() if index + 1 < len(matches) else len(text)])
            for index, match in enumerate(matches)]


def inspect(displays, windows, expected):
    """expected is {positive virtual display ID: packageName}. Raises on unknown."""
    if not expected or any(display <= 0 for display in expected):
        raise ValueError("Explicit nonzero virtual-display identities required")
    display_blocks = {}
    for match, block in chunks(displays, r"^\s{0,4}Display: mDisplayId=(\d+)\b"):
        identity = int(match.group(1))
        if identity in display_blocks:
            raise ValueError(f"Duplicate display block {identity}")
        display_blocks[identity] = block
    window_blocks = chunks(windows, r"^\s*Window #\d+ Window\{[^\n]+\}:\s*$")
    if not window_blocks:
        raise ValueError("Missing current WindowState dump; refusing empty evidence")
    records = []
    for display, package in expected.items():
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+", package):
            raise ValueError("Invalid expected package")
        block = display_blocks.get(display)
        if block is None:
            raise ValueError(f"Virtual display {display} absent from display dump")
        # Android17's legacy dump label mShouldShowIme stores mImePolicy,
        # not a boolean. HIDE may omit the IME source entirely on this build.
        policy_tokens = re.findall(r"\bmShouldShowIme=([^,}\s]*)", block)
        policy = None
        if policy_tokens:
            if set(policy_tokens) != {"2"}:
                raise ValueError(f"Non-HIDE or ambiguous display IME policy on {display}: {policy_tokens}")
            policy = 2
        inset_lines = [line.strip() for line in block.splitlines() if re.search(r"\btype=ime\b", line)]
        if not inset_lines and policy != 2:
            raise ValueError(f"Neither explicit hidden IME InsetsSource nor HIDE policy on display {display}")
        for line in inset_lines:
            if unique_bool(line, r"\bvisible=(true|false)\b", f"IME inset visibility display {display}"):
                raise ValueError(f"Visible IME inset on display {display}: {line}")
        app_windows = []
        ime_windows = []
        for match, window in window_blocks:
            is_ime = bool(re.search(r"\bty=INPUT_METHOD(?:_DIALOG)?\b|\bmIsImWindow=true\b", window)
                          or re.search(r"\bInputMethod(?:Dialog)?\}", match.group(0)))
            identities = set(re.findall(r"\bmDisplayId=(\d+)\b", window))
            if is_ime and len(identities) != 1:
                raise ValueError("IME WindowState missing unique display identity")
            if identities != {str(display)}:
                continue
            if is_ime:
                facts = {"header": match.group(0).strip()}
                for key, pattern in [("has_surface", r"\bmHasSurface=(true|false)\b"),
                                     ("ready", r"\bisReadyForDisplay\(\)=(true|false)\b"),
                                     ("on_screen", r"^\s*isOnScreen=(true|false)\b"),
                                     ("visible", r"^\s*isVisible=(true|false)\b")]:
                    facts[key] = unique_bool(window, pattern, f"{key} IME display {display}")
                if any(facts[key] for key in ("has_surface", "ready", "on_screen", "visible")):
                    raise ValueError(f"IME surface/presentation remains attached to display {display}: {facts}")
                ime_windows.append(facts)
            elif re.search(r"(?<![A-Za-z0-9_.])" + re.escape(package) + r"/", match.group(0)):
                if unique_bool(window, r"^\s*isVisible=(true|false)\b", f"app visibility display {display}"):
                    app_windows.append(match.group(0).strip())
        if not app_windows:
            raise ValueError(f"Expected visible {package} window absent on display {display}")
        records.append({"display": display, "package": package, "ime_policy": policy,
                        "ime_source_absent_with_explicit_hide": not inset_lines and policy == 2,
                        "ime_insets": inset_lines,
                        "ime_windows": ime_windows, "visible_app_windows": app_windows})
    return {"passed": True, "scope": "supplied current display/window snapshots only",
            "continuous_never_visible_proven": False, "text_or_keyboard_delivery_proven": False,
            "displays": records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--displays", type=pathlib.Path, required=True)
    parser.add_argument("--windows", type=pathlib.Path, required=True)
    parser.add_argument("--expect", action="append", required=True, metavar="DISPLAY:PACKAGE")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    expected = {}
    for pair in args.expect:
        number, package = pair.split(":", 1)
        if int(number) in expected:
            parser.error("Duplicate expected display identity")
        expected[int(number)] = package
    try:
        result = inspect(args.displays.read_text(), args.windows.read_text(), expected)
    except ValueError as error:
        result = {"passed": False, "reason": str(error)}
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
