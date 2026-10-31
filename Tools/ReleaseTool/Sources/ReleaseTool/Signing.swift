import Foundation
import Darwin

/// Owns one private keychain. It never changes the user's keychain search list or default.
final class SigningSession {
    let context: ToolContext
    let directory: URL
    let keychain: URL
    var environment: [String: String]
    private var keychainCreated = false
    private var notaryKeyID = ""
    private var notaryIssuer = ""

    init(context: ToolContext, directory: URL, environment: [String: String]) {
        self.context = context
        self.directory = directory
        self.keychain = directory.appendingPathComponent("talkless-signing.keychain-db")
        self.environment = environment
        self.environment.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN")
    }

    func prepare(configuration: UpdaterConfiguration, notarization: Bool = true) throws {
        var secretsEnvironment = environment
        secretsEnvironment["OP_SERVICE_ACCOUNT_TOKEN"] = context.environment["OP_SERVICE_ACCOUNT_TOKEN"]
        defer { secretsEnvironment.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN") }
        if secretsEnvironment["OP_SERVICE_ACCOUNT_TOKEN", default: ""].isEmpty {
            secretsEnvironment["OP_SERVICE_ACCOUNT_TOKEN"] = try context.runner.run([
                "/bin/zsh", "-f", "-c",
                "set +x; source \"$HOME/.config/secrets.zsh\" >/dev/null 2>&1; set +x; print -rn -- \"${OP_SERVICE_ACCOUNT_TOKEN:-}\""
            ], environment: secretsEnvironment, sensitive: true)
        }
        try signingRequire(!secretsEnvironment["OP_SERVICE_ACCOUNT_TOKEN", default: ""].isEmpty,
                           "1Password service account token is unavailable.")
        let names = notarization ? signingSecretReferences : Array(signingSecretReferences.prefix(2))
        try signingRequire(names.allSatisfy { environment[$0, default: ""].hasPrefix("op://") },
                           "Configure op:// references for " + names.joined(separator: ", ") + ".")
        func secret(_ reference: String) throws -> String {
            try signingRequire(reference.hasPrefix("op://"), "Secret references must start with op://.")
            return try context.runner.run(["op", "read", "--no-newline", reference],
                                          environment: secretsEnvironment, sensitive: true)
        }
        let certificate = directory.appendingPathComponent("certificate.p12")
        let encoded = try secret(environment["SIGNING_CERTIFICATE_REF"]!)
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let certificateData = Data(base64Encoded: encoded), !certificateData.isEmpty else {
            throw ToolError("The signing certificate must be nonempty base64 PKCS#12 data.")
        }
        try writeSigningSecret(certificateData, to: certificate)
        let password = try secret(environment["SIGNING_PASSWORD_REF"]!)
        if notarization {
            try writeSigningSecret(Data(secret(environment["NOTARY_KEY_REF"]!).utf8),
                                   to: directory.appendingPathComponent("AuthKey.p8"))
            notaryKeyID = try secret(environment["NOTARY_KEY_ID_REF"]!)
            notaryIssuer = try secret(environment["NOTARY_ISSUER_REF"]!)
        }
        if let reference = configuration.keyReference {
            try writeSigningSecret(Data(secret(reference).utf8), to: directory.appendingPathComponent("sparkle-key"))
        }
        secretsEnvironment.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN")
        let keychainPassword = UUID().uuidString + UUID().uuidString
        keychainCreated = true // Clean up even a partially successful creation.
        for command in [
            ["security", "create-keychain", "-p", keychainPassword, keychain.path],
            ["security", "set-keychain-settings", "-lut", "7200", keychain.path],
            ["security", "unlock-keychain", "-p", keychainPassword, keychain.path],
            ["security", "import", certificate.path, "-k", keychain.path, "-P", password,
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"],
            ["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
             "-s", "-k", keychainPassword, keychain.path]
        ] {
            _ = try context.runner.run(command, environment: environment, sensitive: true)
        }
        try FileManager.default.removeItem(at: certificate)
        environment["CODE_SIGN_IDENTITY"] = ToolContext.signingIdentity
        environment["SIGNING_KEYCHAIN"] = keychain.path
    }

    func close() {
        environment.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN")
        if keychainCreated {
            context.cleanupRun(["security", "delete-keychain", keychain.path], environment: environment)
            keychainCreated = false
        }
    }

    func notarize(_ artifact: URL) throws {
        let output = try context.runner.run([
            "xcrun", "notarytool", "submit", artifact.path,
            "--key", directory.appendingPathComponent("AuthKey.p8").path,
            "--key-id", notaryKeyID, "--issuer", notaryIssuer,
            "--wait", "--timeout", "30m", "--output-format", "json"
        ], environment: environment, sensitive: true)
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        try signingRequire(result?["status"] as? String == "Accepted",
                           "Apple did not accept notarization; no release artifacts will be promoted.")
    }

    func staple(_ artifact: URL) throws {
        for attempt in 1...40 {
            do {
                _ = try context.runner.run(["xcrun", "stapler", "staple", artifact.path],
                                           environment: environment, sensitive: true)
            } catch {
                try context.checkCancellation()
                guard attempt < 40 else { throw ToolError("Could not staple the notarization ticket after 40 attempts.") }
                print("Stapling attempt \(attempt)/40 failed; retrying in 30 seconds.")
                try context.sleep(seconds: 30)
                continue
            }
            _ = try context.runner.run(["xcrun", "stapler", "validate", artifact.path],
                                       environment: environment, sensitive: false)
            return
        }
    }
}

let signingSecretReferences = ["SIGNING_CERTIFICATE_REF", "SIGNING_PASSWORD_REF", "NOTARY_KEY_REF",
                               "NOTARY_KEY_ID_REF", "NOTARY_ISSUER_REF"]

func signingRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw ToolError(message) }
}

