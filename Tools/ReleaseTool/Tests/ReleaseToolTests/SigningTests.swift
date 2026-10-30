import XCTest
@testable import ReleaseTool

final class SigningMockRunner: CommandRunning {
    struct Call {
        let arguments: [String]
        let environment: [String: String]
        let sensitive: Bool
    }
    var calls: [Call] = []
    var handler: ([String]) throws -> String = { _ in "" }

    func run(_ arguments: [String], environment: [String: String], sensitive: Bool) throws -> String {
        calls.append(Call(arguments: arguments, environment: environment, sensitive: sensitive))
        return try handler(arguments)
    }
}

final class SigningTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = try signingDirectory(parent: FileManager.default.temporaryDirectory, prefix: "talkless-signing-test-")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func context(_ directory: URL, _ runner: SigningMockRunner, environment: [String: String] = [:]) -> ToolContext {
        ToolContext(root: directory, environment: environment, runner: runner)
    }

    private var signature: String {
        "Authority=\(ToolContext.signingIdentity)\nTeamIdentifier=\(ToolContext.teamID)\nTimestamp=Oct 30, 2026\n"
    }

    private func app(_ url: URL, marker: String, identifier: String = "com.x2x3studio.talkless") throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Talkless",
                    "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
    }

    func testLocalSessionReadsOnlyCertificateAndPasswordAndIsolatesToken() throws {
        let directory = try temporaryDirectory()
        let runner = SigningMockRunner()
        let environment = ["OP_SERVICE_ACCOUNT_TOKEN": "test-token", "SIGNING_CERTIFICATE_REF": "op://test/certificate",
                           "SIGNING_PASSWORD_REF": "op://test/password"]
        runner.handler = { args in
            if args.first == "op" {
                return args.last == "op://test/certificate" ? Data("fake-p12".utf8).base64EncodedString() : "fake-password"
            }
            return ""
        }
        let session = SigningSession(context: context(directory, runner, environment: environment),
                                     directory: directory, environment: environment)
        defer { session.close() }
        try session.prepare(configuration: UpdaterConfiguration(environment: [:]), notarization: false)
        let reads = runner.calls.filter { $0.arguments.first == "op" }
        XCTAssertEqual(reads.map { $0.arguments.last! }, ["op://test/certificate", "op://test/password"])
        XCTAssertTrue(reads.allSatisfy { $0.sensitive && $0.environment["OP_SERVICE_ACCOUNT_TOKEN"] == "test-token" })
        XCTAssertTrue(runner.calls.filter { $0.arguments.first == "security" }.allSatisfy {
            $0.sensitive && $0.environment["OP_SERVICE_ACCOUNT_TOKEN"] == nil
        })
        XCTAssertNil(session.environment["OP_SERVICE_ACCOUNT_TOKEN"])
        XCTAssertEqual(session.environment["CODE_SIGN_IDENTITY"], ToolContext.signingIdentity)
        XCTAssertFalse(signingPathExists(directory.appendingPathComponent("certificate.p12")))
        XCTAssertFalse(signingPathExists(directory.appendingPathComponent("AuthKey.p8")))
        XCTAssertFalse(signingPathExists(directory.appendingPathComponent("sparkle-key")))
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("list-keychains") || $0.arguments.contains("default-keychain") })
        session.close()
        XCTAssertEqual(runner.calls.last?.arguments.prefix(2), ["security", "delete-keychain"])
    }

    func testPartiallyCreatedKeychainIsDeletedOnFailure() throws {
        let directory = try temporaryDirectory()
        let runner = SigningMockRunner()
        let environment = ["OP_SERVICE_ACCOUNT_TOKEN": "test-token", "SIGNING_CERTIFICATE_REF": "op://test/cert",
                           "SIGNING_PASSWORD_REF": "op://test/password"]
        runner.handler = { args in
            if args.contains("create-keychain") { throw ToolError("mock creation failure") }
            if args.first == "op" { return Data("fake".utf8).base64EncodedString() }
            return ""
        }
        let session = SigningSession(context: context(directory, runner, environment: environment),
                                     directory: directory, environment: environment)
        XCTAssertThrowsError(try session.prepare(configuration: UpdaterConfiguration(environment: [:]), notarization: false))
        session.close()
        XCTAssertEqual(runner.calls.last?.arguments.prefix(2), ["security", "delete-keychain"])
        XCTAssertNil(runner.calls.last?.environment["OP_SERVICE_ACCOUNT_TOKEN"])
    }

    func testNotarizationRejectsNonAcceptedStatus() throws {
        let directory = try temporaryDirectory()
        let runner = SigningMockRunner()
        runner.handler = { _ in "{\"status\":\"Invalid\"}" }
        let session = SigningSession(context: context(directory, runner), directory: directory, environment: [:])
        XCTAssertThrowsError(try session.notarize(directory.appendingPathComponent("app.zip")))
        XCTAssertTrue(runner.calls[0].sensitive)
        XCTAssertTrue(runner.calls[0].arguments.contains("--wait"))
        XCTAssertTrue(runner.calls[0].arguments.contains("30m"))
    }

    func testSignatureRequiresFixedIdentityTeamAndTimestamp() throws {
        let directory = try temporaryDirectory()
        let runner = SigningMockRunner()
        for details in ["Authority=wrong\nTeamIdentifier=\(ToolContext.teamID)\nTimestamp=now",
                        "Authority=\(ToolContext.signingIdentity)\nTeamIdentifier=wrong\nTimestamp=now",
                        "Authority=\(ToolContext.signingIdentity)\nTeamIdentifier=\(ToolContext.teamID)"] {
            runner.handler = { _ in details }
            XCTAssertThrowsError(try verifySigningSignature(directory, context: context(directory, runner), environment: [:]))
        }
        let expected = signature
        runner.handler = { _ in expected }
        XCTAssertNoThrow(try verifySigningSignature(directory, context: context(directory, runner), environment: [:]))
    }

    func testLocalAppRejectsUnrelatedBundleAndSymlink() throws {
        let directory = try temporaryDirectory()
        let unrelated = directory.appendingPathComponent("Unrelated.app")
        try app(unrelated, marker: "unrelated", identifier: "com.example.unrelated")
        XCTAssertThrowsError(try localAppInfo(unrelated))
        let valid = directory.appendingPathComponent("Valid.app")
        try app(valid, marker: "valid")
        let link = directory.appendingPathComponent("Talkless.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        XCTAssertThrowsError(try localAppInfo(link))
    }

    func testFailedInstallRestoresOriginalWithoutRetainedBackup() throws {
        let directory = try temporaryDirectory()
        let stage = try signingDirectory(parent: directory, prefix: "stage-")
        let target = directory.appendingPathComponent("Talkless.app")
        let staged = stage.appendingPathComponent("Talkless.app")
        try app(target, marker: "original")
        try app(staged, marker: "replacement")
        let original = try InstalledAppSnapshot(target)
        let runner = SigningMockRunner()
        runner.handler = { args in
            if args.first == "codesign" { throw ToolError("mock final verification failure") }
            return ""
        }
        XCTAssertThrowsError(try replaceLocalApp(stagedApp: staged, target: target, original: original,
                                                context: context(directory, runner), environment: [:]))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8), "original")
        XCTAssertEqual(try InstalledAppSnapshot(target), original)
        XCTAssertFalse(signingPathExists(stage.appendingPathComponent("Previous-Talkless.app")))
    }

    func testRunningAppStopsReplacementBeforeAnyMove() throws {
        let directory = try temporaryDirectory()
        let stage = try signingDirectory(parent: directory, prefix: "stage-")
        let target = directory.appendingPathComponent("Talkless.app")
        let staged = stage.appendingPathComponent("Talkless.app")
        try app(target, marker: "original")
        try app(staged, marker: "replacement")
        let runner = SigningMockRunner()
        runner.handler = { _ in throw ToolError("mock pgrep found a process") }
        XCTAssertThrowsError(try replaceLocalApp(stagedApp: staged, target: target, original: InstalledAppSnapshot(target),
                                                context: context(directory, runner), environment: [:]))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8), "original")
        XCTAssertTrue(signingPathExists(staged))
    }

    func testTemporarySecretsMustBeOutsideRepository() throws {
        let directory = try temporaryDirectory()
        let runner = SigningMockRunner()
        XCTAssertThrowsError(try signingTemporaryRoot(context: context(directory, runner, environment: ["TMPDIR": directory.path])))
        XCTAssertThrowsError(try signingTemporaryRoot(context: context(directory, runner, environment: ["TMPDIR": directory.appendingPathComponent("tmp").path])))
    }
}
