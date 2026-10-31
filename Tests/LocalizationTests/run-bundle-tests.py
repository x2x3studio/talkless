#!/usr/bin/env python3
"""Relocation regressions against SwiftPM's real (unpatched) resource accessor."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/Talkless"


def run(executable, *arguments, expected=0):
    result = subprocess.run([str(executable), *arguments], cwd="/", capture_output=True, text=True, timeout=20)
    assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)


def table(path, values):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(values))


with tempfile.TemporaryDirectory(prefix="talkless-real-accessor-tests-") as temporary:
    work = Path(temporary)
    package = work / "Package"
    target = package / "Sources/Talkless"
    target.mkdir(parents=True)
    for name in ["L10n.swift", "BundleValidation.swift"]:
        shutil.copy2(SOURCE / name, target / name)
    shutil.copy2(ROOT / "Tests/LocalizationTests/BundleProbe.swift", target / "BundleProbe.swift")
    shutil.copytree(SOURCE / "Resources", target / "Resources")
    # No dependencies, generated-accessor patches, or replacement Bundle.module.
    (package / "Package.swift").write_text('''// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "Talkless", defaultLocalization: "en",
    platforms: [.macOS(.v26)], targets: [
        .executableTarget(name: "Talkless", resources: [.process("Resources")])
    ])
''')
    subprocess.run(["swift", "build", "--package-path", str(package), "--build-system", "native"], check=True)
    bin_path = Path(subprocess.check_output([
        "swift", "build", "--package-path", str(package), "--build-system", "native", "--show-bin-path"
    ], text=True).strip())
    accessors = list((package / ".build").glob("**/DerivedSources/resource_bundle_accessor.swift"))
    assert accessors and "fatalError" in accessors[0].read_text(), "Must exercise a genuine fallible SwiftPM accessor"
    development = run(bin_path / "Talkless")
    assert not development["packaged"] and development["chinese"] == "\U00008ddf\U0000968f\U00007cfb\U00007edf"

    # Launch only the tiny Foundation-only test fixture, never the product app.
    original = work / "Original Location/Bundle Probe.app"
    resources = original / "Contents/Resources"
    executable = original / "Contents/MacOS/Talkless"
    executable.parent.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copy2(bin_path / "Talkless", executable)
    table(original / "Contents/Info.plist", {
        "CFBundleExecutable": "Talkless", "CFBundleIdentifier": "test.talkless.bundle-probe",
        "CFBundlePackageType": "APPL", "CFBundleName": "Bundle Probe",
        "CFBundleVersion": "1", "CFBundleDevelopmentRegion": "en",
    })
    shutil.copytree(bin_path / "Talkless_Talkless.bundle", resources / "Talkless_Talkless.bundle")
    required = ["Talkless_Talkless.bundle", "swift-transformers_Hub.bundle", "swift-crypto_Crypto.bundle"]
    for name in required[1:]:
        (resources / name).mkdir()
        table(resources / name / "Info.plist", {"CFBundleIdentifier": "test." + name})
    (resources / "swift-transformers_Hub.bundle/gpt2_tokenizer_config.json").write_text('{"tokenizer_class":"GPT2Tokenizer"}')
    (resources / "SwiftPMResourceBundles.json").write_text(json.dumps(required))
    for language in ["en", "zh-Hans"]:
        folder = resources / (language + ".lproj")
        folder.mkdir()
        shutil.copy2(SOURCE / "Resources" / (language + ".lproj") / "InfoPlist.strings", folder)
    for relative in ["Contents/MacOS/mlx.metallib", "Contents/Resources/AppIcon.icns", "Contents/Frameworks/Sparkle.framework/Sparkle"]:
        path = original / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture-resource")

    moved = work / "Moved Location/Relocated App.app"
    moved.parent.mkdir()
    shutil.move(original, moved)
    executable = moved / "Contents/MacOS/Talkless"
    resources = moved / "Contents/Resources"
    localization = resources / "Talkless_Talkless.bundle"
    result = run(executable)
    assert result["packaged"] and result["chinese"] == "\U00008ddf\U0000968f\U00007cfb\U00007edf"
    assert Path(result["bundlePath"]).resolve() == localization.resolve(), (result, str(localization.resolve()))
    assert result["missingKey"] == result["globalLookup"] == "Readable missing English key"
    report = run(executable, "--verify-bundle")
    assert report["status"] == "ok" and report["localizations"] == ["en", "zh-Hans"]
    assert Path(report["localizationBundlePath"]).resolve() == localization.resolve()
    assert all(Path(path).resolve().is_relative_to(moved.resolve()) for path in report["resourceBundlePaths"].values())

    # Missing .app resources must not silently use a live developer build bundle.
    hidden = work / "hidden-localization.bundle"
    shutil.move(localization, hidden)
    missing = run(executable)
    assert missing["bundlePath"] == "" and missing["chinese"] == "Follow System"
    report = run(executable, "--verify-bundle", expected=1)
    assert "localization_bundle_missing" in report["errors"]
    # Nor may the accessor trap when its baked-in development fallback disappears.
    shutil.move(bin_path / "Talkless_Talkless.bundle", work / "hidden-build.bundle")
    assert run(executable)["chinese"] == "Follow System"
    shutil.move(hidden, localization)
    assert run(executable)["chinese"] == "\U00008ddf\U0000968f\U00007cfb\U00007edf"

    # Internal compatibility alias works, but an external symlink cannot escape.
    root_bundle = moved / "Talkless_Talkless.bundle"
    root_bundle.symlink_to("Contents/Resources/Talkless_Talkless.bundle")
    assert Path(run(executable)["bundlePath"]).resolve() == localization.resolve()
    root_bundle.unlink()
    shutil.move(localization, root_bundle)
    assert Path(run(executable)["bundlePath"]).resolve() == root_bundle.resolve()
    # Release preflight rejects nonstandard root-only resources even if UI can read them.
    assert "resource_bundle_missing:Talkless_Talkless.bundle" in run(executable, "--verify-bundle", expected=1)["errors"]
    shutil.move(root_bundle, hidden)
    localization.symlink_to(hidden)
    assert run(executable)["bundlePath"] == ""
    localization.unlink()
    shutil.move(hidden, localization)

    # Nested symlinks cannot bypass the outer bundle containment check at runtime.
    chinese = localization / "zh-hans.lproj"
    external_chinese = work / "external-chinese.lproj"
    shutil.move(chinese, external_chinese)
    chinese.symlink_to(external_chinese)
    assert run(executable)["chinese"] == "Follow System"
    assert "localization_missing_or_invalid:zh-Hans" in run(executable, "--verify-bundle", expected=1)["errors"]
    chinese.unlink()
    shutil.move(external_chinese, chinese)
    strings = chinese / "Localizable.strings"
    external_strings = work / "external.strings"
    shutil.move(strings, external_strings)
    strings.symlink_to(external_strings)
    assert run(executable)["chinese"] == "Follow System"
    assert "localization_missing_or_invalid:zh-Hans" in run(executable, "--verify-bundle", expected=1)["errors"]
    strings.unlink()
    shutil.move(external_strings, strings)
    stringsdict = chinese / "Localizable.stringsdict"
    external_dictionary = work / "external.stringsdict"
    external_dictionary.write_bytes(plistlib.dumps({}))
    stringsdict.symlink_to(external_dictionary)
    assert run(executable)["chinese"] == "Follow System"
    stringsdict.unlink()
    assert run(executable)["chinese"] == "\U00008ddf\U0000968f\U00007cfb\U00007edf"

    # Both supported language catalogs and localized permission prompts are required.
    shutil.move(chinese, work / "hidden-chinese.lproj")
    report = run(executable, "--verify-bundle", expected=1)
    assert "localization_missing_or_invalid:zh-Hans" in report["errors"]
    shutil.move(work / "hidden-chinese.lproj", chinese)
    strings = chinese / "Localizable.strings"
    original_strings = strings.read_bytes()
    strings.write_text("not a valid strings table")
    assert "localization_missing_or_invalid:zh-Hans" in run(executable, "--verify-bundle", expected=1)["errors"]
    strings.write_bytes(original_strings)
    permission = resources / "en.lproj/InfoPlist.strings"
    saved_permission = permission.read_bytes()
    permission.unlink()
    assert any(error.startswith("permission_localization_missing:en:") for error in run(executable, "--verify-bundle", expected=1)["errors"])
    permission.write_bytes(saved_permission)
    manifest = resources / "SwiftPMResourceBundles.json"
    manifest.write_text(json.dumps(required + ["../outside.bundle"]))
    assert "resource_bundle_manifest_missing_or_invalid" in run(executable, "--verify-bundle", expected=1)["errors"]
    manifest.write_text(json.dumps(required))
    # Transitive bundle contents must not redirect the real Hub probe outside app.
    hub = resources / "swift-transformers_Hub.bundle"
    external_config = work / "external-tokenizer.json"
    external_config.write_text('{"tokenizer_class":"GPT2Tokenizer"}')
    config_link = hub / "gpt2_tokenizer_config.json"
    original_config = config_link.read_bytes()
    for invalid in ["not JSON", "[]", '"scalar"', '{"tokenizer_class":"unexpected"}']:
        config_link.write_text(invalid)
        assert "hub_probe_resource_missing_or_invalid" in run(executable, "--verify-bundle", expected=1)["errors"]
    config_link.unlink()
    config_link.symlink_to(external_config)
    assert "resource_bundle_external_or_unreadable:swift-transformers_Hub.bundle" in run(executable, "--verify-bundle", expected=1)["errors"]
    config_link.unlink()
    config_link.write_bytes(original_config)
    external_folder = work / "external-hub-resources"
    external_folder.mkdir()
    nested_link = hub / "NestedResources"
    nested_link.symlink_to(external_folder)
    assert "resource_bundle_external_or_unreadable:swift-transformers_Hub.bundle" in run(executable, "--verify-bundle", expected=1)["errors"]
    nested_link.unlink()
    # Following internal directory aliases must also validate their descendants.
    internal_folder = resources / "SharedHubResources"
    internal_folder.mkdir()
    (internal_folder / "config.json").symlink_to(external_config)
    nested_link.symlink_to(internal_folder)
    assert "resource_bundle_external_or_unreadable:swift-transformers_Hub.bundle" in run(executable, "--verify-bundle", expected=1)["errors"]
    nested_link.unlink()
    shutil.rmtree(internal_folder)
    assert run(executable, "--verify-bundle")["status"] == "ok"
    shutil.rmtree(resources / "swift-transformers_Hub.bundle")
    assert "resource_bundle_missing:swift-transformers_Hub.bundle" in run(executable, "--verify-bundle", expected=1)["errors"]

# The production verifier branch must stay before every startup side effect.
app_source = (SOURCE / "App.swift").read_text()
verify = app_source.index('CommandLine.arguments.contains("--verify-bundle")')
assert verify < app_source.index("Diagnostics.shared.startSession()") < app_source.index("let app = NSApplication.shared")
assert verify < app_source.index("let delegate = AppDelegate()")
assert "LocalizationSettings" not in (SOURCE / "BundleValidation.swift").read_text()
print("Bundle regressions passed (real generated accessor, CLI fallback, relocated .app, missing/external resources, bilingual verification and startup ordering).")
