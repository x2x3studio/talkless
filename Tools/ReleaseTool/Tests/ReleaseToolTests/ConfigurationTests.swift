import XCTest
@testable import ReleaseTool

final class ConfigurationTests: XCTestCase {
    let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]
    let fixed = Date(timeIntervalSince1970: 1793363696)

    func testLocalBuildDisablesUpdates() throws {
        let result = try configuredBundle(info, environment: [:])
        XCTAssertNil(result["SUFeedURL"])
        XCTAssertNil(result["SUPublicEDKey"])
        XCTAssertEqual(result["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(result["TalklessDefaultUpdateChannel"] as? String, "beta")
    }
    func testReleaseConfiguration() throws {
        let result = try configuredBundle(info, environment: [
            "VERSION": "2026.1030.45296", "BUILD_NUMBER": "1793363696",
            "UPDATE_FEED_URL": "https://example.com/appcast.xml",
            "BETA_UPDATE_FEED_URL": "https://example.com/appcast-beta.xml",
            "SPARKLE_PUBLIC_KEY": Data(repeating: 1, count: 32).base64EncodedString(),
        ])
        XCTAssertEqual(result["CFBundleVersion"] as? String, "1793363696")
        XCTAssertEqual(result["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(result["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(result["SUAutomaticallyUpdate"] as? Bool, false)
    }
    func testInvalidConfiguration() throws {
        for environment in [["VERSION": "1.2-beta"], ["BUILD_NUMBER": "0"], ["UPDATE_FEED_URL": "https://example.com/feed"], ["RELEASE_CHANNEL": "nightly"]] {
            XCTAssertThrowsError(try configuredBundle(info, environment: environment))
        }
        var env = ["UPDATE_FEED_URL": "http://example.com/feed", "BETA_UPDATE_FEED_URL": "https://example.com/beta", "SPARKLE_PUBLIC_KEY": Data(repeating: 1, count: 32).base64EncodedString()]
        XCTAssertThrowsError(try configuredBundle(info, environment: env))
        env["UPDATE_FEED_URL"] = "https://example.com/feed?secret=value"
        XCTAssertThrowsError(try configuredBundle(info, environment: env))
        env["UPDATE_FEED_URL"] = "https://example.com/feed"
        env["SPARKLE_PUBLIC_KEY"] = Data(repeating: 1, count: 31).base64EncodedString()
        XCTAssertThrowsError(try configuredBundle(info, environment: env))
    }
    func testCalendarBeta() throws {
        let result = try calendarVersion(ref: "refs/heads/main", now: fixed)
        XCTAssertEqual(result["VERSION"], "2026.1030.45296")
        XCTAssertEqual(result["RELEASE_TAG"], "v2026.1030.45296-beta.1793363696")
    }
    func testCalendarStableAndInvalidRefs() throws {
        XCTAssertEqual(try calendarVersion(ref: "refs/tags/v2026.1030.45296", now: fixed)["RELEASE_CHANNEL"], "stable")
        for ref in ["refs/heads/feature", "refs/tags/v2026.1330.1", "refs/tags/v2026.230.1", "refs/tags/v2026.1030.86400", "refs/tags/v2026.1030.1-beta"] {
            XCTAssertThrowsError(try calendarVersion(ref: ref, now: fixed), ref)
        }
    }
    func testResourcePatchingIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Module.build/DerivedSources/resource_bundle_accessor.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Bundle.main.bundleURL.appendingPathComponent(\"test\")".write(to: file, atomically: true, encoding: .utf8)
        try patchResources(in: root)
        let once = try String(contentsOf: file, encoding: .utf8)
        try patchResources(in: root)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), once)
        XCTAssertTrue(once.contains("Bundle.main.resourceURL"))
    }
}