func writeSigningSecret(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func signingPathExists(_ url: URL) -> Bool {
    var value = stat()
    return lstat(url.path, &value) == 0
}

func signingIsSymlink(_ url: URL) -> Bool {
    var value = stat()
    return lstat(url.path, &value) == 0 && (value.st_mode & S_IFMT) == S_IFLNK
}

func signingDirectory(parent: URL, prefix: String) throws -> URL {
    let result = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    return result
}

func signingTemporaryRoot(context: ToolContext) throws -> URL {
    let temporary = URL(fileURLWithPath: context.environment["TMPDIR"] ?? NSTemporaryDirectory(),
                        isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    let root = context.root.resolvingSymlinksInPath().standardizedFileURL.path
    try signingRequire(temporary.path != root && !temporary.path.hasPrefix(root + "/"),
                       "TMPDIR must be outside the project for signing secrets.")
    return temporary
}

func requireSigningTools(_ names: [String], context: ToolContext) throws {
    #if !arch(arm64)
    throw ToolError("Signing builds require an Apple Silicon Mac.")
    #else
    let paths = context.environment["PATH", default: "/usr/bin:/bin:/usr/sbin:/sbin"].split(separator: ":")
    for name in names {
        try signingRequire(paths.contains { FileManager.default.isExecutableFile(atPath: String($0) + "/" + name) },
                           "Required tool is unavailable: \(name)")
    }
    #endif
}

func signingLock(context: ToolContext) throws -> URL {
    let dist = context.root.appendingPathComponent("dist", isDirectory: true)
    try signingRequire(!signingIsSymlink(dist), "dist must not be a symlink.")
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    let lock = dist.appendingPathComponent(".release-lock", isDirectory: true)
    guard mkdir(lock.path, 0o700) == 0 else {
        throw ToolError("Cannot acquire dist/.release-lock; another build may be running.")
    }
    return lock
}

func verifySigningSignature(_ path: URL, context: ToolContext, environment: [String: String]) throws {
    _ = try context.runner.run(["codesign", "--verify", "--deep", "--strict", path.path],
                               environment: environment, sensitive: false)
    // codesign writes successful display output to stderr; redirect only this command.
    let output = try context.runner.run([
        "/bin/sh", "-c", "exec codesign -d --verbose=4 \"$1\" 2>&1", "sh", path.path
    ], environment: environment, sensitive: false)
    let lines = output.components(separatedBy: .newlines)
    try signingRequire(lines.contains("TeamIdentifier=" + ToolContext.teamID)
                       && lines.contains("Authority=" + ToolContext.signingIdentity)
                       && lines.contains { $0.hasPrefix("Timestamp=") && $0.count > "Timestamp=".count },
                       "Signature is missing the expected Developer ID, Team ID, or secure timestamp.")
}

func signingAppInfo(_ app: URL) throws -> [String: Any] {
    var isDirectory: ObjCBool = false
    try signingRequire(FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory)
                       && isDirectory.boolValue && !signingIsSymlink(app),
                       "Expected a real Talkless app directory: \(app.path)")
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        throw ToolError("Invalid app property list: \(app.path)")
    }
    return info
}

