import Foundation
import XCTest
@testable import ReleaseTool

final class ReleaseNotesTests: XCTestCase {
    private let chineseSource = "## Unreleased\n### \u{6539}\u{8fdb}\n- \u{66f4}\u{65b0}\u{8bf4}\u{660e}\n"
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-notes-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testRepositoryPendingNotesUseSupportedBilingualFormat() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
            throw XCTSkip("Standalone ReleaseTool checkout has no product changelogs.")
        }
        let sources = try ReleaseNotes.sourceNames.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
        let notes = try ReleaseNotes(changelog: sources[0], chineseChangelog: sources[1])
        let snapshot = notes.markdown(version: "1.0.0", build: "1", channel: "beta")
        XCTAssertEqual(try ReleaseNotes(snapshot: snapshot, version: "1.0.0", build: "1", channel: "beta"), notes)
        XCTAssertFalse(notes.english.isEmpty)
        XCTAssertFalse(notes.simplifiedChinese.isEmpty)
    }

    func testExtractsOnlyUnreleasedAndRendersDeterministically() throws {
        let source = """
        # Changelog
        Instructions outside the pending section are not published.

        ## Unreleased

        ### Improved
        - Clearer update details.
        - Faster launch.

        ## 1.0.0
        - Old notes must not appear.
        """
        let notes = try ReleaseNotes(changelog: source, chineseChangelog: chineseSource)
        XCTAssertEqual(notes.english, [.heading("Improved"), .bullet("Clearer update details."), .bullet("Faster launch.")])
        for channel in ["beta", "stable"] {
            let markdown = notes.markdown(version: "1.2.3", build: "42", channel: channel)
            XCTAssertEqual(try ReleaseNotes(snapshot: markdown, version: "1.2.3", build: "42", channel: channel), notes)
            let html = notes.html(version: "1.2.3", build: "42", channel: channel)
            XCTAssertEqual(html, notes.html(version: "1.2.3", build: "42", channel: channel))
            XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("Talkless 1.2.3 \(channel) (build 42)"))
            XCTAssertFalse(String(decoding: html, as: UTF8.self).contains("Old notes"))
            XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("<section lang=\"zh-Hans\""))
            XCTAssertTrue(String(decoding: markdown, as: UTF8.self).contains("\u{66f4}\u{65b0}\u{8bf4}\u{660e}"))
            XCTAssertTrue(notes.githubMarkdown.contains("\u{66f4}\u{65b0}\u{8bf4}\u{660e}"))
            XCTAssertThrowsError(try ReleaseNotes(snapshot: markdown, version: "1.2.4", build: "42", channel: channel))
        }
    }

    func testHTMLAndGitHubBodyEscapeUntrustedTextWithoutLoadingResources() throws {
        let notes = try ReleaseNotes(changelog: """
        ## Unreleased
        ### <img src="https://example.com/tracker" onerror='bad()'> & more
        - <script>alert('unsafe')</script> & "quoted"
        - [link](javascript:alert(1)) ![image](https://example.com/image) **literal**
        """, chineseChangelog: chineseSource)
        let html = String(decoding: notes.html(version: "1.0.0", build: "1", channel: "beta"), as: UTF8.self)
        XCTAssertTrue(html.contains("&lt;img src=&quot;https://example.com/tracker&quot; onerror=&#39;bad()&#39;&gt; &amp; more"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;unsafe&#39;)&lt;/script&gt; &amp; &quot;quoted&quot;"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertFalse(html.contains("href=\"https:"))
        XCTAssertTrue(html.contains("hreflang=\"zh-Hans\""))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("**literal**"))
        XCTAssertTrue(notes.githubMarkdown.contains("&#39;unsafe&#39;"))
        XCTAssertFalse(notes.githubMarkdown.contains("<script>"))
        XCTAssertFalse(notes.githubMarkdown.contains("[link]("))
        XCTAssertFalse(notes.githubMarkdown.contains("![image]("))
    }

    func testMissingEmptyDuplicateAndUnsupportedNotesFailClosed() throws {
        for source in ["", "# Changelog\n- Missing section", "## Unreleased\n", "## Unreleased\n### Empty",
                       "## Unreleased\n- First\n## Unreleased\n- Second", "## Unreleased\nFree-form paragraph",
                       "## Unreleased\n- ", "## Unreleased\n### \n- Something", "## Unreleased\n```html\n<script>bad</script>\n```",
                       "## Unreleased\n- One\n  continuation", "## Unreleased\n- Bad\u{0}content",
                       "## Unreleased\n### Empty\n### Also empty\n- Content"] {
            XCTAssertThrowsError(try ReleaseNotes(changelog: source, chineseChangelog: chineseSource), source)
            XCTAssertThrowsError(try ReleaseNotes(changelog: chineseSource, chineseChangelog: source), source)
        }
    }

    func testChineseSnapshotIsRequiredAndChangesArtifactBytes() throws {
        let source = "## Unreleased\n- Update details."
        let notes = try ReleaseNotes(changelog: source, chineseChangelog: chineseSource)
        let changed = try ReleaseNotes(changelog: source, chineseChangelog: chineseSource + "- \u{65b0}\u{529f}\u{80fd}\n")
        XCTAssertNotEqual(notes.markdown(version: "1.0.0", build: "1", channel: "beta"), changed.markdown(version: "1.0.0", build: "1", channel: "beta"))
        XCTAssertNotEqual(notes.html(version: "1.0.0", build: "1", channel: "beta"), changed.html(version: "1.0.0", build: "1", channel: "beta"))
        let englishOnly = Data("# Talkless 1.0.0 beta (build 1)\n\n## English\n\n- Update details.\n".utf8)
        XCTAssertThrowsError(try ReleaseNotes(snapshot: englishOnly, version: "1.0.0", build: "1", channel: "beta"))
        XCTAssertThrowsError(try notes.requireFresh(comparedWith: chineseSource, language: 1, previousTag: "v0.9.0"))
        let root = try temporaryDirectory()
        try Data(source.utf8).write(to: root.appendingPathComponent("CHANGELOG.md"))
        let runner = SigningMockRunner()
        XCTAssertThrowsError(try pendingReleaseNotes(context: ToolContext(root: root, environment: [:], runner: runner), tag: "v1.0.0"))
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testSnapshotFilesAreNeverOverwritten() throws {
        let stage = try temporaryDirectory()
        let notes = try ReleaseNotes(changelog: "## Unreleased\n- Original notes.", chineseChangelog: chineseSource)
        try notes.write(to: stage, version: "1.0.0", build: "1", channel: "beta")
        let original = try Data(contentsOf: stage.appendingPathComponent(ReleaseNotes.htmlName))
        let changed = try ReleaseNotes(changelog: "## Unreleased\n- Changed notes.", chineseChangelog: chineseSource)
        XCTAssertThrowsError(try changed.write(to: stage, version: "1.0.0", build: "2", channel: "stable"))
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent(ReleaseNotes.htmlName)), original)
    }

    func testPendingNotesRequireFreshContentWithoutNetworkOrSecrets() throws {
        let root = try temporaryDirectory()
        let source = "## Unreleased\n### Changed\n- New update details.\n"
        try Data(source.utf8).write(to: root.appendingPathComponent("CHANGELOG.md"))
        try Data(chineseSource.utf8).write(to: root.appendingPathComponent("CHANGELOG.zh-Hans.md"))
        let runner = SigningMockRunner()
        let context = ToolContext(root: root, environment: ["OP_SERVICE_ACCOUNT_TOKEN": "must-not-leak"], runner: runner)
        for oldSource in [source, "## Unreleased\n\n### Changed\n\n- New update details.\n"] {
            runner.handler = { args in
                if args.contains("for-each-ref") { return "v1.2.4-beta.43\nv1.2.3-beta.42\n" }
                if args.contains("ls-tree") { return "CHANGELOG.md\n" }
                if args.contains("show") { return oldSource }
                return ""
            }
            XCTAssertThrowsError(try pendingReleaseNotes(context: context, tag: "v1.2.4-beta.43"))
            XCTAssertTrue(runner.calls.filter { $0.arguments.contains("show") }.allSatisfy {
                $0.arguments.last == "v1.2.3-beta.42:CHANGELOG.md"
            })
        }
        runner.handler = { args in
            if args.contains("for-each-ref") { return "v1.2.3-beta.42\n" }
            if args.contains("ls-tree") { return "CHANGELOG.md\n" }
            if args.contains("show") { return "## Unreleased\n- Older notes." }
            return ""
        }
        XCTAssertEqual(try pendingReleaseNotes(context: context, tag: "v1.2.4-beta.43"), try ReleaseNotes(changelog: source, chineseChangelog: chineseSource))
        XCTAssertTrue(runner.calls.allSatisfy { $0.arguments.first == "git" && $0.environment["OP_SERVICE_ACCOUNT_TOKEN"] == nil })
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("fetch") })
    }

    func testFreshnessFindsLatestTagContainingEachLanguage() throws {
        let root = try temporaryDirectory()
        let englishSource = "## Unreleased\n- Current English notes."
        let sources = [englishSource, chineseSource]
        for (index, name) in ReleaseNotes.sourceNames.enumerated() {
            try Data(sources[index].utf8).write(to: root.appendingPathComponent(name))
        }
        for missingSource in ReleaseNotes.sourceNames {
            for stale in [true, false] {
                let runner = SigningMockRunner()
                runner.handler = { args in
                    if args.contains("for-each-ref") { return "v1.2.4-beta.43\nv1.2.3-beta.42\nv1.2.2-beta.41\n" }
                    if args.contains("ls-tree") {
                        if args.contains("v1.2.3-beta.42") && args.last == missingSource { return "" }
                        return args.last! + "\n"
                    }
                    if args.contains("show") {
                        if args.last == "v1.2.2-beta.41:" + missingSource && stale {
                            return missingSource == "CHANGELOG.md" ? englishSource : self.chineseSource
                        }
                        return "## Unreleased\n- Older notes."
                    }
                    return ""
                }
                let context = ToolContext(root: root, environment: [:], runner: runner)
                if stale {
                    XCTAssertThrowsError(try pendingReleaseNotes(context: context, tag: "v1.2.4-beta.43"), missingSource)
                } else {
                    XCTAssertNoThrow(try pendingReleaseNotes(context: context, tag: "v1.2.4-beta.43"), missingSource)
                }
                XCTAssertTrue(runner.calls.contains { $0.arguments == ["git", "show", "v1.2.2-beta.41:" + missingSource] })
                let otherSource = ReleaseNotes.sourceNames.first { $0 != missingSource }!
                XCTAssertFalse(runner.calls.contains { $0.arguments == ["git", "show", "v1.2.2-beta.41:" + otherSource] })
            }
        }
    }

    func testFirstNotesReleaseSupportsOldTagsWithoutChangelog() throws {
        let root = try temporaryDirectory()
        try Data("## Unreleased\n- First human notes.".utf8).write(to: root.appendingPathComponent("CHANGELOG.md"))
        try Data(chineseSource.utf8).write(to: root.appendingPathComponent("CHANGELOG.zh-Hans.md"))
        let runner = SigningMockRunner()
        runner.handler = { args in args.contains("for-each-ref") ? "v1.2.3-beta.42\n" : "" }
        let context = ToolContext(root: root, environment: [:], runner: runner)
        XCTAssertNoThrow(try pendingReleaseNotes(context: context, tag: "v1.2.4-beta.43"))
        XCTAssertFalse(runner.calls.contains { $0.arguments.contains("show") })
    }
}
