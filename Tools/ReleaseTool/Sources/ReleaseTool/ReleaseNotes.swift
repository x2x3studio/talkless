import Foundation

/// Deliberately not a general Markdown renderer: only headings and plain-text bullets.
/// Source text is never interpreted as HTML, links, images, or executable content.
struct ReleaseNotes: Equatable {
    enum Block: Equatable {
        case heading(String)
        case bullet(String)
    }

    static let markdownName = "release-notes.md"
    static let htmlName = "release-notes.html"
    static let assetNames: Set<String> = [markdownName, htmlName]
    static let sourceNames = ["CHANGELOG.md", "CHANGELOG.zh-Hans.md"]
    // Keep source code English-only; the human translation lives in CHANGELOG.zh-Hans.md.
    static let chineseTitle = "\u{7b80}\u{4f53}\u{4e2d}\u{6587}"
    let english: [Block]
    let simplifiedChinese: [Block]

    init(changelog: String, chineseChangelog: String) throws {
        english = try Self.pendingSection(changelog, name: Self.sourceNames[0])
        simplifiedChinese = try Self.pendingSection(chineseChangelog, name: Self.sourceNames[1])
    }

    private static func pendingSection(_ source: String, name: String) throws -> [Block] {
        let lines = source.components(separatedBy: .newlines)
        let starts = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == "## Unreleased" }
        guard starts.count == 1, let start = starts.first else {
            throw ToolError("\(name) must contain exactly one ## Unreleased section.")
        }
        let end = lines.indices.dropFirst(start + 1).first { lines[$0].hasPrefix("## ") } ?? lines.endIndex
        return try parseBody(lines[(start + 1)..<end].joined(separator: "\n"))
    }

    private static func parseBody(_ body: String) throws -> [Block] {
        var result: [Block] = []
        var headingNeedsBullet = false
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ToolError("Release notes must not contain control characters.")
            }
            if line.hasPrefix("### "), !headingNeedsBullet {
                let text = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { throw ToolError("Release note headings must not be empty.") }
                result.append(.heading(text))
                headingNeedsBullet = true
            } else if line.hasPrefix("- ") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { throw ToolError("Release note bullets must not be empty.") }
                result.append(.bullet(text))
                headingNeedsBullet = false
            } else {
                throw ToolError("Release notes support only ### headings and single-line - plain-text bullets.")
            }
        }
        guard !headingNeedsBullet, result.contains(where: { if case .bullet = $0 { return true }; return false }) else {
            throw ToolError("Add human-written notes to both changelogs' Unreleased sections before releasing.")
        }
        return result
    }

    private var languages: [(code: String, title: String, blocks: [Block])] {
        [("en", "English", english), ("zh-Hans", Self.chineseTitle, simplifiedChinese)]
    }

    private func title(version: String, build: String, channel: String) -> String {
        "Talkless \(version) \(channel) (build \(build))"
    }

    private func body(_ blocks: [Block], escape: (String) -> String = { $0 }) -> String {
        blocks.map { block in
            switch block {
            case .heading(let text): return "\n### \(escape(text))\n"
            case .bullet(let text): return "- \(escape(text))\n"
            }
        }.joined().trimmingCharacters(in: .newlines) + "\n"
    }

    func markdown(version: String, build: String, channel: String) -> Data {
        let sections = languages.map { "## \($0.title)\n\n" + body($0.blocks) }.joined(separator: "\n")
        return Data(("# " + title(version: version, build: build, channel: channel) + "\n\n" + sections).utf8)
    }

    init(snapshot: Data, version: String, build: String, channel: String) throws {
        let prefix = "# Talkless \(version) \(channel) (build \(build))\n\n## English\n\n"
        guard let text = String(data: snapshot, encoding: .utf8), text.hasPrefix(prefix) else {
            throw ToolError("Release note snapshot does not match the release.")
        }
        let sections = String(text.dropFirst(prefix.count)).components(separatedBy: "\n## \(Self.chineseTitle)\n\n")
        guard sections.count == 2 else { throw ToolError("Release note snapshot must contain English and Simplified Chinese sections.") }
        english = try Self.parseBody(sections[0])
        simplifiedChinese = try Self.parseBody(sections[1])
        guard markdown(version: version, build: build, channel: channel) == snapshot else {
            throw ToolError("Release note snapshot is not in canonical form.")
        }
    }

    func html(version: String, build: String, channel: String) -> Data {
        let title = htmlEscaped(title(version: version, build: build, channel: channel))
        var content = ""
        for language in languages {
            content += "<section lang=\"\(language.code)\" id=\"\(language.code)\">\n<h2>\(language.title)</h2>\n"
            var inList = false
            for block in language.blocks {
                switch block {
                case .heading(let text):
                    if inList { content += "</ul>\n"; inList = false }
                    content += "<h3>\(htmlEscaped(text))</h3>\n"
                case .bullet(let text):
                    if !inList { content += "<ul>\n"; inList = true }
                    content += "<li>\(htmlEscaped(text))</li>\n"
                }
            }
            if inList { content += "</ul>\n" }
            content += "</section>\n"
        }
        return Data("""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(title)</title>
        <style>:root { color-scheme: light dark; } body { font: 14px -apple-system, sans-serif; line-height: 1.5; margin: 24px; } h1 { font-size: 20px; } h2 { font-size: 18px; } h3 { font-size: 16px; } li { margin: 6px 0; }</style>
        </head>
        <body>
        <h1>\(title)</h1>
        <nav><a href="#en" hreflang="en">English</a> | <a href="#zh-Hans" hreflang="zh-Hans">\(Self.chineseTitle)</a></nav>
        \(content)</body>
        </html>

        """.utf8)
    }

    var githubMarkdown: String {
        languages.map { "\n## \($0.title)\n\n" + body($0.blocks, escape: markdownEscaped) }.joined()
    }

    func write(to stage: URL, version: String, build: String, channel: String) throws {
        try validateVersion(version, build: build)
        _ = try releaseTag(version: version, build: build, channel: channel)
        try markdown(version: version, build: build, channel: channel)
            .write(to: stage.appendingPathComponent(Self.markdownName), options: .withoutOverwriting)
        try html(version: version, build: build, channel: channel)
            .write(to: stage.appendingPathComponent(Self.htmlName), options: .withoutOverwriting)
    }

    func requireFresh(comparedWith source: String, language: Int, previousTag: String) throws {
        let old = try Self.pendingSection(source, name: Self.sourceNames[language])
        guard languages[language].blocks != old else {
            throw ToolError("\(Self.sourceNames[language])'s Unreleased notes are unchanged since \(previousTag). Update them for this release before building.")
        }
    }
}

