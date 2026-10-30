import Foundation

func configuredBundle(_ original: [String: Any], environment: [String: String]) throws -> [String: Any] {
    var info = original
    let version = environment["VERSION"] ?? info["CFBundleShortVersionString"] as? String ?? ""
    let build = environment["BUILD_NUMBER"] ?? info["CFBundleVersion"] as? String ?? ""
    try validateVersion(version, build: build)
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = build
    let channel = environment["RELEASE_CHANNEL"] ?? "beta"
    guard ["beta", "stable"].contains(channel) else { throw ToolError("RELEASE_CHANNEL must be beta or stable") }
    info["TalklessDefaultUpdateChannel"] = channel
    let stable = (environment["UPDATE_FEED_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let beta = (environment["BETA_UPDATE_FEED_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let key = (environment["SPARKLE_PUBLIC_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let enabled = !stable.isEmpty || !beta.isEmpty || !key.isEmpty
    for name in ["SUFeedURL", "SUBetaFeedURL", "SUPublicEDKey"] { info.removeValue(forKey: name) }
    if enabled {
        guard !stable.isEmpty, !beta.isEmpty, let decoded = Data(base64Encoded: key), decoded.count == 32 else {
            throw ToolError("Both update feed URLs and a 32-byte SPARKLE_PUBLIC_KEY are required")
        }
        info["SUFeedURL"] = try httpsURL(stable, name: "UPDATE_FEED_URL")
        info["SUBetaFeedURL"] = try httpsURL(beta, name: "BETA_UPDATE_FEED_URL")
        guard stable != beta else { throw ToolError("Stable and Beta feeds must be distinct") }
        info["SUPublicEDKey"] = key
    }
    info["SUEnableAutomaticChecks"] = enabled
    info["SUAutomaticallyUpdate"] = false
    info["SUAllowsAutomaticUpdates"] = false
    info["SUSendProfileInfo"] = false
    return info
}

func calendarVersion(ref: String, now: Date = Date(), buildOverride: String? = nil) throws -> [String: String] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
    let build = buildOverride ?? String(Int(now.timeIntervalSince1970))
    let version: String
    let channel: String
    if ref == "refs/heads/main" {
        version = "\(parts.year!).\(parts.month! * 100 + parts.day!).\(parts.hour! * 3600 + parts.minute! * 60 + parts.second!)"
        channel = "beta"
    } else if ref.hasPrefix("refs/tags/v") {
        version = String(ref.dropFirst("refs/tags/v".count))
        try validateVersion(version, build: build)
        let numbers = version.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3, (1...9999).contains(numbers[0]), (0..<86400).contains(numbers[2]) else {
            throw ToolError("Stable release tags must use vYEAR.MDD.UTC_SECONDS")
        }
        let month = numbers[1] / 100, day = numbers[1] % 100
        guard let date = calendar.date(from: DateComponents(year: numbers[0], month: month, day: day)),
              calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else {
            throw ToolError("Invalid calendar version date")
        }
        channel = "stable"
    } else {
        throw ToolError("Releases run only for main or a stable calendar-version tag")
    }
    try validateVersion(version, build: build)
    return ["VERSION": version, "BUILD_NUMBER": build, "RELEASE_CHANNEL": channel,
            "RELEASE_TAG": try releaseTag(version: version, build: build, channel: channel)]
}

func configureBundle(path: URL, context: ToolContext) throws {
    let bytes = try Data(contentsOf: path)
    guard let info = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
        throw ToolError("Invalid application property list")
    }
    let updated = try configuredBundle(info, environment: context.environment)
    try PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0).write(to: path, options: .atomic)
}

func patchResources(in directory: URL) throws {
    for build in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where build.lastPathComponent.hasSuffix(".build") {
        let file = build.appendingPathComponent("DerivedSources/resource_bundle_accessor.swift")
        guard FileManager.default.fileExists(atPath: file.path) else { continue }
        let source = try String(contentsOf: file, encoding: .utf8)
        let updated = source.replacingOccurrences(of: "Bundle.main.bundleURL.appendingPathComponent",
            with: "(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent")
        if source != updated { try updated.write(to: file, atomically: true, encoding: .utf8) }
    }
}
