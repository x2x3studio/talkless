import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import ReleaseTool

private final class PublicationMockRunner: CommandRunning {
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

final class PublicationTests: XCTestCase {
    private let version = "2026.1030.42"
    private let build = "1793318400"
    private let fixtureSignature = Data(repeating: 0, count: 64).base64EncodedString()

    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-publication-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    private func configurationEnvironment(channel: String = "beta") throws -> [String: String] {
        let base = "https://github.com/\(ToolContext.repository)/releases/download/"
        return [
            "UPDATE_FEED_URL": base + "updates/appcast.xml",
            "BETA_UPDATE_FEED_URL": base + "updates/appcast-beta.xml",
            "SPARKLE_PUBLIC_KEY": Data(repeating: 0, count: 32).base64EncodedString(),
            "TALKLESS_SPARKLE_KEY_REF": "op://fixture-only/item/key",
            "DOWNLOAD_BASE_URL": base + (try releaseTag(version: version, build: build, channel: channel)),
        ]
    }

    @discardableResult
    private func fixture(_ directory: URL, channel: String = "beta", updater: Bool = false) throws -> ReleaseMetadata {
        let config = try UpdaterConfiguration(environment: updater ? configurationEnvironment(channel: channel) : [:])
        let stem = "Talkless-\(version)-\(build)-arm64"
        let archive = Data("Mock archive; not signed release material".utf8)
        for ext in ["zip", "dmg"] {
            try archive.write(to: directory.appendingPathComponent(stem + "." + ext))
        }
        if updater {
            let appcast = try makeAppcast(version: version, build: build, minimumOS: "15.0",
                                         downloadURL: config.downloadBaseURL! + "/" + stem + ".zip",
                                         signature: fixtureSignature, length: UInt64(archive.count))
            for name in try feedNames(channel: channel) { try appcast.write(to: directory.appendingPathComponent(name)) }
        }
        return try writeMetadata(stage: directory, version: version, build: build, channel: channel,
                                 sourceCommit: String(repeating: "a", count: 40), configuration: config)
    }

    private func context(_ root: URL, runner: PublicationMockRunner, acknowledged: Bool = true,
                         extraEnvironment: [String: String] = [:]) -> ToolContext {
        var env = extraEnvironment
        if acknowledged { env["PUBLIC_RELEASE_ACK"] = ToolContext.repository }
        return ToolContext(root: root, environment: env, runner: runner)
    }

