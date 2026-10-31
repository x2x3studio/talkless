import Foundation
import Darwin

let resourceBundleManifestName = "SwiftPMResourceBundles.json"
let requiredResourceBundleNames = ["Talkless_Talkless.bundle", "swift-crypto_Crypto.bundle", "swift-transformers_Hub.bundle"]

/// SwiftPM's native accessor is for command-line products, not Contents-style apps.
/// Substitute an owned input at compiler invocation, never edit DerivedSources:
/// SwiftPM can regenerate those files between planning and compilation.
func appResourceAccessor(_ source: String) throws -> String {
    let pattern = #"let mainPath = (?:Bundle\.main\.bundleURL|\(Bundle\.main\.resourceURL \?\? Bundle\.main\.bundleURL\))\.appendingPathComponent\("([^"/]+\.bundle)"\)\.path"#
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..., in: source)
    guard let match = regex.firstMatch(in: source, range: range),
          let nameRange = Range(match.range(at: 1), in: source),
          source.contains("static nonisolated let module: Bundle"),
          source.contains("let buildPath ="), source.contains("Bundle(path: buildPath)") else {
        throw ToolError("Unsupported SwiftPM resource accessor; review the compiler adapter for this toolchain.")
    }
    let name = String(source[nameRange])
    guard name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0) }) else {
        throw ToolError("Invalid SwiftPM resource bundle name.")
    }
    return """
    import Foundation
    extension Foundation.Bundle {
        static nonisolated let module: Bundle = {
            // Both locations are inside the running product, never the build machine.
            for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
                if let bundle = Bundle(url: base.appendingPathComponent("\(name)")) {
                    return bundle
                }
            }
            Swift.fatalError("Missing packaged resource bundle: \(name)")
        }()
    }
    """
}

/// Swift driver response files use shell-style quotes/backslash escaping, not JSON.
func compilerResponseArguments(_ contents: String) throws -> [String] {
    var arguments: [String] = [], word = ""
    var quote: Character?, escaped = false, started = false
    for character in contents {
        if escaped { word.append(character); escaped = false; started = true; continue }
        if character == "\\", quote != "'" { escaped = true; started = true; continue }
        if let current = quote {
            if character == current { quote = nil } else { word.append(character) }
            continue
        }
        if character == "\"" || character == "'" { quote = character; started = true }
        else if character.isWhitespace {
            if started { arguments.append(word); word = ""; started = false }
        } else { word.append(character); started = true }
    }
    guard quote == nil, !escaped else { throw ToolError("Malformed Swift compiler response file.") }
    if started { arguments.append(word) }
    return arguments
}

func compilerInputArguments(_ arguments: [String], directory: URL, depth: Int = 0) throws -> [String] {
    guard depth < 16 else { throw ToolError("Recursive Swift compiler response files.") }
    var expanded: [String] = []
    for argument in arguments {
        if argument.hasPrefix("@"), !["@loader_path", "@executable_path", "@rpath"].contains(where: { argument == $0 || argument.hasPrefix($0 + "/") }) {
            let path = URL(fileURLWithPath: String(argument.dropFirst()), relativeTo: directory)
            let nested = try compilerResponseArguments(String(contentsOf: path, encoding: .utf8))
            expanded += try compilerInputArguments(nested, directory: directory, depth: depth + 1)
        } else { expanded.append(argument) }
    }
    var result: [String] = [], index = 0
    while index < expanded.count {
        if expanded[index] == "-filelist" {
            guard expanded.indices.contains(index + 1) else { throw ToolError("Missing compiler file list.") }
            let file = URL(fileURLWithPath: expanded[index + 1], relativeTo: directory)
            result += try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
            index += 2
        } else { result.append(expanded[index]); index += 1 }
    }
    return result
}

