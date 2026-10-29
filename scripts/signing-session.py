#!/usr/bin/env python3
"""Local Developer ID release session; secrets never leave an owned temp directory."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
IDENTITY = "Developer ID Application: Shanghai Gotehab Information Technology Co., Ltd (AXJQF2CMF2)"
TEAM = "AXJQF2CMF2"
REPOSITORY = "x2x3studio/talkless"
SECRET_REFS = ("SIGNING_CERTIFICATE_REF", "SIGNING_PASSWORD_REF", "NOTARY_KEY_REF",
               "NOTARY_KEY_ID_REF", "NOTARY_ISSUER_REF")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def validate_version(version: str, build: str) -> None:
    require(bool(re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version)),
            "VERSION must be three non-negative integers, for example 0.1.0.")
    require(bool(re.fullmatch(r"[1-9][0-9]{0,17}", build)),
            "BUILD_NUMBER must be a positive integer of at most eighteen digits.")


def https_url(value: str, name: str) -> str:
    parsed = urlsplit(value)
    require(parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username
            and not parsed.password and not parsed.query and not parsed.fragment
            and not any(c.isspace() for c in value),
            f"{name} must be an HTTPS URL without credentials, query, fragment, or whitespace.")
    return value


def release_tag(version: str, build: str, channel: str) -> str:
    require(channel in ("beta", "stable"), "RELEASE_CHANNEL must be beta or stable.")
    return f"v{version}-beta.{build}" if channel == "beta" else f"v{version}"


def feed_names(channel: str) -> set[str]:
    return {"appcast-beta.xml"} if channel == "beta" else {"appcast.xml", "appcast-beta.xml"}


def updater_config(env: dict[str, str]) -> dict[str, str]:
    names = ("UPDATE_FEED_URL", "BETA_UPDATE_FEED_URL", "SPARKLE_PUBLIC_KEY", "TALKLESS_SPARKLE_KEY_REF", "DOWNLOAD_BASE_URL")
    values = {name: env.get(name, "").strip() for name in names}
    if not any(values.values()):
        return {}
    require(all(values.values()), "Updater configuration is incomplete: set all of " + ", ".join(names) + ", or none.")
    https_url(values["UPDATE_FEED_URL"], "UPDATE_FEED_URL")
    https_url(values["BETA_UPDATE_FEED_URL"], "BETA_UPDATE_FEED_URL")
    require(values["UPDATE_FEED_URL"] != values["BETA_UPDATE_FEED_URL"], "Stable and beta feeds must have distinct URLs.")
    values["DOWNLOAD_BASE_URL"] = https_url(values["DOWNLOAD_BASE_URL"], "DOWNLOAD_BASE_URL").rstrip("/")
    try:
        key = base64.b64decode(values["SPARKLE_PUBLIC_KEY"], validate=True)
    except ValueError:
        key = b""
    require(len(key) == 32, "SPARKLE_PUBLIC_KEY must be a base64-encoded 32-byte Ed25519 public key.")
    require(values["TALKLESS_SPARKLE_KEY_REF"].startswith("op://"), "TALKLESS_SPARKLE_KEY_REF must be an op:// reference.")
    return values


def run(args: list[str], *, env: dict[str, str] | None = None, sensitive: bool = False) -> str:
    # Always capture subprocess output. In particular, security/op errors can echo credentials.
    if env is None:
        env = os.environ.copy()
        env.pop("OP_SERVICE_ACCOUNT_TOKEN", None)
    result = subprocess.run(args, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        if not sensitive:
            sys.stderr.write(result.stderr.decode("utf-8", errors="replace"))
        raise RuntimeError(f"{Path(args[0]).name} failed (exit {result.returncode}); "
                           + ("credential command output suppressed." if sensitive else "release stopped."))
    return result.stdout.decode("utf-8", errors="strict")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def make_appcast(version: str, build: str, minimum_os: str, download_url: str,
                 signature: str, length: int) -> bytes:
    require(len(base64.b64decode(signature, validate=True)) == 64, "Invalid Sparkle signature length.")
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Talkless Updates"
    ET.SubElement(channel, "language").text = "en"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Talkless {version}"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = minimum_os
    ET.SubElement(item, "enclosure", {
        "url": download_url, "length": str(length), "type": "application/octet-stream",
        f"{{{SPARKLE_NS}}}edSignature": signature,
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


class SigningSession:
    def __init__(self, directory: Path, env: dict[str, str]):
        self.directory = directory
        self.env = env
        self.keychain = directory / "talkless-signing.keychain-db"
        self.keychain_created = False

    def read_secret(self, ref: str) -> bytes:
        require(ref.startswith("op://"), "Secret references must start with op://.")
        return run(["op", "read", "--no-newline", ref], env=self.env, sensitive=True).encode()

    def prepare(self, config: dict[str, str]) -> None:
        if not self.env.get("OP_SERVICE_ACCOUNT_TOKEN"):
            self.env["OP_SERVICE_ACCOUNT_TOKEN"] = run([
                "/bin/zsh", "-f", "-c",
                'set +x; source "$HOME/.config/secrets.zsh" >/dev/null 2>&1; '
                'set +x; print -rn -- "${OP_SERVICE_ACCOUNT_TOKEN:-}"',
            ], env=self.env, sensitive=True)
        require(bool(self.env.get("OP_SERVICE_ACCOUNT_TOKEN")), "1Password service account token is unavailable.")
        refs = {name: self.env.get(name, "") for name in SECRET_REFS}
        require(all(value.startswith("op://") for value in refs.values()),
                "Configure op:// references for " + ", ".join(SECRET_REFS) + ".")
        certificate = self.directory / "certificate.p12"
        encoded = self.read_secret(refs["SIGNING_CERTIFICATE_REF"])
        certificate.write_bytes(base64.b64decode(b"".join(encoded.split()), validate=True))
        password = self.read_secret(refs["SIGNING_PASSWORD_REF"]).decode()
        self.notary_key = self.directory / "AuthKey.p8"
        self.notary_key.write_bytes(self.read_secret(refs["NOTARY_KEY_REF"]))
        self.notary_key_id = self.read_secret(refs["NOTARY_KEY_ID_REF"]).decode()
        self.notary_issuer = self.read_secret(refs["NOTARY_ISSUER_REF"]).decode()
        if config:
            (self.directory / "sparkle-key").write_bytes(self.read_secret(config["TALKLESS_SPARKLE_KEY_REF"]))
        self.env.pop("OP_SERVICE_ACCOUNT_TOKEN", None)
        keychain_password = secrets.token_hex(24)
        self.keychain_created = True  # Also clean up a partially successful create.
        run(["security", "create-keychain", "-p", keychain_password, str(self.keychain)], sensitive=True)
        run(["security", "set-keychain-settings", "-lut", "7200", str(self.keychain)], sensitive=True)
        run(["security", "unlock-keychain", "-p", keychain_password, str(self.keychain)], sensitive=True)
        run(["security", "import", str(certificate), "-k", str(self.keychain), "-P", password,
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], sensitive=True)
        run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
             "-s", "-k", keychain_password, str(self.keychain)], sensitive=True)
        certificate.unlink()
        # Never add this keychain to the user's global search list or change the default keychain.
        self.env.update(CODE_SIGN_IDENTITY=IDENTITY, SIGNING_KEYCHAIN=str(self.keychain))

    def close(self) -> None:
        self.env.pop("OP_SERVICE_ACCOUNT_TOKEN", None)
        if self.keychain_created:
            subprocess.run(["security", "delete-keychain", str(self.keychain)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def notarize(self, artifact: Path) -> None:
        result = run(["xcrun", "notarytool", "submit", str(artifact), "--key", str(self.notary_key),
                      "--key-id", self.notary_key_id, "--issuer", self.notary_issuer,
                      "--wait", "--timeout", "30m", "--output-format", "json"], sensitive=True)
        require(json.loads(result).get("status") == "Accepted", "Apple did not accept notarization; no release artifacts will be promoted.")

    def staple(self, path: Path) -> None:
        for attempt in range(1, 41):
            result = subprocess.run(["xcrun", "stapler", "staple", str(path)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode == 0:
                run(["xcrun", "stapler", "validate", str(path)])
                return
            if attempt < 40:
                print(f"Stapling attempt {attempt}/40 failed; retrying in 30 seconds.", flush=True)
                time.sleep(30)
        raise RuntimeError("Could not staple the notarization ticket after 40 attempts.")


def verify_signature(path: Path) -> None:
    run(["codesign", "--verify", "--deep", "--strict", str(path)])
    # codesign -d writes its successful display output to stderr.
    result = subprocess.run(["codesign", "-d", "--verbose=4", str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    details = result.stderr.decode("utf-8", errors="replace").splitlines()
    require(result.returncode == 0 and f"TeamIdentifier={TEAM}" in details
            and f"Authority={IDENTITY}" in details
            and any(line.startswith("Timestamp=") for line in details),
            "Signature is missing the expected Developer ID, Team ID, or secure timestamp.")


def sign_appcast(stage: Path, archive: Path, config: dict[str, str], version: str,
                 build: str, minimum_os: str, channel: str, session: SigningSession) -> None:
    configured = os.environ.get("SPARKLE_SIGN_UPDATE")
    tools = [Path(configured).expanduser().resolve()] if configured else list((ROOT / ".build/artifacts").glob("**/bin/sign_update"))
    require(len(tools) == 1 and tools[0].is_file(),
            "Sparkle sign_update was not found uniquely. Set SPARKLE_SIGN_UPDATE to the pinned Sparkle distribution's bin/sign_update.")
    signature = run([str(tools[0]), "--ed-key-file", str(session.directory / "sparkle-key"),
                     "-p", str(archive)], env=session.env, sensitive=True).strip()
    # Check against the public key embedded in the app, not merely the private file's own public half.
    verifier = session.directory / "verify-sparkle.swift"
    verifier.write_text('''import CryptoKit
import Foundation
let args = CommandLine.arguments
let archive = try Data(contentsOf: URL(fileURLWithPath: args[1]))
guard let signature = Data(base64Encoded: args[2]), let rawKey = Data(base64Encoded: args[3]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
guard key.isValidSignature(signature, for: archive) else { exit(1) }
''')
    run(["swift", str(verifier), str(archive), signature, config["SPARKLE_PUBLIC_KEY"]], env=session.env)
    appcast = make_appcast(version, build, minimum_os, config["DOWNLOAD_BASE_URL"] + "/" + archive.name,
                           signature, archive.stat().st_size)
    for name in feed_names(channel):
        (stage / name).write_bytes(appcast)


def release(version: str, build: str) -> None:
    validate_version(version, build)
    env = os.environ.copy()
    channel = env.get("RELEASE_CHANNEL", "beta")
    tag = release_tag(version, build, channel)
    config = updater_config(env)
    require(sys.platform == "darwin" and os.uname().machine == "arm64", "Release builds require an Apple Silicon Mac.")
    for tool in ("op", "security", "codesign", "xcrun", "swift", "ditto", "hdiutil", "git"):
        require(shutil.which(tool) is not None, f"Required tool is unavailable: {tool}")
    commit = run(["git", "rev-parse", "HEAD"]).strip()
    require(not run(["git", "status", "--porcelain"]).strip(), "Commit or stash working-tree changes before building a release.")
    releases = ROOT / "dist/releases"
    releases.mkdir(parents=True, exist_ok=True)
    destination = releases / f"{version}-{build}"
    require(not destination.exists(), f"Release output already exists: {destination}")
    lock = ROOT / "dist/.release-lock"
    try:
        lock.mkdir()
    except FileExistsError:
        raise ValueError("Another release may be running (dist/.release-lock exists). Do not share dist with another build.") from None
    try:
        temporary_root = Path(tempfile.gettempdir()).resolve()
        require(temporary_root != ROOT and ROOT not in temporary_root.parents,
                "TMPDIR must be outside the project for signing secrets.")
        with tempfile.TemporaryDirectory(prefix="talkless-signing-", dir=temporary_root) as secret_dir, \
                tempfile.TemporaryDirectory(prefix=".talkless-release-", dir=releases) as stage_dir:
            stage = Path(stage_dir)
            session = SigningSession(Path(secret_dir), env)
            old_umask = os.umask(0o077)
            try:
                print("Preparing a temporary signing session (credential output is suppressed).", flush=True)
                session.prepare(config)
                os.umask(old_umask)
                env.update(VERSION=version, BUILD_NUMBER=build, CONFIGURATION="release", RELEASE_CHANNEL=channel)
                env.update(UPDATE_FEED_URL=config.get("UPDATE_FEED_URL", ""),
                           BETA_UPDATE_FEED_URL=config.get("BETA_UPDATE_FEED_URL", ""),
                           SPARKLE_PUBLIC_KEY=config.get("SPARKLE_PUBLIC_KEY", ""))
                print("Building Talkless with " + ("signed Sparkle updates." if config else "updater disabled (signed test release)."), flush=True)
                run(["/bin/bash", str(ROOT / "scripts/build-app.sh")], env=env)
                app = ROOT / "dist/Talkless.app"
                info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                require(info.get("CFBundleShortVersionString") == version and info.get("CFBundleVersion") == build,
                        "Built app version/build does not match the requested release.")
                require(info.get("SUFeedURL", "") == config.get("UPDATE_FEED_URL", "")
                        and info.get("SUBetaFeedURL", "") == config.get("BETA_UPDATE_FEED_URL", "")
                        and info.get("TalklessDefaultUpdateChannel") == channel
                        and info.get("SUPublicEDKey", "") == config.get("SPARKLE_PUBLIC_KEY", ""),
                        "Built app updater configuration does not match the release configuration.")
                verify_signature(app)
                submission = session.directory / "notarize-app.zip"
                run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(submission)])
                print("Submitting the app for notarization.", flush=True)
                session.notarize(submission)
                session.staple(app)
                verify_signature(app)
                image_source = session.directory / "dmg-root"
                image_source.mkdir()
                run(["ditto", str(app), str(image_source / "Talkless.app")])
                (image_source / "Applications").symlink_to("/Applications")
                stem = f"Talkless-{version}-{build}-arm64"
                dmg = stage / f"{stem}.dmg"
                run(["hdiutil", "create", "-volname", "Talkless", "-srcfolder", str(image_source),
                     "-format", "UDZO", "-fs", "HFS+", str(dmg)])
                run(["codesign", "--force", "--sign", IDENTITY, "--keychain", str(session.keychain),
                     "--timestamp", str(dmg)])
                verify_signature(dmg)
                print("Submitting the disk image for notarization.", flush=True)
                session.notarize(dmg)
                session.staple(dmg)
                verify_signature(dmg)
                # The final ZIP is created only after app stapling. Never mutate either final archive after signing/checksums.
                archive = stage / f"{stem}.zip"
                run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)])
                if config:
                    sign_appcast(stage, archive, config, version, build, info["LSMinimumSystemVersion"], channel, session)
                files = {p.name: {"sha256": sha256(p), "size": p.stat().st_size} for p in sorted(stage.iterdir())}
                (stage / "SHA256SUMS").write_text("".join(f"{item['sha256']}  {name}\n" for name, item in files.items()))
                metadata = {
                    "schema_version": 1, "product": "Talkless", "version": version, "build_number": build,
                    "tag": tag, "release_channel": channel, "architecture": "arm64", "source_commit": commit,
                    "signing_identity": IDENTITY, "team_id": TEAM, "notarized": True, "stapled": True,
                    "updater_enabled": bool(config), "update_feed_url": config.get("UPDATE_FEED_URL"),
                    "beta_update_feed_url": config.get("BETA_UPDATE_FEED_URL"),
                    "download_base_url": config.get("DOWNLOAD_BASE_URL"), "files": files,
                }
                (stage / "release-metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
                # No partially signed artifacts become a release directory.
                require(not destination.exists(), "Release destination appeared during the build; refusing to overwrite it.")
                stage.rename(destination)
            finally:
                os.umask(old_umask)
                session.close()
    finally:
        lock.rmdir()
    print(f"Release artifacts: {destination}\nNothing was published.")


def publish(directory: str, publish_public: bool) -> None:
    repository = os.environ.get("RELEASE_REPOSITORY", REPOSITORY)
    require(repository == REPOSITORY, "RELEASE_REPOSITORY must be x2x3studio/talkless.")
    acknowledged = os.environ.get("PUBLIC_RELEASE_ACK") == repository
    require(not publish_public or acknowledged,
            "Public publication requires --publish and PUBLIC_RELEASE_ACK=x2x3studio/talkless.")
    directory_path = Path(directory).expanduser().resolve()
    metadata = json.loads((directory_path / "release-metadata.json").read_text())
    validate_version(metadata["version"], metadata["build_number"])
    require(metadata.get("schema_version") == 1 and metadata.get("product") == "Talkless"
            and metadata.get("team_id") == TEAM and metadata.get("signing_identity") == IDENTITY
            and metadata.get("notarized") is True and metadata.get("stapled") is True,
            "Release metadata does not describe a signed, notarized Talkless release.")
    channel = metadata["release_channel"]
    require(metadata["tag"] == release_tag(metadata["version"], metadata["build_number"], channel)
            and bool(re.fullmatch(r"[0-9a-f]{40}", metadata["source_commit"])),
            "Release tag or source commit is invalid.")
    stem = f"Talkless-{metadata['version']}-{metadata['build_number']}-arm64"
    expected = {f"{stem}.zip", f"{stem}.dmg"}
    if metadata["updater_enabled"]:
        expected.update(feed_names(channel))
        if publish_public:
            require(metadata["download_base_url"] == f"https://github.com/{repository}/releases/download/{metadata['tag']}",
                    "The appcast download base must match this public repository and release tag.")
            require(metadata["update_feed_url"] == f"https://github.com/{repository}/releases/download/updates/appcast.xml"
                    and metadata["beta_update_feed_url"] == f"https://github.com/{repository}/releases/download/updates/appcast-beta.xml",
                    "Public feeds must use the pre-provisioned updates release asset URLs.")
    require(set(metadata["files"]) == expected, "Unexpected or missing release assets in metadata.")
    for name, item in metadata["files"].items():
        path = directory_path / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size == item["size"]
                and sha256(path) == item["sha256"], f"Release artifact has changed: {name}")
    checksum_text = "".join(f"{item['sha256']}  {name}\n" for name, item in sorted(metadata["files"].items()))
    require((directory_path / "SHA256SUMS").read_text() == checksum_text, "SHA256SUMS does not match release metadata.")
    # Query only: this script never creates or changes repository visibility.
    repo = json.loads(run(["gh", "api", f"repos/{repository}"]))
    require(repo.get("private") is True or acknowledged,
            "Uploading even a draft to the public repository requires PUBLIC_RELEASE_ACK=x2x3studio/talkless.")
    require(not publish_public or repo.get("private") is False, "--publish requires the repository to be public.")
    if publish_public and metadata["updater_enabled"]:
        # Require the owner to provision the mutable feed release; never create it implicitly.
        feeds = json.loads(run(["gh", "release", "view", "updates", "--repo", repository,
                               "--json", "isDraft,assets"]))
        require(feeds.get("isDraft") is False, "The pre-provisioned updates release must already be published.")
        with tempfile.TemporaryDirectory(prefix="talkless-feed-check-") as temporary:
            for asset in feeds["assets"]:
                if asset["name"] not in feed_names("stable"):
                    continue
                run(["gh", "release", "download", "updates", "--repo", repository, "--pattern", asset["name"], "--dir", temporary])
                document = ET.parse(Path(temporary) / asset["name"])
                existing_builds = [int(node.text or "0") for node in document.findall(f".//{{{SPARKLE_NS}}}version")]
                require(document.getroot().tag == "rss" and document.find("channel") is not None,
                        "Existing update feed is not an RSS channel.")
                require(not document.findall("channel/item") or existing_builds,
                        "Existing update feed items have no Sparkle build numbers.")
                require(int(metadata["build_number"]) > max(existing_builds, default=0),
                        "BUILD_NUMBER must exceed every currently published stable/beta feed build.")
    tag = metadata["tag"]
    notes = (f"Talkless {metadata['version']} {channel} (build {metadata['build_number']}) for Apple Silicon.\n\n"
             "Developer ID signed and notarized ZIP and disk image. "
             + ("Sparkle updates are enabled.\n" if metadata["updater_enabled"] else "Automatic updates are disabled in this signed test release.\n"))
    args = ["gh", "release", "create", tag, "--repo", repository, "--draft", "--title",
            f"Talkless {metadata['version']}", "--notes", notes]
    if channel == "beta":
        args += ["--prerelease"]
    args += ["--target", metadata["source_commit"]]
    args += [str(directory_path / name) for name in sorted(expected | {"SHA256SUMS", "release-metadata.json"})]
    # No clobber/update path: an existing tag's release must be handled manually.
    run(args)
    if publish_public:
        run(["gh", "release", "edit", tag, "--repo", repository, "--draft=false",
             "--latest" if channel == "stable" else "--latest=false"])
        if metadata["updater_enabled"]:
            # Final manifests are replaced only after all immutable assets are publicly available.
            # GitHub does not offer a transaction across assets: serialize public publication jobs.
            run(["gh", "release", "upload", "updates", "--repo", repository, "--clobber"]
                + [str(directory_path / name) for name in sorted(feed_names(channel))])
    print(f"{'Published' if publish_public else 'Created draft'}: {repository} {tag}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("release", help="Build signed, notarized ZIP/DMG locally; never publish")
    build.add_argument("version")
    build.add_argument("build_number")
    upload = commands.add_parser("publish", help="Create a draft by default; require acknowledgement for the public repository")
    upload.add_argument("directory")
    upload.add_argument("--publish", action="store_true", help="Explicitly publish to the existing public Talkless repository")
    args = parser.parse_args()
    # SIGTERM must unwind finally blocks just like Ctrl-C so our own keychain is deleted.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        if args.command == "release":
            release(args.version, args.build_number)
        else:
            publish(args.directory, args.publish)
    except (ValueError, RuntimeError, OSError, KeyError) as error:
        print(f"Release error: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