    private func configureGitHub(_ runner: PublicationMockRunner, privateRepository: Bool = false,
                                 feeds: [String: Data] = [:], draftFeed: Bool = false,
                                 failCreate: Bool = false, failEdit: Bool = false) {
        runner.handler = { arguments in
            if arguments.prefix(2) == ["gh", "api"] { return "{\"private\":\(privateRepository)}" }
            if arguments.prefix(3) == ["gh", "release", "view"] {
                let assets = feeds.keys.sorted().map { ["name": $0] }
                let data = try JSONSerialization.data(withJSONObject: ["isDraft": draftFeed, "assets": assets])
                return String(decoding: data, as: UTF8.self)
            }
            if arguments.prefix(3) == ["gh", "release", "download"] {
                let name = arguments[arguments.firstIndex(of: "--pattern")! + 1]
                let directory = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "--dir")! + 1])
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
                try XCTUnwrap(feeds[name]).write(to: directory.appendingPathComponent(name))
            }
            if failCreate && arguments.prefix(3) == ["gh", "release", "create"] { throw ToolError("Release already exists") }
            if failEdit && arguments.prefix(3) == ["gh", "release", "edit"] { throw ToolError("Publication failed") }
            return ""
        }
    }

    func testVersionAndChannelValidation() throws {
        for pair in [("0.1.0", "1"), (version, build), ("1.2.3", String(repeating: "9", count: 18))] {
            XCTAssertNoThrow(try validateVersion(pair.0, build: pair.1))
        }
        for pair in [("../1.0.0", "1"), ("1.0.0-beta", "1"), ("01.2.3", "1"), ("1.2.3\n", "1"),
                     ("1.2.3", "0"), ("1.2.3", "1;id"), ("1.2.3", "01"), ("1.2.3", "1\n"),
                     ("1.2.3", String(repeating: "9", count: 19))] {
            XCTAssertThrowsError(try validateVersion(pair.0, build: pair.1))
        }
        XCTAssertEqual(try releaseTag(version: "1.2.3", build: "4", channel: "beta"), "v1.2.3-beta.4")
        XCTAssertEqual(try releaseTag(version: "1.2.3", build: "5", channel: "stable"), "v1.2.3")
        XCTAssertThrowsError(try releaseTag(version: "1.2.3", build: "4", channel: "preview"))
        XCTAssertEqual(try feedNames(channel: "beta"), ["appcast-beta.xml"])
        XCTAssertEqual(try feedNames(channel: "stable"), ["appcast.xml", "appcast-beta.xml"])
        XCTAssertThrowsError(try feedNames(channel: "preview"))
    }

    func testUpdaterConfigurationAllFiveFieldsAndSafeURLs() throws {
        XCTAssertFalse(try UpdaterConfiguration(environment: [:]).isEnabled)
        let valid = try configurationEnvironment()
        XCTAssertTrue(try UpdaterConfiguration(environment: valid).isEnabled)
        for name in valid.keys {
            var bad = valid
            bad.removeValue(forKey: name)
            XCTAssertThrowsError(try UpdaterConfiguration(environment: bad))
        }
        for url in ["http://example.com", "https://user:password@example.com/a", "https://@example.com/a",
                    "https://example.com/a?q=1", "https://example.com/a#fragment", "https://example.com/?",
                    "https://example.com/#", "https://example.com/a b", "https://example.com/a\nb", "https:///a",
                    "https://example.com\\@evil.example/a"] {
            var bad = valid
            bad["UPDATE_FEED_URL"] = url
            XCTAssertThrowsError(try UpdaterConfiguration(environment: bad), url)
        }
        for (name, value) in [("SPARKLE_PUBLIC_KEY", "not-base64"), ("SPARKLE_PUBLIC_KEY", Data(repeating: 0, count: 31).base64EncodedString()),
                              ("TALKLESS_SPARKLE_KEY_REF", "raw-private-value"), ("UPDATE_FEED_URL", valid["BETA_UPDATE_FEED_URL"]!)] {
            var bad = valid
            bad[name] = value
            XCTAssertThrowsError(try UpdaterConfiguration(environment: bad))
        }
        var whitespace = valid.mapValues { "  \($0)\n" }
        whitespace["DOWNLOAD_BASE_URL"] = valid["DOWNLOAD_BASE_URL"]! + "///"
        XCTAssertEqual(try UpdaterConfiguration(environment: whitespace).downloadBaseURL, valid["DOWNLOAD_BASE_URL"])
    }

    func testAppcastEscapingAndDeterminism() throws {
        let url = "https://example.com/a&b.zip"
        func make() throws -> Data {
            try makeAppcast(version: version, build: build, minimumOS: "15.0", downloadURL: url,
                            signature: fixtureSignature, length: 1234)
        }
        let data = try make()
        XCTAssertEqual(data, try make())
        let document = try XMLDocument(data: data)
        let enclosure = try XCTUnwrap(document.nodes(forXPath: "/rss/channel/item/enclosure").first as? XMLElement)
        XCTAssertEqual(enclosure.attribute(forName: "url")?.stringValue, url)
        XCTAssertEqual(enclosure.attribute(forName: "length")?.stringValue, "1234")
        XCTAssertThrowsError(try makeAppcast(version: version, build: build, minimumOS: "15.0", downloadURL: url,
                                             signature: "bad", length: 1))
    }

    func testNativeSignatureVerificationAndCompiledToolDiscovery() throws {
        // Deterministic, test-only Ed25519 fixture; no credential manager or network access.
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let root = try temporaryDirectory()
        let archive = root.appendingPathComponent("fixture.zip")
        let archiveData = Data("Test archive bytes".utf8)
        try archiveData.write(to: archive)
        let signature = try key.signature(for: archiveData).base64EncodedString()
        let tools = root.appendingPathComponent(".build/artifacts/sparkle/Sparkle/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let tool = tools.appendingPathComponent("sign_update")
        try Data().write(to: tool)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var env = try configurationEnvironment(channel: "stable")
        env["SPARKLE_PUBLIC_KEY"] = key.publicKey.rawRepresentation.base64EncodedString()
        env["OP_SERVICE_ACCOUNT_TOKEN"] = "fixture-token-must-not-reach-sign-update"
        let config = try UpdaterConfiguration(environment: env)
        let runner = PublicationMockRunner()
        runner.handler = { _ in signature + "\n" }
        try generateSignedAppcasts(context: context(root, runner: runner), stage: stage, archive: archive,
                                   configuration: config, version: version, build: build, minimumOS: "15.0",
                                   channel: "stable", secretDirectory: root, environment: env)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(Array(runner.calls[0].arguments.dropFirst()), ["--ed-key-file", root.appendingPathComponent("sparkle-key").path, "-p", archive.path])
        let discoveredTool = URL(fileURLWithPath: runner.calls[0].arguments[0])
        let discoveredID = try FileManager.default.attributesOfItem(atPath: discoveredTool.path)[.systemFileNumber] as? NSNumber
        let expectedID = try FileManager.default.attributesOfItem(atPath: tool.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(discoveredID, expectedID)
        XCTAssertTrue(runner.calls[0].sensitive)
        XCTAssertNil(runner.calls[0].environment["OP_SERVICE_ACCOUNT_TOKEN"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path).sorted(), ["appcast-beta.xml", "appcast.xml"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("verify-sparkle.swift").path))
        XCTAssertNoThrow(try verifySparkleSignature(archive: archive, signature: signature, publicKey: env["SPARKLE_PUBLIC_KEY"]!))
        try Data("Modified archive".utf8).write(to: archive)
        XCTAssertThrowsError(try verifySparkleSignature(archive: archive, signature: signature, publicKey: env["SPARKLE_PUBLIC_KEY"]!))
    }

    func testMetadataExactSnakeCaseKeysNullsAndChecksums() throws {
        let directory = try temporaryDirectory()
        let metadata = try fixture(directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("release-metadata.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema_version", "product", "version", "build_number", "tag", "release_channel", "architecture",
                                          "source_commit", "signing_identity", "team_id", "notarized", "stapled", "updater_enabled",
                                          "update_feed_url", "beta_update_feed_url", "download_base_url", "files"])
        XCTAssertTrue(object["update_feed_url"] is NSNull)
        XCTAssertTrue(object["beta_update_feed_url"] is NSNull)
        XCTAssertTrue(object["download_base_url"] is NSNull)
        XCTAssertEqual(try JSONDecoder().decode(ReleaseMetadata.self, from: data), metadata)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("SHA256SUMS"), encoding: .utf8), metadata.checksumText)
        let known = directory.appendingPathComponent("known-hash")
        try Data("abc".utf8).write(to: known)
        XCTAssertEqual(try sha256(known), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for (key, value) in [("architecture", "x86_64" as Any), ("tag", "vwrong" as Any), ("notarized", 1 as Any),
                             ("extra", true as Any), ("source_commit", "not-a-commit" as Any)] {
            var bad = object
            bad[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(ReleaseMetadata.self, from: JSONSerialization.data(withJSONObject: bad)), key)
        }
        var missing = object
        missing.removeValue(forKey: "beta_update_feed_url")
        XCTAssertThrowsError(try JSONDecoder().decode(ReleaseMetadata.self, from: JSONSerialization.data(withJSONObject: missing)))
        var traversal = object
        traversal["files"] = ["../injected.zip": ["sha256": String(repeating: "a", count: 64), "size": 1]]
        XCTAssertThrowsError(try JSONDecoder().decode(ReleaseMetadata.self, from: JSONSerialization.data(withJSONObject: traversal)))
        var badFiles = object
        badFiles["files"] = metadata.files.mapValues { ["sha256": $0.sha256, "size": $0.size, "extra": 1] as [String: Any] }
        XCTAssertThrowsError(try JSONDecoder().decode(ReleaseMetadata.self, from: JSONSerialization.data(withJSONObject: badFiles)))
    }

    func testPublicationAcknowledgementRejectedBeforeIO() throws {
        for (environment, shouldPublish) in [([String: String](), true), (["RELEASE_REPOSITORY": "x2x3studio/other"], false),
                                              (["PUBLIC_RELEASE_ACK": "wrong"], true)] {
            let runner = PublicationMockRunner()
            let ctx = ToolContext(root: URL(fileURLWithPath: "/nonexistent"), environment: environment, runner: runner)
            XCTAssertThrowsError(try publish(context: ctx, directory: ctx.root, publishPublic: shouldPublish))
            XCTAssertTrue(runner.calls.isEmpty)
        }
    }

    func testDraftAndPublicPublicationChannelSemantics() throws {
        for channel in ["beta", "stable"] {
            let directory = try temporaryDirectory()
            let metadata = try fixture(directory, channel: channel)
            for publicPublish in [false, true] {
                let runner = PublicationMockRunner()
                configureGitHub(runner)
                try publish(context: context(directory, runner: runner), directory: directory, publishPublic: publicPublish)
                XCTAssertEqual(runner.calls.count, publicPublish ? 3 : 2)
                let create = runner.calls[1].arguments
                XCTAssertEqual(Array(create.prefix(4)), ["gh", "release", "create", metadata.tag])
                XCTAssertTrue(create.contains("--draft"))
                XCTAssertEqual(create.contains("--prerelease"), channel == "beta")
                XCTAssertFalse(create.contains("--clobber"))
                if publicPublish {
                    XCTAssertTrue(runner.calls[2].arguments.contains("--draft=false"))
                    XCTAssertTrue(runner.calls[2].arguments.contains(channel == "stable" ? "--latest" : "--latest=false"))
                }
            }
        }
    }

    func testPublicDraftNeedsACKAndPrivatePublicationFails() throws {
        let directory = try temporaryDirectory()
        try fixture(directory)
        let runner = PublicationMockRunner()
        configureGitHub(runner)
        XCTAssertThrowsError(try publish(context: context(directory, runner: runner, acknowledged: false), directory: directory, publishPublic: false))
        XCTAssertEqual(runner.calls.count, 1)
        runner.calls = []
        configureGitHub(runner, privateRepository: true)
        XCTAssertThrowsError(try publish(context: context(directory, runner: runner), directory: directory, publishPublic: true))
        XCTAssertEqual(runner.calls.count, 1)
        runner.calls = []
        try publish(context: context(directory, runner: runner, acknowledged: false), directory: directory, publishPublic: false)
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testChangedAssetsAndAllowlistRejectBeforeNetwork() throws {
        for mutation in ["archive", "checksum", "symlink", "extra", "metadata-symlink"] {
            let directory = try temporaryDirectory()
            let metadata = try fixture(directory)
            let archive = directory.appendingPathComponent(metadata.assetStem + ".zip")
            switch mutation {
            case "archive": try Data("tampered".utf8).write(to: archive)
            case "checksum": try Data("wrong".utf8).write(to: directory.appendingPathComponent("SHA256SUMS"))
            case "symlink":
                let original = try temporaryDirectory().appendingPathComponent("archive")
                try FileManager.default.moveItem(at: archive, to: original)
                try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: original)
            case "metadata-symlink":
                let path = directory.appendingPathComponent("release-metadata.json")
                let original = try temporaryDirectory().appendingPathComponent("metadata")
                try FileManager.default.moveItem(at: path, to: original)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: original)
            default: try Data("private data".utf8).write(to: directory.appendingPathComponent("private-key"))
            }
            let runner = PublicationMockRunner()
            XCTAssertThrowsError(try publish(context: context(directory, runner: runner), directory: directory, publishPublic: true))
            XCTAssertTrue(runner.calls.isEmpty, mutation)
        }
    }

    func testEmptyBootstrapAndManifestUploadLast() throws {
        let empty = Data("<rss version=\"2.0\"><channel><title>Talkless</title></channel></rss>".utf8)
        for channel in ["beta", "stable"] {
            let directory = try temporaryDirectory()
            try fixture(directory, channel: channel, updater: true)
            let runner = PublicationMockRunner()
            configureGitHub(runner, feeds: ["appcast.xml": empty, "appcast-beta.xml": empty])
            try publish(context: context(directory, runner: runner), directory: directory, publishPublic: true)
            let calls = runner.calls.map(\.arguments)
            XCTAssertEqual(Array(calls[calls.count - 2].prefix(3)), ["gh", "release", "edit"])
            XCTAssertEqual(Array(calls.last!.prefix(4)), ["gh", "release", "upload", "updates"])
            XCTAssertTrue(calls.last!.contains("--clobber"))
            let uploaded = Set(calls.last!.filter { $0.hasSuffix(".xml") }.map { URL(fileURLWithPath: $0).lastPathComponent })
            XCTAssertEqual(uploaded, try feedNames(channel: channel))
            XCTAssertEqual(calls.filter { $0.prefix(3) == ["gh", "release", "download"] }.count, 2)
        }
    }

    func testMonotonicBothFeedsAndMalformedRSS() throws {
        let valid = try makeAppcast(version: version, build: build, minimumOS: "15.0", downloadURL: "https://example.com/a.zip",
                                    signature: fixtureSignature, length: 1)
        XCTAssertNoThrow(try validateFeedMonotonicity(valid, build: "1793318401"))
        XCTAssertThrowsError(try validateFeedMonotonicity(valid, build: build))
        for invalid in ["<not-rss><channel/></not-rss>", "<rss/>", "<rss><channel><item/></channel></rss>",
                        "<rss><channel/></rss><rss/>", "<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss><channel/></rss>",
                        "<rss xmlns:s='\(sparkleNamespace)'><channel><item><s:version>bad</s:version></item></channel></rss>",
                        "<rss xmlns:s='\(sparkleNamespace)'><channel><item><s:version>1</s:version></item><item/></channel></rss>"] {
            XCTAssertThrowsError(try validateFeedMonotonicity(Data(invalid.utf8), build: build), invalid)
        }
        for feed in ["appcast.xml", "appcast-beta.xml"] {
            let directory = try temporaryDirectory()
            try fixture(directory, updater: true)
            let runner = PublicationMockRunner()
            configureGitHub(runner, feeds: [feed: valid])
            XCTAssertThrowsError(try publish(context: context(directory, runner: runner), directory: directory, publishPublic: true))
            XCTAssertFalse(runner.calls.contains { $0.arguments.prefix(3) == ["gh", "release", "create"] })
        }
    }

    func testExistingReleaseAndPublishFailureNeverOverwriteAssetsOrFeeds() throws {
        for failCreate in [true, false] {
            let directory = try temporaryDirectory()
            try fixture(directory, updater: true)
            let runner = PublicationMockRunner()
            configureGitHub(runner, failCreate: failCreate, failEdit: !failCreate)
            XCTAssertThrowsError(try publish(context: context(directory, runner: runner), directory: directory, publishPublic: true))
            XCTAssertFalse(runner.calls.contains { $0.arguments.prefix(3) == ["gh", "release", "upload"] })
            XCTAssertFalse(runner.calls.contains { $0.arguments.contains("--clobber") })
        }
    }
}
