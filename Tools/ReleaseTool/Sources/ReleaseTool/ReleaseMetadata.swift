import CryptoKit
import Foundation

private func matchesEntire(_ value: String, _ pattern: String) -> Bool {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.firstMatch(in: value, range: range)?.range == range
}

func validateVersion(_ version: String, build: String) throws {
    guard matchesEntire(version, "(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)") else {
        throw ToolError("VERSION must be three non-negative integers, for example 0.1.0.")
    }
    guard matchesEntire(build, "[1-9][0-9]{0,17}") else {
        throw ToolError("BUILD_NUMBER must be a positive integer of at most eighteen digits.")
    }
}

func releaseTag(version: String, build: String, channel: String) throws -> String {
    try validateVersion(version, build: build)
    guard channel == "beta" || channel == "stable" else {
        throw ToolError("RELEASE_CHANNEL must be beta or stable.")
    }
    return channel == "beta" ? "v\(version)-beta.\(build)" : "v\(version)"
}

func feedNames(channel: String) throws -> Set<String> {
    guard channel == "beta" || channel == "stable" else {
        throw ToolError("RELEASE_CHANNEL must be beta or stable.")
    }
    return channel == "beta" ? ["appcast-beta.xml"] : ["appcast.xml", "appcast-beta.xml"]
}

@discardableResult
func httpsURL(_ value: String, name: String) throws -> String {
    guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
          !value.contains("\\"),
          let components = URLComponents(string: value), components.scheme == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil,
          components.url != nil else {
        throw ToolError("\(name) must be an HTTPS URL without credentials, query, fragment, or whitespace.")
    }
    return value
}

struct UpdaterConfiguration: Sendable {
    let stableFeedURL: String?
    let betaFeedURL: String?
    let publicKey: String?
    let keyReference: String?
    let downloadBaseURL: String?

    var isEnabled: Bool { stableFeedURL != nil }

