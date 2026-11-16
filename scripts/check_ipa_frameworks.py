#!/usr/bin/env python3
"""Check required @rpath dependencies in an exported iOS app."""

import plistlib
import posixpath
import struct
import sys
import zipfile


THIN_MAGIC = {
    b"\xce\xfa\xed\xfe": ("<", 28),
    b"\xcf\xfa\xed\xfe": ("<", 32),
    b"\xfe\xed\xfa\xce": (">", 28),
    b"\xfe\xed\xfa\xcf": (">", 32),
}
FAT_MAGIC = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}
# Weak dependencies may legitimately be absent on the device.
REQUIRED_DYLIB_COMMANDS = {0xC, 0x20, 0x8000001F, 0x80000023}


def dependencies(data):
    magic = data[:4]
    if magic in FAT_MAGIC:
        endian, wide = FAT_MAGIC[magic]
        count = struct.unpack_from(endian + "I", data, 4)[0]
        fmt = endian + ("IIQQII" if wide else "IIIII")
        entry_size = struct.calcsize(fmt)
        if count == 0 or count > (len(data) - 8) // entry_size:
            raise ValueError("invalid universal Mach-O header")
        result = set()
        for i in range(count):
            entry = struct.unpack_from(fmt, data, 8 + i * entry_size)
            offset, size = entry[2:4]
            if offset + size > len(data) or data[offset:offset + 4] not in THIN_MAGIC:
                raise ValueError("invalid universal Mach-O slice")
            result.update(dependencies(data[offset:offset + size]))
        return result
    if magic not in THIN_MAGIC:
        raise ValueError("not a supported Mach-O binary")
    endian, header_size = THIN_MAGIC[magic]
    count, commands_size = struct.unpack_from(endian + "II", data, 16)
    end = header_size + commands_size
    if end > len(data):
        raise ValueError("invalid Mach-O load commands")
    position = header_size
    result = set()
    for _ in range(count):
        if position + 8 > end:
            raise ValueError("truncated Mach-O load command")
        command, size = struct.unpack_from(endian + "II", data, position)
        if size < 8 or position + size > end:
            raise ValueError("invalid Mach-O load command size")
        if command in REQUIRED_DYLIB_COMMANDS:
            if size < 24:
                raise ValueError("invalid Mach-O dylib command")
            name_offset = struct.unpack_from(endian + "I", data, position + 8)[0]
            if name_offset < 24 or name_offset >= size:
                raise ValueError("invalid Mach-O dylib name")
            name = data[position + name_offset:position + size]
            if b"\0" not in name:
                raise ValueError("unterminated Mach-O dylib name")
            result.add(name.split(b"\0", 1)[0].decode("utf-8"))
        position += size
    if position != end:
        raise ValueError("inconsistent Mach-O load command size")
    return result


def check_ipa(path):
    with zipfile.ZipFile(path) as ipa:
        files = set(ipa.namelist())
        plists = [name for name in files if name.startswith("Payload/") and
                  name.count("/") == 2 and name.endswith(".app/Info.plist")]
        if len(plists) != 1:
            raise ValueError("IPA must contain exactly one top-level app")
        app = plists[0][:-len("Info.plist")]
        executable = app + plistlib.loads(ipa.read(plists[0]))["CFBundleExecutable"]
        if executable not in files:
            raise ValueError("app executable is missing")

        binaries = [executable]
        for name in sorted(files):
            if name.startswith(app + "Frameworks/") and not name.endswith("/"):
                with ipa.open(name) as source:
                    magic = source.read(4)
                if magic in THIN_MAGIC or magic in FAT_MAGIC:
                    binaries.append(name)

        errors = []
        for binary in binaries:
            try:
                loads = dependencies(ipa.read(binary))
            except (ValueError, struct.error, UnicodeError) as error:
                raise ValueError(f"{binary}: {error}") from error
            for load in sorted(loads):
                if not load.startswith("@rpath/"):
                    continue
                relative = load[len("@rpath/"):]
                # Swift standard libraries may be supplied by iOS itself.
                if "/" not in relative and relative.startswith("libswift") and relative.endswith(".dylib"):
                    continue
                target = posixpath.normpath(app + "Frameworks/" + relative)
                if not target.startswith(app + "Frameworks/") or target not in files:
                    errors.append(f"{binary} requires missing {load}")
                elif target not in binaries:
                    errors.append(f"{binary} requires {load}, but it is not a Mach-O binary")
        return errors


def main():
    if len(sys.argv) != 2:
        print("Usage: check_ipa_frameworks.py PATH.ipa", file=sys.stderr)
        return 2
    try:
        errors = check_ipa(sys.argv[1])
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f"IPA framework check failed: {error}", file=sys.stderr)
        return 1
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("IPA required @rpath dependencies are present.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