func resourceCompilerArguments(_ arguments: [String], directory: URL, inputDirectory: URL) throws -> [String] {
    let inputs = try compilerInputArguments(arguments, directory: directory)
    let paths = Set(inputs.filter { $0.hasSuffix("/resource_bundle_accessor.swift") || $0 == "resource_bundle_accessor.swift" })
    guard !paths.isEmpty else { return arguments }
    let invocation = inputDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: invocation, withIntermediateDirectories: true)
    var replacements: [String: String] = [:]
    for (index, path) in paths.sorted().enumerated() {
        let original = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        let replacement = invocation.appendingPathComponent("accessor-\(index).swift")
        let source = try String(contentsOf: original, encoding: .utf8)
        try appResourceAccessor(source).write(to: replacement, atomically: true, encoding: .utf8)
        replacements[path] = replacement.path
        replacements[original.path] = replacement.path
    }
    var adapted = inputs.map { replacements[$0] ?? $0 }
    // Keep SwiftPM's declared object/dependency outputs while changing input keys.
    for index in adapted.indices where adapted[index] == "-output-file-map" {
        guard adapted.indices.contains(index + 1) else { throw ToolError("Missing compiler output file map.") }
        let mapURL = URL(fileURLWithPath: adapted[index + 1], relativeTo: directory)
        guard let original = try JSONSerialization.jsonObject(with: Data(contentsOf: mapURL)) as? [String: Any] else {
            throw ToolError("Invalid compiler output file map.")
        }
        var updated: [String: Any] = [:]
        for (input, outputs) in original { updated[replacements[input] ?? input] = outputs }
        let output = invocation.appendingPathComponent("output-file-map.json")
        try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]).write(to: output)
        adapted[index + 1] = output.path
    }
    return adapted
}

func runResourceCompiler(arguments: [String], environment: [String: String]) throws -> Never {
    guard let compiler = environment["TALKLESS_REAL_SWIFTC"], compiler.hasPrefix("/"),
          let ownedInputs = environment["TALKLESS_RESOURCE_INPUTS"] else {
        throw ToolError("The app compiler adapter requires TALKLESS_REAL_SWIFTC and TALKLESS_RESOURCE_INPUTS.")
    }
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let adapted = try resourceCompilerArguments(arguments, directory: directory, inputDirectory: URL(fileURLWithPath: ownedInputs))
    let argv = ([compiler] + adapted).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    _ = argv.withUnsafeBufferPointer { execv(compiler, $0.baseAddress!) }
    throw ToolError("Unable to execute the Swift compiler (errno \(errno)).")
}

func packageResources(from directory: URL, app: URL) throws {
    let fm = FileManager.default
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    let bundles = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        .filter { $0.pathExtension == "bundle" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let names = bundles.map(\.lastPathComponent)
    guard Set(requiredResourceBundleNames).isSubset(of: Set(names)) else {
        throw ToolError("Missing required SwiftPM resource bundles in the build output.")
    }
    for source in bundles {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ToolError("SwiftPM resource bundles must be real directories: \(source.lastPathComponent)")
        }
        let destination = resources.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }
    try JSONEncoder().encode(names).write(to: resources.appendingPathComponent(resourceBundleManifestName), options: .atomic)
    try verifyResourcePackaging(app: app)
}

func verifyResourcePackaging(app: URL) throws {
    let fm = FileManager.default
    let root = app.resolvingSymlinksInPath().standardizedFileURL
    let resources = root.appendingPathComponent("Contents/Resources")
    let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: resources.appendingPathComponent(resourceBundleManifestName)))
    guard Set(names).count == names.count, Set(requiredResourceBundleNames).isSubset(of: Set(names)) else {
        throw ToolError("Invalid or incomplete SwiftPM resource manifest.")
    }
    let actual = try fm.contentsOfDirectory(atPath: resources.path).filter { $0.hasSuffix(".bundle") }
    guard Set(actual) == Set(names) else { throw ToolError("SwiftPM resource manifest does not match packaged bundles.") }
    for name in names {
        guard name.hasSuffix(".bundle"), !name.contains("/"), name != ".bundle" else {
            throw ToolError("Invalid resource manifest entry.")
        }
        let bundle = resources.appendingPathComponent(name)
        let values = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, Bundle(url: bundle) != nil else {
            throw ToolError("Invalid packaged resource bundle: \(name)")
        }
    }
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
        throw ToolError("Cannot enumerate application bundle.")
    }
    for case let file as URL in enumerator {
        if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            let target = try fm.destinationOfSymbolicLink(atPath: file.path)
            guard !target.hasPrefix("/"), file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                  fm.fileExists(atPath: file.path) else {
                throw ToolError("Application contains an external or broken symlink: \(file.lastPathComponent)")
            }
        }
    }
}

func verifyExecutablePrivacy(_ executable: URL, forbiddenPaths: [String]) throws {
    let data = try Data(contentsOf: executable, options: .mappedIfSafe)
    for path in Set(["/Users/", "/home/"] + forbiddenPaths).filter({ !$0.isEmpty && $0 != "/" }) {
        guard data.range(of: Data(path.utf8)) == nil else {
            // Do not copy the private path into CI output.
            throw ToolError("The application executable contains a build-machine path; check compiler prefix maps.")
        }
    }
}
