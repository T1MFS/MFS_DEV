import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from check_ipa_bluetooth import check_ipa


class CheckIpaBluetoothTest(unittest.TestCase):
    def check_info(self, info):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "app.ipa"
            with zipfile.ZipFile(path, "w") as ipa:
                ipa.writestr("Payload/MFS.app/Info.plist", plistlib.dumps(info))
            check_ipa(path)

    def test_restoration_configuration_passes(self):
        self.check_info({
            "UIBackgroundModes": ["bluetooth-central"],
            "NSBluetoothAlwaysUsageDescription": "Read glucose from your sensor.",
        })

    def test_missing_or_invalid_background_mode_fails(self):
        for modes in (None, [], "bluetooth-central"):
            with self.subTest(modes=modes), self.assertRaisesRegex(ValueError, "UIBackgroundModes"):
                info = {"NSBluetoothAlwaysUsageDescription": "Read glucose from your sensor."}
                if modes is not None:
                    info["UIBackgroundModes"] = modes
                self.check_info(info)

    def test_missing_bluetooth_description_fails(self):
        with self.assertRaisesRegex(ValueError, "NSBluetoothAlwaysUsageDescription"):
            self.check_info({"UIBackgroundModes": ["bluetooth-central"]})


if __name__ == "__main__":
    unittest.main()
