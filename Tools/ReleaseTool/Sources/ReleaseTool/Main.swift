import Foundation
import Dispatch
import Darwin

@main
struct ReleaseTool {
    static func main() {
        let cancellation = CancellationState()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { cancellation.cancel() }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            let root: URL
            if let index = arguments.firstIndex(of: "--root"), arguments.indices.contains(index + 1) {
                root = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
                arguments.removeSubrange(index...(index + 1))
            } else {
                root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }
            let environment = ProcessInfo.processInfo.environment
            var context = ToolContext(root: root, environment: environment,
                runner: ProcessRunner(directory: root, cancellation: cancellation))
            context.cancellation = cancellation
            guard let command = arguments.first else { throw ToolError(usage) }
            let args = Array(arguments.dropFirst())
            switch command {
            case "check-repository":
                guard args.isEmpty else { throw ToolError(usage) }
                try checkRepository(context: context)
            case "version":
                var ref = environment["GITHUB_REF"] ?? ""
                var build: String?
                var index = 0
                while index < args.count {
                    guard index + 1 < args.count else { throw ToolError(usage) }
                    switch args[index] {
                    case "--ref": ref = args[index + 1]
                    case "--build-number": build = args[index + 1]
                    default: throw ToolError(usage)
                    }
                    index += 2
                }
                let values = try calendarVersion(ref: ref, buildOverride: build)
                let output = ["VERSION", "BUILD_NUMBER", "RELEASE_CHANNEL", "RELEASE_TAG"].map { "\($0)=\(values[$0]!)\n" }.joined()
                print(output, terminator: "")
                if let path = environment["GITHUB_ENV"] {
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(output.utf8))
                }
            case "configure-bundle":
                guard args.count == 1 else { throw ToolError(usage) }
                try configureBundle(path: URL(fileURLWithPath: args[0]), context: context)
            case "patch-resources":
                guard args.count == 1 else { throw ToolError(usage) }
                try patchResources(in: URL(fileURLWithPath: args[0]))
            case "release":
                guard args.count == 2 else { throw ToolError(usage) }
                try release(context: context, version: args[0], build: args[1])
            case "local-install":
                guard args.isEmpty || args == ["--no-updater"] else { throw ToolError(usage) }
                try localInstall(context: context, noUpdater: args.contains("--no-updater"))
            case "publish":
                guard args.count == 1 || (args.count == 2 && args[1] == "--publish") else { throw ToolError(usage) }
                try publish(context: context, directory: URL(fileURLWithPath: args[0]), publishPublic: args.contains("--publish"))
            case "--help", "help": print(usage)
            default: throw ToolError(usage)
            }
        } catch {
            FileHandle.standardError.write(Data(("ReleaseTool: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    static let usage = """
    ReleaseTool [--root PATH] COMMAND
      check-repository
      version [--ref REF] [--build-number NUMBER]
      configure-bundle PLIST
      patch-resources BUILD_DIRECTORY
      release VERSION BUILD_NUMBER
      local-install [--no-updater]
      publish ARTIFACT_DIRECTORY [--publish]
    """
}
