import Foundation
import Darwin

func localAppInfo(_ app: URL) throws -> [String: Any] {
    let info = try signingAppInfo(app)
    try signingRequire(info["CFBundleIdentifier"] as? String == "com.x2x3studio.talkless"
                       && info["CFBundleExecutable"] as? String == "Talkless",
                       "Refusing to replace an unrelated app: \(app.path)")
    return info
}

struct InstalledAppSnapshot: Equatable {
    let device: dev_t
    let inode: ino_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init(_ app: URL) throws {
        var value = stat()
        guard lstat(app.path, &value) == 0 else { throw ToolError("Cannot inspect installed app: \(app.path)") }
        device = value.st_dev
        inode = value.st_ino
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
    }
}

func requireTalklessStopped(context: ToolContext, environment: [String: String]) throws {
    do {
        // pgrep's 1 means no matches; errors and matches both stop installation.
        _ = try context.runner.run([
            "/bin/sh", "-c", "pgrep -u \"$1\" -x Talkless >/dev/null; [ \"$?\" -eq 1 ]", "sh", String(getuid())
        ], environment: environment, sensitive: true)
    } catch {
        try context.checkCancellation()
        throw ToolError("Quit Talkless before installing (the installer never terminates apps or resets permissions).")
    }
}

/// Keep the old app only for this transaction. On success the caller removes the staging directory.
func replaceLocalApp(stagedApp: URL, target: URL, original: InstalledAppSnapshot?,
                     context: ToolContext, environment: [String: String]) throws {
    try requireTalklessStopped(context: context, environment: environment)
    if let original {
        _ = try localAppInfo(target)
        try signingRequire(try InstalledAppSnapshot(target) == original,
                           "Installed app changed during the build; refusing to overwrite it.")
    } else {
        try signingRequire(!signingPathExists(target), "An app appeared at the install destination during the build.")
    }
    try requireTalklessStopped(context: context, environment: environment)
    try context.checkCancellation()
    let stage = stagedApp.deletingLastPathComponent()
    let previous = stage.appendingPathComponent("Previous-Talkless.app")
    var movedPrevious = false
    var installed = false
    do {
        if original != nil {
            try FileManager.default.moveItem(at: target, to: previous)
            movedPrevious = true
        }
        try FileManager.default.moveItem(at: stagedApp, to: target)
        installed = true
        _ = try localAppInfo(target)
        try verifySigningSignature(target, context: context, environment: environment)
        try context.checkCancellation()
    } catch {
        let installationError = error
        do {
            if installed {
                try FileManager.default.moveItem(at: target, to: stage.appendingPathComponent("Failed-Talkless.app"))
            }
            if movedPrevious { try FileManager.default.moveItem(at: previous, to: target) }
        } catch {
            // Never delete the only intact original if the filesystem prevents rollback.
            throw ToolError("Installation failed and rollback could not finish. Recover the original app from \(previous.path).")
        }
        throw installationError
    }
}

