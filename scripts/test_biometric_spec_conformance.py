"""Fail when Sources/Biometrics.swift drifts from the biometric spec in TidepoolApi_extended.

The spec checkout is located via SPEC_DIR (CI sets it). Locally the spec tests are skipped if it is not found.
The app sends a subset of the spec's metrics, so every Swift metric must exist in the spec with the same unit.
"""
import os
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SWIFT = ROOT / "Sources" / "Biometrics.swift"
METRIC_FILE = "reference/data/models/biometric/metric.v1.yaml"
CANDIDATES = [os.environ.get("SPEC_DIR"), ROOT.parent / "TidepoolApi_extended", ROOT.parent / "tidepoolAPI_Extended"]


def swift_metrics() -> dict[str, str]:
    """Parse `enum BiometricMetric`: its cases and the `units` switch."""
    source = SWIFT.read_text()
    enum = source[source.index("enum BiometricMetric"):source.index("struct BiometricSample")]
    cases = re.findall(r"^\s*case ([A-Za-z]+)\s*$", enum, re.M)
    units = dict(re.findall(r'case \.([A-Za-z]+): return "([^"]+)"', enum))
    return {name: units.get(name) for name in cases}


def find_spec() -> Path | None:
    for candidate in filter(None, CANDIDATES):
        path = Path(candidate) / METRIC_FILE
        if path.is_file():
            return path
    return None


class BiometricSpecConformanceTest(unittest.TestCase):
    def test_parser_finds_the_swift_metrics(self):
        metrics = swift_metrics()
        self.assertGreaterEqual(len(metrics), 3)
        self.assertNotIn(None, metrics.values(), "every metric needs a unit in the units switch")

    def test_swift_metrics_match_spec(self):
        path = find_spec()
        if path is None:
            self.skipTest("TidepoolApi_extended checkout not found (set SPEC_DIR)")
        spec = yaml.safe_load(path.read_text())
        for name, unit in swift_metrics().items():
            self.assertIn(name, spec["enum"], f"{name} is not a spec metric")
            self.assertEqual(unit, spec["x-metric-units"][name], f"wrong unit for {name}")

    def test_glucose_is_not_a_biometric(self):
        for name in swift_metrics():
            self.assertNotIn(name.lower(), {"glucose", "cbg", "smbg"})


if __name__ == "__main__":
    unittest.main()
