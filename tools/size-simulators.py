#!/usr/bin/env python3
"""Prints the UDIDs of the smallest and the largest iPhone simulator on iOS 27.0, one per line.

Sizes are read from each device type's capabilities (screen pixels over scale, in points), so the pick
follows the Xcode on the runner rather than a list of names. A type with no simulator yet is created;
one that iOS 27.0 does not support is skipped. Names go to stderr.
"""
import json
import plistlib
import subprocess
import sys

RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"


def simctl(*args):
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True)


def find_screen(node):
    """The ScreenDimensionsCapability dict, wherever the plist nests it."""
    if isinstance(node, dict):
        if "main-screen-width" in node:
            return node
        for value in node.values():
            found = find_screen(value)
            if found:
                return found
    return None


def screen_points(bundle):
    with open(f"{bundle}/Contents/Resources/capabilities.plist", "rb") as handle:
        screen = find_screen(plistlib.load(handle))
    scale = screen["main-screen-scale"]
    return screen["main-screen-width"] / scale, screen["main-screen-height"] / scale


def existing():
    listing = json.loads(simctl("list", "-j", "devices", "available").stdout)
    return {d["deviceTypeIdentifier"]: d["udid"] for d in listing["devices"].get(RUNTIME, []) if "deviceTypeIdentifier" in d}


def pick(types, have, largest):
    for name, identifier, _ in sorted(types, key=lambda t: t[2], reverse=largest):
        if identifier in have:
            return name, have[identifier]
        made = simctl("create", f"Marquee {name}", identifier, RUNTIME)
        if made.returncode == 0:
            return name, made.stdout.strip()
    sys.exit("No iPhone simulator for iOS 27.0")


def main():
    listing = json.loads(simctl("list", "-j", "devicetypes").stdout)
    types = []
    for kind in listing["devicetypes"]:
        if kind.get("productFamily") != "iPhone":
            continue
        try:
            width, height = screen_points(kind["bundlePath"])
        except (OSError, KeyError, TypeError, plistlib.InvalidFileException):
            continue
        types.append((kind["name"], kind["identifier"], width * height))
    have = existing()
    for largest in (False, True):
        name, udid = pick(types, have, largest)
        print(name, file=sys.stderr)
        print(udid)


main()
