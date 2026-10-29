#!/usr/bin/env python3
"""Model-free tests for public bundle metadata and update configuration."""
import base64
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("configure_bundle", Path(__file__).with_name("configure-bundle.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BundleConfigurationTests(unittest.TestCase):
    def info(self):
        return {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"}

    def test_local_build_has_no_update_requests(self):
        result = module.configure(self.info(), {})
        self.assertNotIn("SUFeedURL", result)
        self.assertNotIn("SUPublicEDKey", result)
        self.assertFalse(result["SUEnableAutomaticChecks"])

    def test_release_configures_checking_without_silent_install(self):
        key = base64.b64encode(bytes(range(32))).decode()
        result = module.configure(self.info(), {
            "VERSION": "1.2.3", "BUILD_NUMBER": "42",
            "UPDATE_FEED_URL": "https://downloads.example.com/appcast.xml",
            "BETA_UPDATE_FEED_URL": "https://downloads.example.com/appcast-beta.xml", "SPARKLE_PUBLIC_KEY": key,
        })
        self.assertEqual(result["CFBundleVersion"], "42")
        self.assertEqual(result["CFBundleShortVersionString"], "1.2.3")
        self.assertTrue(result["SUEnableAutomaticChecks"])
        self.assertFalse(result["SUAutomaticallyUpdate"])
        self.assertFalse(result["SUAllowsAutomaticUpdates"])

    def test_rejects_partial_feed_configuration(self):
        for env in [{"UPDATE_FEED_URL": "https://example.com/feed"}, {"SPARKLE_PUBLIC_KEY": "abc"}]:
            with self.assertRaises(ValueError):
                module.configure(self.info(), env)

    def test_rejects_non_https_and_credentials(self):
        for feed in ["http://example.com/feed", "https://token@example.com/feed", "https://example.com/feed?token=secret", "https://example.com/feed#fragment"]:
            with self.assertRaises(ValueError):
                module.configure(self.info(), {"UPDATE_FEED_URL": feed, "BETA_UPDATE_FEED_URL": "https://example.com/beta", "SPARKLE_PUBLIC_KEY": base64.b64encode(bytes(32)).decode()})

    def test_rejects_invalid_key(self):
        for key in ["invalid", base64.b64encode(bytes(31)).decode(), base64.b64encode(bytes(33)).decode()]:
            with self.assertRaises(ValueError):
                module.configure(self.info(), {"UPDATE_FEED_URL": "https://example.com/feed", "BETA_UPDATE_FEED_URL": "https://example.com/beta", "SPARKLE_PUBLIC_KEY": key})

    def test_rejects_invalid_versions(self):
        for env in [{"VERSION": "1.2-beta"}, {"VERSION": "$(command)"}, {"BUILD_NUMBER": "0"}, {"BUILD_NUMBER": "-1"}]:
            with self.assertRaises(ValueError):
                module.configure(self.info(), env)

    def test_disables_stale_updater_config(self):
        info = self.info() | {"SUFeedURL": "https://old.example/feed", "SUPublicEDKey": "old"}
        result = module.configure(info, {})
        self.assertNotIn("SUFeedURL", result)
        self.assertNotIn("SUPublicEDKey", result)


if __name__ == "__main__":
    unittest.main()
