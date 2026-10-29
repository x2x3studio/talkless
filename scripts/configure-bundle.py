#!/usr/bin/env python3
"""Apply version and public updater configuration to a generated app bundle."""
import base64
import os
from pathlib import Path
import plistlib
import re
import sys
from urllib.parse import urlparse


def configure(info, environment):
    version = environment.get("VERSION", info["CFBundleShortVersionString"])
    build = environment.get("BUILD_NUMBER", info["CFBundleVersion"])
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("VERSION must have three numeric components")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("BUILD_NUMBER must be a positive integer")
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = build
    feed = environment.get("UPDATE_FEED_URL", "").strip()
    beta_feed = environment.get("BETA_UPDATE_FEED_URL", "").strip()
    key = environment.get("SPARKLE_PUBLIC_KEY", "").strip()
    channel = environment.get("RELEASE_CHANNEL", "beta")
    if channel not in {"beta", "stable"}:
        raise ValueError("RELEASE_CHANNEL must be beta or stable")
    info["TalklessDefaultUpdateChannel"] = channel
    if any((feed, beta_feed, key)) and not all((feed, beta_feed, key)):
        raise ValueError("Both update feed URLs and SPARKLE_PUBLIC_KEY must be provided together")
    for name in ("SUFeedURL", "SUBetaFeedURL", "SUPublicEDKey"):
        info.pop(name, None)
    if feed:
        for address in (feed, beta_feed):
            url = urlparse(address)
            if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment:
                raise ValueError("Update feed URLs must use HTTPS without credentials, query or fragment")
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError("SPARKLE_PUBLIC_KEY must encode a 32-byte Ed25519 public key")
        info["SUFeedURL"] = feed
        info["SUBetaFeedURL"] = beta_feed
        info["SUPublicEDKey"] = key
    info["SUEnableAutomaticChecks"] = bool(feed)
    info["SUAutomaticallyUpdate"] = False
    info["SUAllowsAutomaticUpdates"] = False
    info["SUSendProfileInfo"] = False
    return info


def main():
    path = Path(sys.argv[1])
    with path.open("rb") as source:
        info = plistlib.load(source)
    info = configure(info, os.environ)
    with path.open("wb") as output:
        plistlib.dump(info, output, sort_keys=False)


if __name__ == "__main__":
    main()
