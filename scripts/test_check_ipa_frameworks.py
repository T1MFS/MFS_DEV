import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from check_ipa_frameworks import LC_RPATH, check_ipa, dependencies


def macho(*loads):
    commands = []
    for kind, name in loads:
        value = name.encode() + b"\0"
        start = 12 if kind == LC_RPATH else 24
        size = (start + len(value) + 7) & ~7
        header = (struct.pack("<III", kind, size, start) if kind == LC_RPATH else
                  struct.pack("<IIIIII", kind, size, start, 0, 0, 0))
        commands.append(header + value.ljust(size - start, b"\0"))
    body = b"".join(commands)
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0, 0, 0, len(commands), len(body), 0, 0) + body


def universal(first, second):
    offset = 8 + 2 * 20
    header = struct.pack(">II", 0xCAFEBABE, 2)
    entries = struct.pack(">IIIII", 0, 0, offset, len(first), 0)
    entries += struct.pack(">IIIII", 0, 0, offset + len(first), len(second), 0)
    return header + entries + first + second


class CheckIpaFrameworksTest(unittest.TestCase):
    def make_ipa(self, path, *, include_chart=False, runpath=True, executable=None):
        app = "Payload/MFS.app/"
        with zipfile.ZipFile(path, "w") as ipa:
            ipa.writestr(app + "Info.plist", plistlib.dumps({"CFBundleExecutable": "MFS"}))
            commands = [(0xC, "@rpath/LoopKitUI.framework/LoopKitUI")]
            if runpath:
                commands.append((LC_RPATH, "@executable_path/Frameworks"))
            ipa.writestr(app + "MFS", executable if executable is not None else macho(*commands))
            ipa.writestr(app + "Frameworks/LoopKitUI.framework/LoopKitUI", macho(
                (0xC, "@rpath/SwiftCharts.framework/SwiftCharts"),
                (0x80000018, "@rpath/Optional.framework/Optional"),
                (0xC, "@rpath/libswiftCore.dylib")))
            if include_chart:
                ipa.writestr(app + "Frameworks/SwiftCharts.framework/SwiftCharts", macho())

    def test_missing_transitive_framework_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.ipa"
            self.make_ipa(path)
            errors = check_ipa(path)
            self.assertEqual(len(errors), 1)
            self.assertIn("@rpath/SwiftCharts.framework/SwiftCharts", errors[0])

    def test_embedded_framework_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.ipa"
            self.make_ipa(path, include_chart=True)
            self.assertEqual(check_ipa(path), [])

    def test_missing_executable_framework_runpath_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.ipa"
            self.make_ipa(path, include_chart=True, runpath=False)
            self.assertIn("@executable_path/Frameworks runpath", check_ipa(path)[0])

    def test_each_executable_slice_requires_runpath(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.ipa"
            executable = universal(macho((LC_RPATH, "@executable_path/Frameworks")),
                                   macho((LC_RPATH, "/usr/lib/swift")))
            self.make_ipa(path, include_chart=True, executable=executable)
            self.assertIn("slice 2 is missing", check_ipa(path)[0])

    def test_invalid_embedded_framework_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.ipa"
            self.make_ipa(path)
            with zipfile.ZipFile(path, "a") as ipa:
                ipa.writestr("Payload/MFS.app/Frameworks/SwiftCharts.framework/SwiftCharts", b"invalid")
            self.assertIn("not a Mach-O binary", check_ipa(path)[0])

    def test_universal_binary_checks_all_slices(self):
        first = macho()
        second = macho((0xC, "@rpath/Foo.framework/Foo"))
        self.assertEqual(dependencies(universal(first, second)), {"@rpath/Foo.framework/Foo"})

    def test_invalid_load_command_is_rejected(self):
        with self.assertRaises(ValueError):
            dependencies(macho((0xC, "@rpath/Foo.framework/Foo"))[:-1])


if __name__ == "__main__":
    unittest.main()
