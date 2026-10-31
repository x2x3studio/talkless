import XCTest
@testable import ReleaseTool

final class ResourcePackagingTests: XCTestCase {
    private let generated = """
    import Foundation
    extension Foundation.Bundle {
        static nonisolated let module: Bundle = {
            let mainPath = Bundle.main.bundleURL.appendingPathComponent("Example_Module.bundle").path
            let buildPath = "/private/build/Example_Module.bundle"
            let preferredBundle = Bundle(path: mainPath)
            guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
                Swift.fatalError("could not load resource bundle")
            }
            return bundle
        }()
    }
    """

    private func temporary(_ action: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }

    func testAccessorUsesOnlyRunningBundleAndRejectsUnknownToolchain() throws {
        let result = try appResourceAccessor(generated)
        XCTAssertTrue(result.contains("Bundle.main.resourceURL"))
        XCTAssertTrue(result.contains("Example_Module.bundle"))
        XCTAssertFalse(result.contains("/private/build"))
        XCTAssertFalse(result.contains("buildPath"))
        XCTAssertThrowsError(try appResourceAccessor("import Foundation"))
        XCTAssertThrowsError(try appResourceAccessor(generated.replacingOccurrences(of: "Example_Module.bundle", with: "../External.bundle")))
        let patched = generated.replacingOccurrences(of: "Bundle.main.bundleURL.appendingPathComponent", with: "(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent")
        XCTAssertEqual(try appResourceAccessor(patched), result)
    }

