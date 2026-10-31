import Foundation

func prepareAppExecutable(_ executable: URL, context: ToolContext) throws {
    let listing = try context.runner.run(["otool", "-l", executable.path], environment: context.environment, sensitive: false)
    var nextPath = false
    for line in listing.components(separatedBy: .newlines) {
        let value = line.trimmingCharacters(in: .whitespaces)
        if value == "cmd LC_RPATH" { nextPath = true; continue }
        if nextPath, value.hasPrefix("path "), let end = value.range(of: " (offset ") {
            let path = String(value[value.index(value.startIndex, offsetBy: 5)..<end.lowerBound])
            nextPath = false
            // SwiftPM derives a Swift compatibility runtime rpath from SWIFT_EXEC.
            // The compiler adapter is temporary; no build-machine search paths ship.
            if path.hasPrefix("/"), path != "/usr/lib/swift" {
                _ = try context.runner.run(["install_name_tool", "-delete_rpath", path, executable.path], environment: context.environment, sensitive: false)
            }
        }
    }
    // Drop the linker's OSO/AST debug map paths, retaining normal symbol names.
    _ = try context.runner.run(["strip", "-S", executable.path], environment: context.environment, sensitive: false)
    try verifyExecutablePrivacy(executable, forbiddenPaths: [context.root.path, context.environment["HOME"] ?? ""])
}

func verifyRelocatedBundle(app: URL, deniedPaths: [String], context: ToolContext) throws {
    // The release caller retains its original credential-bearing context after
    // signing. Diagnostics need only normal process paths and locale, not tokens.
    let allowedEnvironment = Set(["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"])
    let environment = context.environment.filter { allowedEnvironment.contains($0.key) }
    try verifyResourcePackaging(app: app)
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent("talkless-relocated-" + UUID().uuidString)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temporary) }
    let relocated = temporary.appendingPathComponent("Talkless.app")
    _ = try context.runner.run(["ditto", app.path, relocated.path], environment: environment, sensitive: false)
    _ = try context.runner.run(["codesign", "--verify", "--deep", "--strict", relocated.path], environment: environment, sensitive: false)
    let paths = Set((deniedPaths + [context.root.path]).flatMap { path in
        [URL(fileURLWithPath: path).standardizedFileURL.path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
    })
    guard !paths.isEmpty, paths.allSatisfy({ $0 != "/" && !$0.isEmpty }) else {
        throw ToolError("Relocated validation requires specific build directories to deny.")
    }
    let denials = try paths.sorted().map { path -> String in
        let literal = String(decoding: try JSONEncoder().encode(path), as: UTF8.self)
        return "(subpath \(literal))"
    }.joined(separator: " ")
    let profile = "(version 1)(allow default)(deny network*)(deny file-read* \(denials))"
    let output = try context.runner.run(["/usr/bin/sandbox-exec", "-p", profile,
                                         relocated.appendingPathComponent("Contents/MacOS/Talkless").path, "--verify-bundle"],
                                        environment: environment, sensitive: false, timeout: 30)
    guard let report = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
          report["status"] as? String == "ok", report["dependencyProbe"] as? String == "ok",
          let localization = report["localizationBundlePath"] as? String,
          let bundles = report["resourceBundlePaths"] as? [String: String],
          Set(requiredResourceBundleNames).isSubset(of: Set(bundles.keys)) else {
        throw ToolError("Relocated application resource diagnostic did not pass.")
    }
    let resources = relocated.appendingPathComponent("Contents/Resources").resolvingSymlinksInPath().path + "/"
    guard ([localization] + Array(bundles.values)).allSatisfy({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(resources) }) else {
        throw ToolError("Relocated application loaded resources from outside its bundle.")
    }
    print("Verified relocated signed bundle with build-directory reads and network denied.")
}
