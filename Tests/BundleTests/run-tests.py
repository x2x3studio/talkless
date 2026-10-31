#!/usr/bin/env python3
"""Clean real SwiftPM compilation, sealed app relocation, and no-build-fallback regression."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(arguments, *, env=None, expected=0):
    result = subprocess.run([str(arg) for arg in arguments], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
    if result.returncode != expected:
        raise AssertionError(f"{arguments[0]} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def write(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)


run(["swift", "build", "--package-path", ROOT / "Tools/ReleaseTool", "--build-system", "native"])
tool_bin = Path(run(["swift", "build", "--package-path", ROOT / "Tools/ReleaseTool",
                     "--build-system", "native", "--show-bin-path"]).strip()) / "ReleaseTool"
with tempfile.TemporaryDirectory(prefix="talkless-bundle-test-", dir="/tmp") as temporary:
    root = Path(temporary).resolve()
    package = root / "package with spaces"
    build = root / "build with spaces"
    owned_inputs = root / "compiler owned_inputs"
    write(package / "Package.swift", '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Fixture", platforms: [.macOS(.v13)], targets: [
    .target(name: "Dependency", resources: [.copy("dependency.txt")]),
    .executableTarget(name: "Fixture", dependencies: ["Dependency"], resources: [.copy("app.txt")])
])
''')
    write(package / "Sources/Dependency/dependency.txt", "dependency resource")
    write(package / "Sources/Dependency/Dependency.swift", '''import Foundation
public func dependencyResource() throws -> String {
    try String(contentsOf: Bundle.module.url(forResource: "dependency", withExtension: "txt")!, encoding: .utf8)
}
''')
    write(package / "Sources/Fixture/app.txt", "app resource")
    write(package / "Sources/Fixture/main.swift", '''import Foundation
import Dependency
import Darwin
for name in ["Fixture_Fixture.bundle", "Fixture_Dependency.bundle"] {
    guard let base = Bundle.main.resourceURL, Bundle(url: base.appendingPathComponent(name)) != nil else {
        print("missing-resource")
        exit(2)
    }
}
let own = try String(contentsOf: Bundle.module.url(forResource: "app", withExtension: "txt")!, encoding: .utf8)
print("\\(own)|\\(try dependencyResource())")
''')
    compiler_adapter = root / "toolchain/bin/swiftc"
    compiler_adapter.parent.mkdir(parents=True)
    shutil.copy2(tool_bin, compiler_adapter)
    env = dict(os.environ, SWIFT_EXEC=str(compiler_adapter), TALKLESS_RESOURCE_COMPILER="1",
               TALKLESS_REAL_SWIFTC=run(["xcrun", "--find", "swiftc"]).strip(),
               TALKLESS_RESOURCE_INPUTS=str(owned_inputs))
    base = ["swift", "build", "--package-path", package, "--scratch-path", build, "--build-system", "native",
            "--toolchain", str(Path(env["TALKLESS_REAL_SWIFTC"]).parent.parent)]
    for configuration in ["release", "debug"]:
        flags = ["-c", configuration, "-Xswiftc", "-file-prefix-map", "-Xswiftc", f"{root}=/source",
                 "-Xswiftc", "-debug-prefix-map", "-Xswiftc", f"{root}=/source",
                 "-Xlinker", "-oso_prefix", "-Xlinker", str(root) + "/"]
        run(base + flags, env=env)
        binary_directory = Path(run(base + ["-c", configuration, "--show-bin-path"], env=env).strip())
        binary = binary_directory / "Fixture"
        # Remove linker debug-map OSO/AST paths; keep ordinary symbols for reports.
        run(["strip", "-S", binary])
        data = binary.read_bytes()
        if str(build).encode() in data:
            matches = [part.decode(errors="replace") for part in data.split(b"\0") if str(build).encode() in part]
            raise AssertionError("absolute build fallback leaked into executable: " + repr(matches)[:6000])
        if b"/Users/" in data:
            matches = [part.decode(errors="replace") for part in data.split(b"\0") if b"/Users/" in part]
            raise AssertionError("personal path leaked into executable: " + repr(matches)[:6000])
        accessors = list(binary_directory.glob("*.build/DerivedSources/resource_bundle_accessor.swift"))
        assert len(accessors) == 2
        for accessor in accessors:
            source = accessor.read_text()
            assert "Bundle.main.bundleURL.appendingPathComponent" in source, "generated source was mutated"
            assert "let buildPath =" in source
        # Delete generated inputs and force a fresh planning pass. The adapter must
        # still apply at compilation, not only in an earlier patching/build phase.
        for accessor in accessors:
            accessor.unlink()
        run(base + flags, env=env)
        app = root / f"relocated {configuration}" / "Fixture.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        resources = app / "Contents/Resources"
        resources.mkdir()
        shutil.copy2(binary, app / "Contents/MacOS/Fixture")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.example.talkless-bundle-test",
            "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"
        }))
        for bundle in binary_directory.glob("*.bundle"):
            shutil.copytree(bundle, resources / bundle.name)
        run(["codesign", "--force", "--sign", "-", app])
        run(["codesign", "--verify", "--deep", "--strict", app])
        # No developer directory moves/deletes: deny all fixture build reads.
        profile = '(version 1)(allow default)(deny network*)(deny file-read* (subpath ' + json.dumps(str(build)) + ')(subpath ' + json.dumps(str(owned_inputs)) + '))'
        # Verify the sandbox rule itself is effective, not just syntactically valid.
        marker = build / "denied-marker.txt"
        marker.write_text("must not be readable")
        run(["/usr/bin/sandbox-exec", "-p", profile, "/bin/cat", marker], expected=1)
        output = run(["/usr/bin/sandbox-exec", "-p", profile, app / "Contents/MacOS/Fixture"])
        assert output.strip() == "app resource|dependency resource", output
        # Negative case lives in a separate unsigned copy to leave signed app intact.
        broken = root / f"missing-{configuration}.app"
        shutil.copytree(app, broken)
        shutil.rmtree(broken / "Contents/Resources/Fixture_Dependency.bundle")
        output = run(["/usr/bin/sandbox-exec", "-p", profile, broken / "Contents/MacOS/Fixture"], expected=2)
        assert output.strip() == "missing-resource"
print("Bundle tests passed (clean release/debug, regeneration, transitive resources, strict signing, sandbox relocation, negative bundle).")
