import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("release_metadata", Path(__file__).resolve().parents[1] / "release_metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class ReleaseMetadataTest(unittest.TestCase):
    def test_build_number_is_not_part_of_release_tag(self):
        self.assertEqual(metadata.read_metadata("name: truenavo\nversion: 0.1.0+12\n"),
                         {"version": "0.1.0", "build": "12", "tag": "v0.1.0"})

    def test_rejects_invalid_or_ambiguous_versions(self):
        for source in ["", "version: 0.1.0", "version: 0.1.0+0", "version: 01.1.0+1",
                       "version: 1.0.0+2100000001", "version: 0.1.0+1\nversion: 0.2.0+2"]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                metadata.read_metadata(source)

    def test_extracts_only_requested_version(self):
        self.assertEqual(metadata.extract_notes("# Notes\n\n## 0.2.0\nNew\n\n## 0.1.0\nOld\n", "0.2.0"), "New")

    def test_rejects_missing_empty_or_oversized_notes(self):
        for source in ["## 0.2.0\nOther", "## 0.1.0\n\n", "## 0.1.0\n" + "가" * 501]:
            with self.subTest(length=len(source)), self.assertRaises(ValueError):
                metadata.extract_notes(source, "0.1.0")


if __name__ == "__main__":
    unittest.main()
