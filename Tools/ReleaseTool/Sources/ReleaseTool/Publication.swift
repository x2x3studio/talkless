import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

private func xmlEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

func makeAppcast(version: String, build: String, minimumOS: String, downloadURL: String,
                 signature: String, length: UInt64) throws -> Data {
    try validateVersion(version, build: build)
    try httpsURL(downloadURL, name: "Appcast download URL")
    guard let signatureData = Data(base64Encoded: signature), signatureData.count == 64 else {
        throw ToolError("Invalid Sparkle signature length.")
    }
    guard minimumOS.range(of: "^[0-9]+(?:\\.[0-9]+){0,2}$", options: .regularExpression) != nil,
          !minimumOS.contains(where: \.isNewline) else {
        throw ToolError("Invalid minimum system version.")
    }
    return Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss xmlns:sparkle="\(sparkleNamespace)" version="2.0">
      <channel>
        <title>Talkless Updates</title>
        <language>en</language>
        <item>
          <title>Talkless \(xmlEscaped(version))</title>
          <sparkle:version>\(xmlEscaped(build))</sparkle:version>
          <sparkle:shortVersionString>\(xmlEscaped(version))</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>\(xmlEscaped(minimumOS))</sparkle:minimumSystemVersion>
          <enclosure url="\(xmlEscaped(downloadURL))" length="\(length)" type="application/octet-stream" sparkle:edSignature="\(xmlEscaped(signature))" />
        </item>
      </channel>
    </rss>

    """.utf8)
}

func verifySparkleSignature(archive: URL, signature: String, publicKey: String) throws {
    guard let signatureData = Data(base64Encoded: signature), signatureData.count == 64,
          let keyData = Data(base64Encoded: publicKey), keyData.count == 32 else {
        throw ToolError("Invalid Sparkle signature or public key.")
    }
    try requireRegularFile(archive)
    let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signatureData, for: bytes) else {
        throw ToolError("Sparkle signature does not match the archive and configured public key.")
    }
}

private func sparkleSigningTool(context: ToolContext, environment: [String: String]) throws -> URL {
    let tools: [URL]
    if let configured = environment["SPARKLE_SIGN_UPDATE"], !configured.isEmpty {
        let path = (configured as NSString).expandingTildeInPath
        tools = [URL(fileURLWithPath: path, relativeTo: context.root).standardizedFileURL.resolvingSymlinksInPath()]
    } else {
        let artifacts = context.root.appendingPathComponent(".build/artifacts", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: artifacts, includingPropertiesForKeys: [.isRegularFileKey])
        tools = (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.lastPathComponent == "sign_update" && $0.deletingLastPathComponent().lastPathComponent == "bin"
        }
    }
    guard tools.count == 1, let tool = tools.first,
          (try? tool.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        throw ToolError("Sparkle sign_update was not found uniquely. Set SPARKLE_SIGN_UPDATE to the pinned Sparkle distribution's bin/sign_update.")
    }
    return tool
}

func generateSignedAppcasts(context: ToolContext, stage: URL, archive: URL,
                            configuration: UpdaterConfiguration, version: String, build: String,
                            minimumOS: String, channel: String, secretDirectory: URL,
                            environment: [String: String]) throws {
    guard configuration.isEnabled, let publicKey = configuration.publicKey,
          let baseURL = configuration.downloadBaseURL else {
        throw ToolError("Signed appcasts require a complete updater configuration.")
    }
    try validateVersion(version, build: build)
    let names = try feedNames(channel: channel)
    try requireRegularFile(archive)
    let tool = try sparkleSigningTool(context: context, environment: environment)
    var safeEnvironment = environment
    safeEnvironment.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN")
    let signature = try context.runner.run([
        tool.path, "--ed-key-file", secretDirectory.appendingPathComponent("sparkle-key").path, "-p", archive.path,
    ], environment: safeEnvironment, sensitive: true).trimmingCharacters(in: .whitespacesAndNewlines)
    // CryptoKit verifies the exact final archive against the public key embedded in the app.
    // No Swift source, private-key material, or helper interpreter is generated at runtime.
    try verifySparkleSignature(archive: archive, signature: signature, publicKey: publicKey)
    let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
    guard let size = attributes[.size] as? NSNumber else { throw ToolError("Could not determine archive size.") }
    let appcast = try makeAppcast(version: version, build: build, minimumOS: minimumOS,
                                 downloadURL: baseURL + "/" + archive.lastPathComponent,
                                 signature: signature, length: size.uint64Value)
    for name in names.sorted() {
        try appcast.write(to: stage.appendingPathComponent(name), options: .withoutOverwriting)
    }
}

// FoundationXML must never resolve network/file entities from a downloaded feed.
private func parseRSS(_ data: Data) throws -> (XMLDocument, XMLElement) {
    guard let text = String(data: data, encoding: .utf8),
          !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
          !text.localizedCaseInsensitiveContains("<!ENTITY") else {
        throw ToolError("Existing update feed must be UTF-8 RSS without a document type or entities.")
    }
    let document: XMLDocument
    do { document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) }
    catch { throw ToolError("Existing update feed is not valid XML.") }
    guard let root = document.rootElement(), root.name == "rss", root.uri == nil || root.uri == "",
          root.elements(forName: "channel").count == 1,
          let channel = root.elements(forName: "channel").first else {
        throw ToolError("Existing update feed is not an RSS channel.")
    }
    return (document, channel)
}

func validateFeedMonotonicity(_ data: Data, build: String) throws {
    try validateVersion("0.0.0", build: build)
    let (document, channel) = try parseRSS(data)
    // Foundation's XPath namespace-uri() matching is inconsistent across macOS
    // releases; match the XML node's resolved namespace explicitly instead.
    func sparkleVersions(in node: XMLNode) -> [XMLElement] {
        let children = node.children ?? []
        return children.flatMap { child -> [XMLElement] in
            let own: [XMLElement]
            if let element = child as? XMLElement, element.localName == "version", element.uri == sparkleNamespace {
                own = [element]
            } else {
                own = []
            }
            return own + sparkleVersions(in: child)
        }
    }
    let nodes = sparkleVersions(in: document)
    let nextBuild = UInt64(build)!
    for node in nodes {
        let text = node.stringValue ?? ""
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let current = UInt64(text), current > 0 else {
            throw ToolError("Existing update feed contains an invalid Sparkle build number.")
        }
        guard nextBuild > current else {
            throw ToolError("BUILD_NUMBER must exceed every currently published stable/beta feed build.")
        }
    }
    // An empty, valid RSS channel is the supported bootstrap manifest. Every nonempty
    // item must have its own valid build; a single valid sibling cannot hide a bad item.
    for item in channel.elements(forName: "item") {
        let builds = item.elements(forLocalName: "version", uri: sparkleNamespace)
        guard builds.count == 1 else { throw ToolError("Existing update feed items must have one Sparkle build number.") }
    }
}

private struct RepositoryResponse: Decodable { let `private`: Bool }
private struct FeedReleaseResponse: Decodable {
    struct Asset: Decodable { let name: String }
    let isDraft: Bool
    let assets: [Asset]
}

private func decodeResponse<T: Decodable>(_ type: T.Type, text: String) throws -> T {
    do { return try JSONDecoder().decode(type, from: Data(text.utf8)) }
    catch { throw ToolError("GitHub returned an invalid release response; publication stopped.") }
}

func publish(context: ToolContext, directory: URL, publishPublic: Bool) throws {
    let repository = context.environment["RELEASE_REPOSITORY"] ?? ToolContext.repository
    guard repository == ToolContext.repository else { throw ToolError("RELEASE_REPOSITORY must be \(ToolContext.repository).") }
    let acknowledged = context.environment["PUBLIC_RELEASE_ACK"] == repository
    guard !publishPublic || acknowledged else {
        throw ToolError("Public publication requires --publish and PUBLIC_RELEASE_ACK=\(repository).")
    }
    let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    let metadataPath = directory.appendingPathComponent("release-metadata.json")
    try requireRegularFile(metadataPath)
    let metadata: ReleaseMetadata
    do { metadata = try JSONDecoder().decode(ReleaseMetadata.self, from: Data(contentsOf: metadataPath)) }
    catch { throw ToolError("Release metadata is invalid; publication stopped.") }
    let expected = try metadata.expectedAssetNames()
    let allowed = expected.union(["SHA256SUMS", "release-metadata.json"])
    let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    guard Set(entries.map(\.lastPathComponent)) == allowed else {
        throw ToolError("Release directory contains unexpected or missing files.")
    }
    if publishPublic && metadata.updaterEnabled {
        guard metadata.downloadBaseURL == "https://github.com/\(repository)/releases/download/\(metadata.tag)" else {
            throw ToolError("The appcast download base must match this public repository and release tag.")
        }
        guard metadata.updateFeedURL == "https://github.com/\(repository)/releases/download/updates/appcast.xml",
              metadata.betaUpdateFeedURL == "https://github.com/\(repository)/releases/download/updates/appcast-beta.xml" else {
            throw ToolError("Public feeds must use the pre-provisioned updates release asset URLs.")
        }
    }
    for name in expected.sorted() {
        let path = directory.appendingPathComponent(name)
        try requireRegularFile(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard let size = attributes[.size] as? NSNumber, let item = metadata.files[name],
              size.uint64Value == item.size, try sha256(path) == item.sha256 else {
            throw ToolError("Release artifact has changed: \(name)")
        }
    }
    let sums = directory.appendingPathComponent("SHA256SUMS")
    try requireRegularFile(sums)
    guard try Data(contentsOf: sums) == Data(metadata.checksumText.utf8) else {
        throw ToolError("SHA256SUMS does not match release metadata.")
    }
    var environment = context.environment
    environment.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN")
    func run(_ arguments: [String]) throws -> String {
        try context.runner.run(arguments, environment: environment, sensitive: false)
    }
    // Query only: this tool never creates a repository or changes its visibility.
    let repo = try decodeResponse(RepositoryResponse.self, text: run(["gh", "api", "repos/\(repository)"]))
    guard repo.private || acknowledged else {
        throw ToolError("Uploading even a draft to the public repository requires PUBLIC_RELEASE_ACK=\(repository).")
    }
    guard !publishPublic || !repo.private else { throw ToolError("--publish requires the repository to be public.") }
    if publishPublic && metadata.updaterEnabled {
        let feeds = try decodeResponse(FeedReleaseResponse.self, text: run([
            "gh", "release", "view", "updates", "--repo", repository, "--json", "isDraft,assets",
        ]))
        guard !feeds.isDraft else { throw ToolError("The pre-provisioned updates release must already be published.") }
        let allFeeds = try feedNames(channel: "stable")
        let names = feeds.assets.map(\.name).filter { allFeeds.contains($0) }
        guard Set(names).count == names.count else { throw ToolError("The updates release has duplicate feed assets.") }
        // Each download gets a newly created, empty directory; no downloaded content is executed.
        for name in names.sorted() {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-feed-check-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            _ = try run(["gh", "release", "download", "updates", "--repo", repository,
                         "--pattern", name, "--dir", temporary.path])
            let feed = temporary.appendingPathComponent(name)
            try requireRegularFile(feed)
            try validateFeedMonotonicity(Data(contentsOf: feed), build: metadata.buildNumber)
        }
    }
    let notes = "Talkless \(metadata.version) \(metadata.releaseChannel) (build \(metadata.buildNumber)) for Apple Silicon.\n\n"
        + "Developer ID signed and notarized ZIP and disk image. "
        + (metadata.updaterEnabled ? "Sparkle updates are enabled.\n" : "Automatic updates are disabled in this signed test release.\n")
    var arguments = ["gh", "release", "create", metadata.tag, "--repo", repository, "--draft", "--title",
                     "Talkless \(metadata.version)", "--notes", notes]
    if metadata.releaseChannel == "beta" { arguments.append("--prerelease") }
    arguments += ["--target", metadata.sourceCommit]
    arguments += allowed.sorted().map { directory.appendingPathComponent($0).path }
    // gh release create fails if this release already exists. There is deliberately no
    // retry, edit, upload/clobber, or overwrite path for immutable release assets.
    _ = try run(arguments)
    if publishPublic {
        _ = try run(["gh", "release", "edit", metadata.tag, "--repo", repository, "--draft=false",
                     metadata.releaseChannel == "stable" ? "--latest" : "--latest=false"])
        if metadata.updaterEnabled {
            // Mutable manifests are last, only after all immutable assets are public.
            // GitHub has no multi-asset transaction: callers must serialize publication.
            _ = try run(["gh", "release", "upload", "updates", "--repo", repository, "--clobber"]
                        + (try feedNames(channel: metadata.releaseChannel)).sorted().map { directory.appendingPathComponent($0).path })
        }
    }
    print("\(publishPublic ? "Published" : "Created draft"): \(repository) \(metadata.tag)")
}
