import Foundation

/// Keep source, tests and documentation English; translations belong only in app catalogs.
func isLocalizationResource(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    return components.count == 5
        && Array(components.prefix(3)) == ["Sources", "Talkless", "Resources"]
        && ["en.lproj", "zh-Hans.lproj"].contains(components[3])
        && ["Localizable.strings", "InfoPlist.strings"].contains(components[4])
}

func checkRepository(context: ToolContext) throws {
    let names = try context.run(["git", "ls-files", "-z"]).split(separator: "\0").map(String.init)
    let forbidden = Set(["safetensors", "gguf", "ggml", "onnx", "wav", "aiff", "pcm", "metallib", "air", "pyc", "log", "stdout", "stderr", "jsonl", "p12", "pem", "key"])
    let directories = Set([".build", "dist", "Vendor", "__pycache__", ".venv", "downloads", "xcuserdata"])
    let key = try NSRegularExpression(pattern: "-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")
    let credential = try NSRegularExpression(pattern: #"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-[A-Za-z0-9_-]{32,}|AKIA[A-Z0-9]{16})\b"#)
    let home = try NSRegularExpression(pattern: #"/(?:Users|home)/[A-Za-z0-9._-]+/"#)
    var errors: [String] = []
    for name in names {
        let url = context.root.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            errors.append("\(name): tracked symlink needs explicit review"); continue
        }
        if forbidden.contains(url.pathExtension.lowercased()) || !directories.isDisjoint(with: name.split(separator: "/").map(String.init)) {
            errors.append("\(name): generated, downloaded or sensitive artifact")
        }
        if url.lastPathComponent == ".env" || (url.lastPathComponent.hasPrefix(".env.") && url.lastPathComponent != ".env.example") {
            errors.append("\(name): local environment file")
        }
        if (attributes[.size] as? NSNumber)?.intValue ?? 0 > 2 * 1024 * 1024 {
            errors.append("\(name): source file exceeds 2 MiB")
        }
        let data = try Data(contentsOf: url)
        if ["Resources/AppIcon.png", "Resources/AppIcon.icns"].contains(name) {
            let signature: [UInt8] = url.pathExtension == "png" ? [137,80,78,71,13,10,26,10] : [105,99,110,115]
            if !data.starts(with: signature) { errors.append("\(name): invalid icon format") }
            continue
        }
        guard let text = String(data: data, encoding: .utf8) else { errors.append("\(name): binary source needs review"); continue }
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if !isLocalizationResource(name), name != "CHANGELOG.zh-Hans.md", line.unicodeScalars.contains(where: { scalar in
                [0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF].contains { $0.contains(Int(scalar.value)) }
            }) { errors.append("\(name):\(index + 1): literal Han text; use English or escaped test data") }
            if key.firstMatch(in: line, range: range) != nil || credential.firstMatch(in: line, range: range) != nil {
                errors.append("\(name):\(index + 1): possible credential")
            }
            if home.firstMatch(in: line, range: range) != nil { errors.append("\(name):\(index + 1): machine-specific home path") }
        }
    }
    guard errors.isEmpty else { throw ToolError(errors.joined(separator: "\n")) }
    print("Repository hygiene passed for \(names.count) tracked files.")
}