    init(environment: [String: String]) throws {
        let names = ["UPDATE_FEED_URL", "BETA_UPDATE_FEED_URL", "SPARKLE_PUBLIC_KEY", "TALKLESS_SPARKLE_KEY_REF", "DOWNLOAD_BASE_URL"]
        let values = names.map { (environment[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if values.allSatisfy(\.isEmpty) {
            stableFeedURL = nil
            betaFeedURL = nil
            publicKey = nil
            keyReference = nil
            downloadBaseURL = nil
            return
        }
        guard values.allSatisfy({ !$0.isEmpty }) else {
            throw ToolError("Updater configuration is incomplete: set all of " + names.joined(separator: ", ") + ", or none.")
        }
        stableFeedURL = try httpsURL(values[0], name: names[0])
        betaFeedURL = try httpsURL(values[1], name: names[1])
        guard stableFeedURL != betaFeedURL else { throw ToolError("Stable and beta feeds must have distinct URLs.") }
        guard let key = Data(base64Encoded: values[2]), key.count == 32 else {
            throw ToolError("SPARKLE_PUBLIC_KEY must be a base64-encoded 32-byte Ed25519 public key.")
        }
        guard values[3].hasPrefix("op://"), values[3].count > 5 else {
            throw ToolError("TALKLESS_SPARKLE_KEY_REF must be an op:// reference.")
        }
        publicKey = values[2]
        keyReference = values[3]
        var base = try httpsURL(values[4], name: names[4])
        while base.hasSuffix("/") { base.removeLast() }
        downloadBaseURL = base
    }
}

func requireRegularFile(_ path: URL) throws {
    let values: URLResourceValues
    do { values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) }
    catch { throw ToolError("A required release artifact is missing or unreadable.") }
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ToolError("Release artifacts must be regular files, not symbolic links.")
    }
}

func sha256(_ path: URL) throws -> String {
    try requireRegularFile(path)
    let handle = try FileHandle(forReadingFrom: path)
    defer { try? handle.close() }
    var digest = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
        digest.update(data: chunk)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private struct AnyMetadataKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireExactKeys(_ decoder: any Decoder, _ expected: Set<String>) throws {
    let keys = try decoder.container(keyedBy: AnyMetadataKey.self).allKeys.map(\.stringValue)
    guard Set(keys) == expected else { throw ToolError("Release metadata has unexpected or missing fields.") }
}

struct ReleaseFile: Codable, Equatable, Sendable {
    let sha256: String
    let size: UInt64

    init(sha256: String, size: UInt64) {
        self.sha256 = sha256
        self.size = size
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case sha256, size }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = try container.decode(String.self, forKey: .sha256)
        size = try container.decode(UInt64.self, forKey: .size)
        guard matchesEntire(sha256, "[0-9a-f]{64}") else { throw ToolError("Release metadata contains an invalid SHA-256 digest.") }
    }
}

struct ReleaseMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let product: String
    let version: String
    let buildNumber: String
    let tag: String
    let releaseChannel: String
    let architecture: String
    let sourceCommit: String
    let signingIdentity: String
    let teamID: String
    let notarized: Bool
    let stapled: Bool
    let updaterEnabled: Bool
    let updateFeedURL: String?
    let betaUpdateFeedURL: String?
    let downloadBaseURL: String?
    let files: [String: ReleaseFile]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version", product, version, buildNumber = "build_number", tag
        case releaseChannel = "release_channel", architecture, sourceCommit = "source_commit"
        case signingIdentity = "signing_identity", teamID = "team_id", notarized, stapled
        case updaterEnabled = "updater_enabled", updateFeedURL = "update_feed_url"
        case betaUpdateFeedURL = "beta_update_feed_url", downloadBaseURL = "download_base_url", files
    }

    init(version: String, build: String, channel: String, sourceCommit: String,
         configuration: UpdaterConfiguration, files: [String: ReleaseFile]) throws {
        schemaVersion = 2
        product = "Talkless"
        self.version = version
        buildNumber = build
        tag = try releaseTag(version: version, build: build, channel: channel)
        releaseChannel = channel
        architecture = "arm64"
        self.sourceCommit = sourceCommit
        signingIdentity = ToolContext.signingIdentity
        teamID = ToolContext.teamID
        notarized = true
        stapled = true
        updaterEnabled = configuration.isEnabled
        updateFeedURL = configuration.stableFeedURL
        betaUpdateFeedURL = configuration.betaFeedURL
        downloadBaseURL = configuration.downloadBaseURL
        self.files = files
        try validate()
    }

    init(from decoder: any Decoder) throws {
        try requireExactKeys(decoder, Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        product = try c.decode(String.self, forKey: .product)
        version = try c.decode(String.self, forKey: .version)
        buildNumber = try c.decode(String.self, forKey: .buildNumber)
        tag = try c.decode(String.self, forKey: .tag)
        releaseChannel = try c.decode(String.self, forKey: .releaseChannel)
        architecture = try c.decode(String.self, forKey: .architecture)
        sourceCommit = try c.decode(String.self, forKey: .sourceCommit)
        signingIdentity = try c.decode(String.self, forKey: .signingIdentity)
        teamID = try c.decode(String.self, forKey: .teamID)
        notarized = try c.decode(Bool.self, forKey: .notarized)
        stapled = try c.decode(Bool.self, forKey: .stapled)
        updaterEnabled = try c.decode(Bool.self, forKey: .updaterEnabled)
        updateFeedURL = try c.decodeIfPresent(String.self, forKey: .updateFeedURL)
        betaUpdateFeedURL = try c.decodeIfPresent(String.self, forKey: .betaUpdateFeedURL)
        downloadBaseURL = try c.decodeIfPresent(String.self, forKey: .downloadBaseURL)
        files = try c.decode([String: ReleaseFile].self, forKey: .files)
        try validate()
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(product, forKey: .product)
        try c.encode(version, forKey: .version)
        try c.encode(buildNumber, forKey: .buildNumber)
        try c.encode(tag, forKey: .tag)
        try c.encode(releaseChannel, forKey: .releaseChannel)
        try c.encode(architecture, forKey: .architecture)
        try c.encode(sourceCommit, forKey: .sourceCommit)
        try c.encode(signingIdentity, forKey: .signingIdentity)
        try c.encode(teamID, forKey: .teamID)
        try c.encode(notarized, forKey: .notarized)
        try c.encode(stapled, forKey: .stapled)
        try c.encode(updaterEnabled, forKey: .updaterEnabled)
        // These keys are present as JSON null when updates are disabled, matching schema 1.
        try c.encode(updateFeedURL, forKey: .updateFeedURL)
        try c.encode(betaUpdateFeedURL, forKey: .betaUpdateFeedURL)
        try c.encode(downloadBaseURL, forKey: .downloadBaseURL)
        try c.encode(files, forKey: .files)
    }

    var assetStem: String { "Talkless-\(version)-\(buildNumber)-arm64" }

    func expectedAssetNames() throws -> Set<String> {
        var expected: Set<String> = [assetStem + ".zip", assetStem + ".dmg"]
        if schemaVersion >= 2 { expected.formUnion(ReleaseNotes.assetNames) }
        if updaterEnabled { expected.formUnion(try feedNames(channel: releaseChannel)) }
        return expected
    }

    func validate() throws {
        try validateVersion(version, build: buildNumber)
        guard [1, 2].contains(schemaVersion), product == "Talkless", architecture == "arm64",
              signingIdentity == ToolContext.signingIdentity, teamID == ToolContext.teamID,
              notarized, stapled else {
            throw ToolError("Release metadata does not describe a signed, notarized Talkless arm64 release.")
        }
        guard tag == (try releaseTag(version: version, build: buildNumber, channel: releaseChannel)),
              matchesEntire(sourceCommit, "[0-9a-f]{40}") else {
            throw ToolError("Release tag or source commit is invalid.")
        }
        if updaterEnabled {
            guard let updateFeedURL, let betaUpdateFeedURL, let downloadBaseURL else {
                throw ToolError("Release metadata has incomplete updater URLs.")
            }
            try httpsURL(updateFeedURL, name: "update_feed_url")
            try httpsURL(betaUpdateFeedURL, name: "beta_update_feed_url")
            try httpsURL(downloadBaseURL, name: "download_base_url")
            guard updateFeedURL != betaUpdateFeedURL else { throw ToolError("Stable and beta feeds must have distinct URLs.") }
        } else if updateFeedURL != nil || betaUpdateFeedURL != nil || downloadBaseURL != nil {
            throw ToolError("Disabled updater metadata must have null updater URLs.")
        }
        guard Set(files.keys) == (try expectedAssetNames()),
              files.values.allSatisfy({ matchesEntire($0.sha256, "[0-9a-f]{64}") }) else {
            throw ToolError("Unexpected or missing release assets in metadata.")
        }
    }

    var checksumText: String {
        files.keys.sorted().map { "\(files[$0]!.sha256)  \($0)\n" }.joined()
    }
}