func localInstall(context: ToolContext, noUpdater: Bool) throws {
    try requireSigningTools(["op", "security", "codesign", "swift", "ditto", "pgrep"], context: context)
    let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let target = applications.appendingPathComponent("Talkless.app", isDirectory: true)
    var isDirectory: ObjCBool = false
    try signingRequire(FileManager.default.fileExists(atPath: applications.path, isDirectory: &isDirectory)
                       && isDirectory.boolValue && !signingIsSymlink(applications)
                       && access(applications.path, W_OK | X_OK) == 0,
                       "/Applications must be writable by this user; this installer does not use sudo.")
    var environment = context.environment
    environment.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN")
    try requireTalklessStopped(context: context, environment: environment)
    let existing = signingPathExists(target) ? try localAppInfo(target) : nil
    let original = existing != nil ? try InstalledAppSnapshot(target) : nil
    let source: [String: Any]
    if let existing { source = existing } else {
        let data = try Data(contentsOf: context.root.appendingPathComponent("Resources/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ToolError("Invalid source app property list.")
        }
        source = info
    }
    // Preserve installed release ordering; never invent a future release build number.
    guard let version = source["CFBundleShortVersionString"] as? String,
          let build = source["CFBundleVersion"] as? String else { throw ToolError("Missing app version or build number.") }
    try validateVersion(version, build: build)
    let publicNames = ["UPDATE_FEED_URL", "BETA_UPDATE_FEED_URL", "SPARKLE_PUBLIC_KEY"]
    let names = Array(signingSecretReferences.prefix(2)) + (noUpdater ? [] : publicNames)
    for name in names where environment[name, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try requireSigningTools(["gh"], context: context)
        environment[name] = try context.runner.run(["gh", "variable", "get", name, "--repo", ToolContext.repository],
                                                   environment: environment, sensitive: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try signingRequire(signingSecretReferences.prefix(2).allSatisfy { environment[$0, default: ""].hasPrefix("op://") },
                       "Signing settings must be op:// references, not private values.")
    if noUpdater {
        for name in publicNames { environment[name] = "" }
    } else {
        for name in publicNames.prefix(2) {
            environment[name] = try httpsURL(environment[name, default: ""].trimmingCharacters(in: .whitespacesAndNewlines), name: name)
        }
        try signingRequire(environment[publicNames[0]] != environment[publicNames[1]], "Stable and beta feeds must have distinct URLs.")
        let key = environment["SPARKLE_PUBLIC_KEY", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        try signingRequire(Data(base64Encoded: key)?.count == 32, "SPARKLE_PUBLIC_KEY must encode a 32-byte Ed25519 public key.")
        environment["SPARKLE_PUBLIC_KEY"] = key
    }
    environment.merge(["VERSION": version, "BUILD_NUMBER": build, "RELEASE_CHANNEL": "beta", "CONFIGURATION": "release"],
                      uniquingKeysWith: { _, new in new })
    let temporaryRoot = try signingTemporaryRoot(context: context)
    let lock = try signingLock(context: context)
    defer { try? FileManager.default.removeItem(at: lock) }
    let app = context.root.appendingPathComponent("dist/Talkless.app")
    try signingRequire(!signingIsSymlink(app), "The build output app must not be a symlink.")
    let secretDirectory = try signingDirectory(parent: temporaryRoot, prefix: "talkless-local-signing-")
    defer { try? FileManager.default.removeItem(at: secretDirectory) }
    let session = SigningSession(context: context, directory: secretDirectory, environment: environment)
    defer { session.close() }
    print("Preparing the release Developer ID in a private temporary keychain.")
    // No notary credentials or Sparkle private key are needed for local builds.
    try session.prepare(configuration: UpdaterConfiguration(environment: [:]), notarization: false)
    environment = session.environment
    print("Building local Talkless \(version) (\(build)); no notarization or publication.")
    _ = try context.runner.run(["/bin/bash", context.root.appendingPathComponent("scripts/build-app.sh").path],
                               environment: environment, sensitive: false)
    let info = try localAppInfo(app)
    try verifySigningConfiguration(info, version: version, build: build, channel: "beta", environment: environment)
    try verifySigningSignature(app, context: context, environment: environment)
    let stage = try signingDirectory(parent: applications, prefix: ".talkless-local-install-")
    defer {
        // Successful installs retain no backup. Preserve a stranded original only if rollback itself failed.
        if !signingPathExists(stage.appendingPathComponent("Previous-Talkless.app")) {
            try? FileManager.default.removeItem(at: stage)
        }
    }
    let stagedApp = stage.appendingPathComponent("Talkless.app")
    _ = try context.runner.run(["ditto", app.path, stagedApp.path], environment: environment, sensitive: false)
    _ = try localAppInfo(stagedApp)
    try verifySigningSignature(stagedApp, context: context, environment: environment)
    try replaceLocalApp(stagedApp: stagedApp, target: target, original: original, context: context, environment: environment)
    try FileManager.default.removeItem(at: stage)
    print("Installed \(target.path) with the release Developer ID. No permissions or app data were reset.\n"
          + "This local build is not notarized. Launch /Applications/Talkless.app, not dist/Talkless.app.")
}