func verifySigningConfiguration(_ info: [String: Any], version: String, build: String,
                                channel: String, environment: [String: String]) throws {
    try signingRequire(info["CFBundleShortVersionString"] as? String == version
                       && info["CFBundleVersion"] as? String == build
                       && info["TalklessDefaultUpdateChannel"] as? String == channel
                       && (info["SUFeedURL"] as? String ?? "") == environment["UPDATE_FEED_URL", default: ""]
                       && (info["SUBetaFeedURL"] as? String ?? "") == environment["BETA_UPDATE_FEED_URL", default: ""]
                       && (info["SUPublicEDKey"] as? String ?? "") == environment["SPARKLE_PUBLIC_KEY", default: ""],
                       "Built app version or updater settings do not match the requested configuration.")
}

func release(context: ToolContext, version: String, build: String) throws {
    try validateVersion(version, build: build)
    let channel = context.environment["RELEASE_CHANNEL", default: "beta"]
    let tag = try releaseTag(version: version, build: build, channel: channel)
    let configuration = try UpdaterConfiguration(environment: context.environment)
    let releaseNotes = try pendingReleaseNotes(context: context, tag: tag)
    try requireSigningTools(["op", "security", "codesign", "xcrun", "swift", "ditto", "hdiutil", "git"], context: context)
    var environment = context.environment
    environment.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN")
    let commit = try context.runner.run(["git", "rev-parse", "HEAD"], environment: environment, sensitive: false)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let status = try context.runner.run(["git", "status", "--porcelain"], environment: environment, sensitive: false)
    try signingRequire(status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Commit or stash working-tree changes before building a release.")
    let lock = try signingLock(context: context)
    defer { try? FileManager.default.removeItem(at: lock) }
    let releases = context.root.appendingPathComponent("dist/releases", isDirectory: true)
    try signingRequire(!signingIsSymlink(releases), "Release output directory must not be a symlink.")
    try FileManager.default.createDirectory(at: releases, withIntermediateDirectories: true)
    let destination = releases.appendingPathComponent("\(version)-\(build)", isDirectory: true)
    try signingRequire(!signingPathExists(destination), "Release output already exists: \(destination.path)")
    let secretDirectory = try signingDirectory(parent: signingTemporaryRoot(context: context), prefix: "talkless-signing-")
    defer { try? FileManager.default.removeItem(at: secretDirectory) }
    let stage = try signingDirectory(parent: releases, prefix: ".talkless-release-")
    defer { try? FileManager.default.removeItem(at: stage) }
    try releaseNotes.write(to: stage, version: version, build: build, channel: channel)
    let session = SigningSession(context: context, directory: secretDirectory, environment: environment)
    defer { session.close() }
    print("Preparing a temporary signing session (credential output is suppressed).")
    try session.prepare(configuration: configuration)
    session.environment.merge([
        "VERSION": version, "BUILD_NUMBER": build, "CONFIGURATION": "release", "RELEASE_CHANNEL": channel,
        "UPDATE_FEED_URL": configuration.stableFeedURL ?? "",
        "BETA_UPDATE_FEED_URL": configuration.betaFeedURL ?? "", "SPARKLE_PUBLIC_KEY": configuration.publicKey ?? ""
    ], uniquingKeysWith: { _, new in new })
    environment = session.environment
    print("Building Talkless with " + (configuration.isEnabled ? "signed Sparkle updates." : "updater disabled (signed test release)."))
    let app = context.root.appendingPathComponent("dist/Talkless.app")
    try signingRequire(!signingIsSymlink(app), "The build output app must not be a symlink.")
    _ = try context.runner.run(["/bin/bash", context.root.appendingPathComponent("scripts/build-app.sh").path],
                               environment: environment, sensitive: false)
    let info = try signingAppInfo(app)
    try verifySigningConfiguration(info, version: version, build: build, channel: channel, environment: environment)
    try verifySigningSignature(app, context: context, environment: environment)
    let submission = secretDirectory.appendingPathComponent("notarize-app.zip")
    _ = try context.runner.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app.path, submission.path],
                               environment: environment, sensitive: false)
    print("Submitting the app for notarization.")
    try session.notarize(submission)
    try session.staple(app)
    try verifySigningSignature(app, context: context, environment: environment)
    try verifyExecutablePrivacy(app.appendingPathComponent("Contents/MacOS/Talkless"), forbiddenPaths: [context.root.path, environment["HOME"] ?? ""])
    try verifyRelocatedBundle(app: app, deniedPaths: [context.root.appendingPathComponent(".build").path], context: context)
    let imageSource = try signingDirectory(parent: secretDirectory, prefix: "dmg-root-")
    _ = try context.runner.run(["ditto", app.path, imageSource.appendingPathComponent("Talkless.app").path],
                               environment: environment, sensitive: false)
    try FileManager.default.createSymbolicLink(atPath: imageSource.appendingPathComponent("Applications").path,
                                              withDestinationPath: "/Applications")
    let stem = "Talkless-\(version)-\(build)-arm64"
    let dmg = stage.appendingPathComponent(stem + ".dmg")
    _ = try context.runner.run(["hdiutil", "create", "-volname", "Talkless", "-srcfolder", imageSource.path,
                                "-format", "UDZO", "-fs", "HFS+", dmg.path], environment: environment, sensitive: false)
    _ = try context.runner.run(["codesign", "--force", "--sign", ToolContext.signingIdentity,
                                "--keychain", session.keychain.path, "--timestamp", dmg.path],
                               environment: environment, sensitive: false)
    try verifySigningSignature(dmg, context: context, environment: environment)
    print("Submitting the disk image for notarization.")
    try session.notarize(dmg)
    try session.staple(dmg)
    try verifySigningSignature(dmg, context: context, environment: environment)
    // Make the final ZIP only after app stapling; never mutate archives after signing/checksums.
    let archive = stage.appendingPathComponent(stem + ".zip")
    _ = try context.runner.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path],
                               environment: environment, sensitive: false)
    if configuration.isEnabled {
        guard let minimumOS = info["LSMinimumSystemVersion"] as? String else { throw ToolError("Built app has no minimum macOS version.") }
        try generateSignedAppcasts(context: context, stage: stage, archive: archive, configuration: configuration,
                                   version: version, build: build, minimumOS: minimumOS, channel: channel,
                                   secretDirectory: secretDirectory, environment: environment)
    }
    _ = try writeMetadata(stage: stage, version: version, build: build, channel: channel,
                          sourceCommit: commit, configuration: configuration)
    try context.checkCancellation()
    try signingRequire(!signingPathExists(destination), "Release destination appeared during the build; refusing to overwrite it.")
    try FileManager.default.moveItem(at: stage, to: destination)
    print("Release artifacts: \(destination.path)\nNothing was published.")
}
