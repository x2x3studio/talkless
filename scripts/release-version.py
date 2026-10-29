#!/usr/bin/env python3
"""Derive release versions without committing generated version bumps."""
import argparse
from datetime import datetime, timezone
import os
import re

VERSION = re.compile(r"v([0-9]+)\.([0-9]+)\.([0-9]+)$")


def derive(ref, now, build):
    if ref.startswith("refs/tags/"):
        tag = ref.removeprefix("refs/tags/")
        if not VERSION.fullmatch(tag):
            raise ValueError("Stable release tags must use vYEAR.MDD.UTC_SECONDS")
        version = tag[1:]
        year, month_day, seconds = map(int, VERSION.fullmatch(tag).groups())
        datetime(year, month_day // 100, month_day % 100, tzinfo=timezone.utc)
        if not 0 <= seconds < 86400:
            raise ValueError("Version seconds must be within a UTC day")
        channel = "stable"
    elif ref == "refs/heads/main":
        seconds = now.hour * 3600 + now.minute * 60 + now.second
        version = f"{now.year}.{now.month * 100 + now.day}.{seconds}"
        channel = "beta"
        tag = f"v{version}-beta.{build}"
    else:
        raise ValueError("Releases run only for main or a stable version tag")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Invalid application version")
    if not re.fullmatch(r"[1-9][0-9]*", str(build)):
        raise ValueError("Invalid build number")
    return {"VERSION": version, "BUILD_NUMBER": str(build), "RELEASE_CHANNEL": channel, "RELEASE_TAG": tag}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ref", default=os.environ.get("GITHUB_REF"))
    parser.add_argument("--build-number")
    args = parser.parse_args()
    now = datetime.now(timezone.utc)
    # Assigned when the serialized release job starts, not when it was queued.
    build = args.build_number or str(int(now.timestamp()))
    result = derive(args.ref or "", now, build)
    lines = "".join(f"{key}={value}\n" for key, value in result.items())
    print(lines, end="")
    if destination := os.environ.get("GITHUB_ENV"):
        with open(destination, "a") as output:
            output.write(lines)


if __name__ == "__main__":
    main()
