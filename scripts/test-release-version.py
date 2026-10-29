#!/usr/bin/env python3
import importlib.util
from pathlib import Path
from datetime import datetime, timezone
import unittest

spec = importlib.util.spec_from_file_location("release_version", Path(__file__).with_name("release-version.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VersionTests(unittest.TestCase):
    now = datetime(2026, 10, 30, 12, 34, 56, tzinfo=timezone.utc)

    def test_main_is_calendar_beta(self):
        result = module.derive("refs/heads/main", self.now, 1793363696)
        self.assertEqual(result["VERSION"], "2026.1030.45296")
        self.assertEqual(result["RELEASE_CHANNEL"], "beta")
        self.assertEqual(result["RELEASE_TAG"], "v2026.1030.45296-beta.1793363696")

    def test_tag_is_stable(self):
        result = module.derive("refs/tags/v2026.1030.45296", self.now, 1793363700)
        self.assertEqual(result["RELEASE_CHANNEL"], "stable")
        self.assertEqual(result["VERSION"], "2026.1030.45296")

    def test_midnight_and_single_digit_month(self):
        now = datetime(2027, 1, 2, tzinfo=timezone.utc)
        self.assertEqual(module.derive("refs/heads/main", now, 1)["VERSION"], "2027.102.0")

    def test_invalid_refs(self):
        for ref in ["refs/heads/feature", "refs/tags/v1.2.3-beta", "refs/tags/v2026.1330.1", "refs/tags/v2026.1030.86400", "refs/tags/v2026.230.1"]:
            with self.assertRaises(ValueError):
                module.derive(ref, self.now, 1)

    def test_invalid_build(self):
        for build in [0, -1, "abc"]:
            with self.assertRaises(ValueError):
                module.derive("refs/heads/main", self.now, build)


if __name__ == "__main__":
    unittest.main()