    func testResponseFilesQuotesEscapesAndMalformedInput() throws {
        XCTAssertEqual(try compilerResponseArguments(#"-c "/path with spaces/a.swift" '/another path/b.swift' escaped\ path.swift"#),
                       ["-c", "/path with spaces/a.swift", "/another path/b.swift", "escaped path.swift"])
        XCTAssertThrowsError(try compilerResponseArguments("\"unfinished"))
        XCTAssertThrowsError(try compilerResponseArguments("trailing\\"))
    }

    func testCompilerSubstitutesOwnedInputsAndOutputKeysWithoutChangingGeneratedFiles() throws {
        try temporary { root in
            let input = root.appendingPathComponent("resource_bundle_accessor.swift")
            try generated.write(to: input, atomically: true, encoding: .utf8)
            let response = root.appendingPathComponent("sources")
            try "\"\(input.path)\"".write(to: response, atomically: true, encoding: .utf8)
            let map = root.appendingPathComponent("outputs.json")
            let outputs = [input.path: ["object": "/expected/accessor.swift.o"], "": ["swift-dependencies": "/expected/master.swiftdeps"]]
            try JSONEncoder().encode(outputs).write(to: map)
            let args = try resourceCompilerArguments(["-c", "@" + response.path, "-output-file-map", map.path], directory: root, inputDirectory: root.appendingPathComponent("owned"))
            XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), generated)
            XCTAssertFalse(args.contains("@" + response.path))
            let replacement = args[1]
            XCTAssertNotEqual(replacement, input.path)
            XCTAssertTrue(try String(contentsOfFile: replacement, encoding: .utf8).contains("Bundle.main.resourceURL"))
            let updated = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
            XCTAssertNil(updated[input.path])
            XCTAssertEqual(updated[replacement]?["object"], "/expected/accessor.swift.o")
            XCTAssertEqual(updated[""]?["swift-dependencies"], "/expected/master.swiftdeps")
            XCTAssertEqual(try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: map)), outputs)
        }
    }

    func testCompilerProbesLinkerTokensFileListsAndRecursiveResponses() throws {
        try temporary { root in
            let probe = ["-print-target-info"]
            XCTAssertEqual(try resourceCompilerArguments(probe, directory: root, inputDirectory: root), probe)
            XCTAssertEqual(try compilerInputArguments(["-Xlinker", "@loader_path", "@rpath/Sparkle"], directory: root), ["-Xlinker", "@loader_path", "@rpath/Sparkle"])
            let list = root.appendingPathComponent("filelist")
            try "/path with spaces/a.swift\nb.swift\n".write(to: list, atomically: true, encoding: .utf8)
            XCTAssertEqual(try compilerInputArguments(["-filelist", list.path], directory: root), ["/path with spaces/a.swift", "b.swift"])
            let cycle = root.appendingPathComponent("recursive")
            try "@recursive".write(to: cycle, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try compilerInputArguments(["@recursive"], directory: root))
        }
    }

    func testPackagesEveryTransitiveBundleAndRejectsMissingOrExternalResources() throws {
        try temporary { root in
            let build = root.appendingPathComponent("build"), app = root.appendingPathComponent("App.app")
            for name in requiredResourceBundleNames + ["Another_Dependency.bundle"] {
                let bundle = build.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try Data("resource".utf8).write(to: bundle.appendingPathComponent("payload"))
            }
            try packageResources(from: build, app: app)
            try verifyResourcePackaging(app: app)
            let resources = app.appendingPathComponent("Contents/Resources")
            let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: resources.appendingPathComponent(resourceBundleManifestName)))
            XCTAssertEqual(names, (requiredResourceBundleNames + ["Another_Dependency.bundle"]).sorted())
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent(requiredResourceBundleNames[0]).path))
            let link = resources.appendingPathComponent("external-link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.path)
            XCTAssertThrowsError(try verifyResourcePackaging(app: app))
            try FileManager.default.removeItem(at: link)
            try FileManager.default.removeItem(at: resources.appendingPathComponent(requiredResourceBundleNames[0]))
            XCTAssertThrowsError(try verifyResourcePackaging(app: app))
            try FileManager.default.removeItem(at: build.appendingPathComponent(requiredResourceBundleNames[0]))
            XCTAssertThrowsError(try packageResources(from: build, app: app))
        }
    }

    func testExecutablePreparationRemovesBuildRpathsButKeepsSystemAndRelativePaths() throws {
        try temporary { root in
            let executable = root.appendingPathComponent("binary")
            try Data("clean binary".utf8).write(to: executable)
            let runner = SigningMockRunner()
            runner.handler = { arguments in
                if arguments.first == "otool" {
                    return ["/private/tmp/compiler/lib/swift", "/usr/lib/swift", "@executable_path/../Frameworks"].map {
                        "cmd LC_RPATH\ncmdsize 64\npath \($0) (offset 12)"
                    }.joined(separator: "\n")
                }
                return ""
            }
            let context = ToolContext(root: root, environment: [:], runner: runner)
            try prepareAppExecutable(executable, context: context)
            XCTAssertEqual(runner.calls.map(\.arguments), [
                ["otool", "-l", executable.path],
                ["install_name_tool", "-delete_rpath", "/private/tmp/compiler/lib/swift", executable.path],
                ["strip", "-S", executable.path]
            ])
        }
    }

    func testRelocatedGateRequiresActualDependencySuccessAndContainedReportedPaths() throws {
        try temporary { root in
            let build = root.appendingPathComponent("build"), app = root.appendingPathComponent("App.app")
            for name in requiredResourceBundleNames {
                let directory = build.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("resource".utf8).write(to: directory.appendingPathComponent("payload"))
            }
            try packageResources(from: build, app: app)
            for scenario in ["success", "dependency-failed", "external-path"] {
                let runner = SigningMockRunner()
                var staged: URL?
                runner.handler = { arguments in
                    if arguments.first == "ditto" { staged = URL(fileURLWithPath: arguments[2]); return "" }
                    guard arguments.first == "/usr/bin/sandbox-exec" else { return "" }
                    XCTAssertTrue(arguments[2].contains("(deny network*)"))
                    XCTAssertTrue(arguments[2].contains("(deny file-read*"))
                    let encodedBuild = String(decoding: try JSONEncoder().encode(build.path), as: UTF8.self)
                    XCTAssertTrue(arguments[2].contains(encodedBuild))
                    let resources = staged!.appendingPathComponent("Contents/Resources")
                    let paths = Dictionary(uniqueKeysWithValues: requiredResourceBundleNames.map { ($0, resources.appendingPathComponent($0).path) })
                    let payload: [String: Any] = [
                        "status": "ok", "dependencyProbe": scenario == "dependency-failed" ? "failed" : "ok",
                        "localizationBundlePath": scenario == "external-path" ? build.path : resources.appendingPathComponent(requiredResourceBundleNames[0]).path,
                        "resourceBundlePaths": paths
                    ]
                    return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                }
                let context = ToolContext(root: root, environment: [
                    "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "PRIVATE_TOKEN": "private",
                    "OP_SERVICE_ACCOUNT_TOKEN": "private", "GH_TOKEN": "private", "GITHUB_TOKEN": "private"
                ], runner: runner)
                if scenario == "success" {
                    XCTAssertNoThrow(try verifyRelocatedBundle(app: app, deniedPaths: [build.path], context: context))
                } else {
                    XCTAssertThrowsError(try verifyRelocatedBundle(app: app, deniedPaths: [build.path], context: context))
                }
                for call in runner.calls {
                    XCTAssertEqual(call.environment, ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"])
                }
                XCTAssertEqual(runner.calls[1].arguments.prefix(5), ["codesign", "--verify", "--deep", "--strict", staged!.path])
                XCTAssertFalse(FileManager.default.fileExists(atPath: staged!.deletingLastPathComponent().path))
            }
        }
    }

    func testDiagnosticProcessDeadlineStopsHungChildAndAllowsFastChild() throws {
        try temporary { root in
            let runner = ProcessRunner(directory: root, cancellation: CancellationState())
            let start = Date()
            XCTAssertThrowsError(try runner.run(["/bin/sleep", "10"], environment: [:], sensitive: false, timeout: 0.1)) { error in
                XCTAssertTrue(error.localizedDescription.contains("timed out"))
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
            XCTAssertEqual(try runner.run(["/usr/bin/true"], environment: [:], sensitive: false, timeout: 1), "")
        }
    }

    func testPrivacyGateDoesNotEchoPrivatePaths() throws {
        try temporary { root in
            let file = root.appendingPathComponent("binary")
            let homeMarkers = ["Users", "home"].map { "/" + $0 + "/" + "private-person/source.swift" }
            for marker in homeMarkers + ["/custom/private/workspace"] {
                try Data(("prefix\0" + marker + "\0suffix").utf8).write(to: file)
                XCTAssertThrowsError(try verifyExecutablePrivacy(file, forbiddenPaths: ["/custom/private"])) { error in
                    XCTAssertFalse(error.localizedDescription.contains(marker))
                }
            }
            try Data("/usr/lib/swift\0@executable_path/../Frameworks".utf8).write(to: file)
            XCTAssertNoThrow(try verifyExecutablePrivacy(file, forbiddenPaths: []))
        }
    }
}
