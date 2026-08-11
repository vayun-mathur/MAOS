#!/usr/bin/env python3
"""
script_to_manifest.py — translate a GrapheneOS install-zip `script.txt` into the ordered
flash plan the MAOS web installer consumes (manifest.json `steps`).

Why: the install zip (`<device>-install-<build>.zip`) already contains the whole `super`
pre-split into `super_1..N.img` (sized to the device max-download-size) AND `script.txt`,
GrapheneOS's *verified* flash sequence — it flashes `super` directly in bootloader mode
(no fastbootd), which is the lowest-brick-risk path. Rather than invent a plan, we translate
that script verbatim into installer steps so the browser flasher does exactly what
GrapheneOS's own tooling does, in the same order.

script.txt grammar (one command per line; blank lines and `#` comments ignored):

    check-var NAME VALUE            # or `check-var NAME:VALUE`
    flash PART FILE [other-slot]    # a 3rd token flashes to the inactive slot
    toggle-active-slot
    reboot-bootloader
    run-cmd CMD...                  # raw fastboot command (e.g. `set_active:a`, `oem uart disable`)
    erase PART
    maybe-cancel-snapshot-update
    check-requirements FILE         # android-info.txt with `require KEY=VAL[|VAL...]` lines
    reboot

Emitted manifest steps (see location_share_server/os_installer/installer.js for handlers):

    {"action":"check-var","name":NAME,"value":VALUE}
    {"action":"flash","partition":PART,"image":FILE[,"slot":"other"]}
    {"action":"toggle-active-slot"}
    {"action":"reboot-bootloader"}
    {"action":"run-cmd","command":CMD}
    {"action":"erase","partition":PART}
    {"action":"snapshot-update-cancel"}
    {"action":"check-requirements","requirements":[{"name":NAME,"values":[...]}, ...]}
    {"action":"reboot"}

Unknown commands are a hard error (fail loud rather than silently drop a step that could
matter for a safe flash).

USAGE:
    script_to_manifest.py --script script.txt --device DEVICE --build BUILD [--srcdir DIR]

Prints the full manifest JSON ({"device","build","steps":[...]}) to stdout. `check-requirements`
resolves its android-info file relative to --srcdir (defaults to the script's own directory).
"""
import argparse
import json
import os
import sys


def parse_android_info(path):
    """Parse `require KEY=VAL[|VAL...]` lines from an android-info.txt into a list of
    {"name": KEY, "values": [VAL, ...]} requirement objects."""
    reqs = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if not line.startswith("require "):
                continue
            body = line[len("require "):].strip()
            if "=" not in body:
                continue
            name, _, value = body.partition("=")
            name = name.strip()
            values = [v.strip() for v in value.split("|") if v.strip()]
            if name:
                reqs.append({"name": name, "values": values})
    return reqs


def translate(script_path, srcdir):
    steps = []
    with open(script_path, "r", encoding="utf-8", errors="replace") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            toks = line.split()
            cmd = toks[0]

            if cmd == "check-var":
                # `check-var NAME VALUE` or `check-var NAME:VALUE`
                if len(toks) >= 3:
                    name, value = toks[1], toks[2]
                elif len(toks) == 2 and ":" in toks[1]:
                    name, value = toks[1].split(":", 1)
                else:
                    raise ValueError(f"line {lineno}: malformed check-var: {line!r}")
                steps.append({"action": "check-var", "name": name, "value": value})

            elif cmd == "flash":
                if len(toks) < 3:
                    raise ValueError(f"line {lineno}: malformed flash: {line!r}")
                step = {"action": "flash", "partition": toks[1], "image": toks[2]}
                # Any trailing token (e.g. `other-slot`) => flash to the inactive slot.
                if len(toks) >= 4:
                    step["slot"] = "other"
                steps.append(step)

            elif cmd == "toggle-active-slot":
                steps.append({"action": "toggle-active-slot"})

            elif cmd == "reboot-bootloader":
                steps.append({"action": "reboot-bootloader"})

            elif cmd == "run-cmd":
                if len(toks) < 2:
                    raise ValueError(f"line {lineno}: run-cmd needs a command: {line!r}")
                steps.append({"action": "run-cmd", "command": " ".join(toks[1:])})

            elif cmd == "erase":
                if len(toks) < 2:
                    raise ValueError(f"line {lineno}: erase needs a partition: {line!r}")
                steps.append({"action": "erase", "partition": toks[1]})

            elif cmd == "maybe-cancel-snapshot-update":
                steps.append({"action": "snapshot-update-cancel"})

            elif cmd == "check-requirements":
                if len(toks) < 2:
                    raise ValueError(f"line {lineno}: check-requirements needs a file: {line!r}")
                info = toks[1]
                if not os.path.isabs(info):
                    info = os.path.join(srcdir, info)
                if not os.path.isfile(info):
                    raise FileNotFoundError(
                        f"line {lineno}: check-requirements file not found: {info}"
                    )
                steps.append(
                    {"action": "check-requirements", "requirements": parse_android_info(info)}
                )

            elif cmd == "reboot":
                steps.append({"action": "reboot"})

            else:
                raise ValueError(
                    f"line {lineno}: unknown script.txt command {cmd!r}. Extend "
                    f"script_to_manifest.py (and installer.js) before publishing: {line!r}"
                )

    if not steps:
        raise ValueError("script.txt produced no steps")
    return steps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True, help="path to the install zip's script.txt")
    ap.add_argument("--device", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument(
        "--srcdir",
        default=None,
        help="dir to resolve check-requirements files against (default: script's dir)",
    )
    args = ap.parse_args()

    srcdir = args.srcdir or os.path.dirname(os.path.abspath(args.script))
    try:
        steps = translate(args.script, srcdir)
    except Exception as e:  # noqa: BLE001 - surface a clear message and fail
        print(f"script_to_manifest: {e}", file=sys.stderr)
        sys.exit(1)

    manifest = {"device": args.device, "build": args.build, "steps": steps}
    json.dump(manifest, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
