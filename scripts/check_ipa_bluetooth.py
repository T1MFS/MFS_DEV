#!/usr/bin/env python3
"""Verify the exported app supports G7 Bluetooth state restoration."""

import plistlib
import sys
import zipfile


def check_ipa(path):
    with zipfile.ZipFile(path) as ipa:
        plists = [name for name in ipa.namelist() if name.startswith("Payload/") and
                  name.count("/") == 2 and name.endswith(".app/Info.plist")]
        if len(plists) != 1:
            raise ValueError("IPA must contain exactly one top-level app")
        info = plistlib.loads(ipa.read(plists[0]))
    modes = info.get("UIBackgroundModes")
    if not isinstance(modes, list) or "bluetooth-central" not in modes:
        raise ValueError("app Info.plist must include bluetooth-central in UIBackgroundModes")
    description = info.get("NSBluetoothAlwaysUsageDescription")
    if not isinstance(description, str) or not description.strip():
        raise ValueError("app Info.plist must include NSBluetoothAlwaysUsageDescription")


def main():
    if len(sys.argv) != 2:
        print("Usage: check_ipa_bluetooth.py PATH.ipa", file=sys.stderr)
        return 2
    try:
        check_ipa(sys.argv[1])
    except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"IPA Bluetooth configuration check failed: {error}", file=sys.stderr)
        return 1
    print("IPA Bluetooth configuration supports state restoration.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