@discardableResult
func writeMetadata(stage: URL, version: String, build: String, channel: String, sourceCommit: String,
                   configuration: UpdaterConfiguration) throws -> ReleaseMetadata {
    try validateVersion(version, build: build)
    _ = try releaseTag(version: version, build: build, channel: channel)
    let stem = "Talkless-\(version)-\(build)-arm64"
    var expected: Set<String> = [stem + ".zip", stem + ".dmg"]
    expected.formUnion(ReleaseNotes.assetNames)
    if configuration.isEnabled { expected.formUnion(try feedNames(channel: channel)) }
    let paths = try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
    guard Set(paths.map(\.lastPathComponent)) == expected else {
        throw ToolError("The release stage contains unexpected or missing assets.")
    }
    var files: [String: ReleaseFile] = [:]
    for path in paths {
        let digest = try sha256(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard let size = attributes[.size] as? NSNumber else { throw ToolError("Could not determine release artifact size.") }
        files[path.lastPathComponent] = ReleaseFile(sha256: digest, size: size.uint64Value)
    }
    let metadata = try ReleaseMetadata(version: version, build: build, channel: channel,
                                       sourceCommit: sourceCommit, configuration: configuration, files: files)
    _ = try validateReleaseNotes(directory: stage, metadata: metadata)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(metadata)
    data.append(0x0a)
    try Data(metadata.checksumText.utf8).write(to: stage.appendingPathComponent("SHA256SUMS"), options: .withoutOverwriting)
    try data.write(to: stage.appendingPathComponent("release-metadata.json"), options: .withoutOverwriting)
    return metadata
}
