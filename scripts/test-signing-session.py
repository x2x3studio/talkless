#!/usr/bin/env python3
"""Model-free release-tool tests. All signing, credential, and GitHub calls are mocked."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

SPEC = importlib.util.spec_from_file_location("signing_session", Path(__file__).with_name("signing-session.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_versions_and_channels(self):
        for version, build in [("0.1.0", "1"), ("2026.1030.45296", "1793318400")]:
            release.validate_version(version, build)
        for version, build in [("../1.0.0", "1"), ("1.0.0-beta", "1"), ("01.2.3", "1"),
                               ("1.2.3", "0"), ("1.2.3", "1;id"), ("1.2.3", "9" * 19)]:
            with self.assertRaises(ValueError):
                release.validate_version(version, build)
        self.assertEqual(release.release_tag("1.2.3", "4", "beta"), "v1.2.3-beta.4")
        self.assertEqual(release.release_tag("1.2.3", "5", "stable"), "v1.2.3")
        with self.assertRaises(ValueError):
            release.release_tag("1.2.3", "4", "preview")

    def test_updater_configuration(self):
        self.assertEqual(release.updater_config({}), {})
        config = dict(UPDATE_FEED_URL="https://example.com/appcast.xml",
                      BETA_UPDATE_FEED_URL="https://example.com/beta.xml",
                      SPARKLE_PUBLIC_KEY=base64.b64encode(bytes(32)).decode(),
                      TALKLESS_SPARKLE_KEY_REF="op://vault/item/key",
                      DOWNLOAD_BASE_URL="https://example.com/v1")
        self.assertEqual(release.updater_config(config), config)
        for name in config:
            bad = config.copy()
            del bad[name]
            with self.assertRaises(ValueError):
                release.updater_config(bad)
        for name, value in [("UPDATE_FEED_URL", "https://user:password@example.com/a"),
                            ("UPDATE_FEED_URL", "http://example.com"),
                            ("SPARKLE_PUBLIC_KEY", "not-base64"),
                            ("TALKLESS_SPARKLE_KEY_REF", "raw-key")]:
            bad = config.copy()
            bad[name] = value
            with self.assertRaises(ValueError):
                release.updater_config(bad)

    def test_xml_escaping_and_stability(self):
        args = ("2026.1030.42", "1793318400", "15.0", "https://example.com/a&b.zip",
                base64.b64encode(bytes(64)).decode(), 1234)
        xml = release.make_appcast(*args)
        self.assertEqual(xml, release.make_appcast(*args))
        enclosure = ET.fromstring(xml).find("channel/item/enclosure")
        self.assertEqual(enclosure.attrib["url"], args[3])
        self.assertEqual(enclosure.attrib["length"], "1234")
        self.assertEqual(release.feed_names("beta"), {"appcast-beta.xml"})
        self.assertEqual(release.feed_names("stable"), {"appcast.xml", "appcast-beta.xml"})

    def test_publication_rejected_before_io(self):
        for env, publish in [({}, True), ({"RELEASE_REPOSITORY": "x2x3studio/other"}, False),
                             ({"PUBLIC_RELEASE_ACK": "wrong"}, True)]:
            with patch.dict(os.environ, env, clear=True), patch.object(release, "run") as run:
                with self.assertRaises(ValueError):
                    release.publish("/not/a/release", publish)
                run.assert_not_called()

    def fixture(self, directory, channel="beta", updater=False):
        version, build = "2026.1030.42", "1793318400"
        stem = f"Talkless-{version}-{build}-arm64"
        tag = release.release_tag(version, build, channel)
        base_url = f"https://github.com/{release.REPOSITORY}/releases/download/{tag}"
        files = {}
        for ext in ["zip", "dmg"]:
            path = directory / f"{stem}.{ext}"
            path.write_bytes(b"Mock archive; not signed release material")
        if updater:
            for name in release.feed_names(channel):
                (directory / name).write_bytes(release.make_appcast(
                    version, build, "15.0", base_url + f"/{stem}.zip", base64.b64encode(bytes(64)).decode(), 40))
        for path in directory.iterdir():
            if path.suffix in {".zip", ".dmg", ".xml"}:
                files[path.name] = {"sha256": release.sha256(path), "size": path.stat().st_size}
        metadata = {
            "schema_version": 1, "product": "Talkless", "version": version, "build_number": build,
            "tag": tag, "release_channel": channel, "source_commit": "a" * 40, "team_id": release.TEAM,
            "signing_identity": release.IDENTITY, "notarized": True, "stapled": True,
            "updater_enabled": updater, "files": files, "download_base_url": base_url,
            "update_feed_url": f"https://github.com/{release.REPOSITORY}/releases/download/updates/appcast.xml",
            "beta_update_feed_url": f"https://github.com/{release.REPOSITORY}/releases/download/updates/appcast-beta.xml",
        }
        (directory / "release-metadata.json").write_text(json.dumps(metadata))
        (directory / "SHA256SUMS").write_text("".join(f"{v['sha256']}  {k}\n" for k, v in sorted(files.items())))
        return metadata

    def test_draft_and_public_publish(self):
        for channel in ["beta", "stable"]:
            with tempfile.TemporaryDirectory() as temp:
                directory = Path(temp)
                metadata = self.fixture(directory, channel)
                calls = []

                def fake_run(args, **kwargs):
                    calls.append(args)
                    return json.dumps({"private": False}) if args[1] == "api" else ""

                with patch.dict(os.environ, {"PUBLIC_RELEASE_ACK": release.REPOSITORY}, clear=True), \
                        patch.object(release, "run", side_effect=fake_run):
                    release.publish(temp, False)
                    self.assertEqual(len(calls), 2)
                    self.assertIn("--draft", calls[1])
                    self.assertEqual("--prerelease" in calls[1], channel == "beta")
                    calls.clear()
                    release.publish(temp, True)
                    self.assertEqual(len(calls), 3)
                    self.assertIn("--draft=false", calls[2])
                    self.assertIn("--latest" if channel == "stable" else "--latest=false", calls[2])
                (directory / next(iter(metadata["files"]))).write_bytes(b"tampered")
                with patch.dict(os.environ, {"PUBLIC_RELEASE_ACK": release.REPOSITORY}, clear=True), \
                        patch.object(release, "run") as run:
                    with self.assertRaises(ValueError):
                        release.publish(temp, True)
                    run.assert_not_called()

    def test_feed_manifest_upload_is_last(self):
        for channel in ["beta", "stable"]:
            with tempfile.TemporaryDirectory() as temp:
                self.fixture(Path(temp), channel, updater=True)
                calls = []

                def fake_run(args, **kwargs):
                    calls.append(args)
                    if args[1] == "api":
                        return json.dumps({"private": False})
                    if args[1:3] == ["release", "view"]:
                        return json.dumps({"isDraft": False, "assets": []})
                    return ""

                with patch.dict(os.environ, {"PUBLIC_RELEASE_ACK": release.REPOSITORY}, clear=True), \
                        patch.object(release, "run", side_effect=fake_run):
                    release.publish(temp, True)
                self.assertEqual(calls[-2][1:3], ["release", "edit"])
                self.assertEqual(calls[-1][1:4], ["release", "upload", "updates"])
                self.assertIn("--clobber", calls[-1])
                uploaded = {Path(arg).name for arg in calls[-1] if arg.endswith(".xml")}
                self.assertEqual(uploaded, release.feed_names(channel))

    def test_empty_bootstrap_feeds_are_accepted(self):
        with tempfile.TemporaryDirectory() as temp:
            self.fixture(Path(temp), updater=True)
            calls = []

            def fake_run(args, **kwargs):
                calls.append(args)
                if args[1] == "api":
                    return json.dumps({"private": False})
                if args[1:3] == ["release", "view"]:
                    return json.dumps({"isDraft": False, "assets": [{"name": "appcast.xml"}]})
                if args[1:3] == ["release", "download"]:
                    (Path(args[-1]) / "appcast.xml").write_text('<rss version="2.0"><channel><title>Talkless</title></channel></rss>')
                return ""

            with patch.dict(os.environ, {"PUBLIC_RELEASE_ACK": release.REPOSITORY}, clear=True), \
                    patch.object(release, "run", side_effect=fake_run):
                release.publish(temp, True)
            self.assertEqual(calls[-1][1:4], ["release", "upload", "updates"])

    def test_feed_downgrade_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            metadata = self.fixture(Path(temp), updater=True)
            calls = []

            def fake_run(args, **kwargs):
                calls.append(args)
                if args[1] == "api":
                    return json.dumps({"private": False})
                if args[1:3] == ["release", "view"]:
                    return json.dumps({"isDraft": False, "assets": [{"name": "appcast.xml"}]})
                if args[1:3] == ["release", "download"]:
                    (Path(args[-1]) / "appcast.xml").write_bytes(release.make_appcast(
                        "2026.1030.42", metadata["build_number"], "15.0", "https://example.com/a.zip",
                        base64.b64encode(bytes(64)).decode(), 1))
                return ""

            with patch.dict(os.environ, {"PUBLIC_RELEASE_ACK": release.REPOSITORY}, clear=True), \
                    patch.object(release, "run", side_effect=fake_run):
                with self.assertRaisesRegex(ValueError, "BUILD_NUMBER must exceed"):
                    release.publish(temp, True)
            self.assertFalse(any(args[1:3] == ["release", "create"] for args in calls))

    def test_public_draft_needs_ack(self):
        with tempfile.TemporaryDirectory() as temp:
            self.fixture(Path(temp))
            with patch.dict(os.environ, {}, clear=True), \
                    patch.object(release, "run", return_value=json.dumps({"private": False})) as run:
                with self.assertRaises(ValueError):
                    release.publish(temp, False)
                self.assertEqual(run.call_count, 1)

    def test_notary_rejection(self):
        with tempfile.TemporaryDirectory() as temp:
            session = release.SigningSession(Path(temp), {})
            session.notary_key = Path(temp) / "nonsecret-fixture"
            session.notary_key_id = "fixture"
            session.notary_issuer = "fixture"
            with patch.object(release, "run", return_value='{"status":"Invalid"}'):
                with self.assertRaises(ValueError):
                    session.notarize(Path(temp) / "archive")


if __name__ == "__main__":
    unittest.main()