/// The release checkout must include tags (CI uses fetch-depth: 0). No remote reads here.
func pendingReleaseNotes(context: ToolContext, tag: String) throws -> ReleaseNotes {
    let sources = try ReleaseNotes.sourceNames.map { name in
        let source = context.root.appendingPathComponent(name)
        try requireRegularFile(source)
        return try String(contentsOf: source, encoding: .utf8)
    }
    let notes = try ReleaseNotes(changelog: sources[0], chineseChangelog: sources[1])
    var environment = context.environment
    environment.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN")
    func git(_ args: [String]) throws -> String {
        try context.runner.run(["git"] + args, environment: environment, sensitive: false)
    }
    let tags = try git(["for-each-ref", "--sort=-creatordate", "--format=%(refname:short)", "refs/tags/v*"])
        .split(whereSeparator: \.isNewline).map(String.init)
    let previousTags = tags.filter { candidate in
        candidate != tag && candidate.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+(?:-beta\.[0-9]+)?$"#, options: .regularExpression) != nil
    }
    for (index, name) in ReleaseNotes.sourceNames.enumerated() {
        // A newer tag may predate or omit one translation. Find the latest tag
        // containing this source rather than silently accepting reused older notes.
        for previous in previousTags {
            let path = try git(["ls-tree", "--name-only", previous, "--", name])
            if !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try notes.requireFresh(comparedWith: git(["show", previous + ":" + name]), language: index, previousTag: previous)
                break
            }
        }
    }
    return notes
}

private func htmlEscaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func markdownEscaped(_ text: String) -> String {
    let escaped = text.map { character in
        "\\`*_{}[]()#+-.!|".contains(character) ? "\\\(character)" : String(character)
    }.joined()
    return htmlEscaped(escaped)
}
