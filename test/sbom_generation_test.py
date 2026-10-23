import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tool/sbom"))
import generate


class SbomGenerationTest(unittest.TestCase):
    def test_serial_number_depends_only_on_published_inputs(self):
        first = generate.serial_number(
            "fullRelease",
            "a" * 64,
            "1111111111111111111111111111111111111111",
        )
        second = generate.serial_number(
            "fullRelease",
            "a" * 64,
            "2222222222222222222222222222222222222222",
        )

        self.assertEqual(first, second)
    def test_fingerprint_and_serial_change_with_flutter_engine(self):
        common = {
            "frameworkVersion": "3.47.7",
            "frameworkRevision": "framework-a",
            "dartSdkVersion": "3.13.5",
        }
        first_fingerprint = generate.fingerprint_inputs(
            flutter_identity={**common, "engineRevision": "engine-a"}
        )
        second_fingerprint = generate.fingerprint_inputs(
            flutter_identity={**common, "engineRevision": "engine-b"}
        )

        self.assertNotEqual(first_fingerprint, second_fingerprint)
        self.assertNotEqual(
            generate.serial_number("fullRelease", first_fingerprint),
            generate.serial_number("fullRelease", second_fingerprint),
        )


if __name__ == "__main__":
    unittest.main()
