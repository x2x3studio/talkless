import Foundation
import Dispatch
import Darwin

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

protocol CommandRunning {
    func run(_ arguments: [String], environment: [String: String], sensitive: Bool) throws -> String
    func cleanup(_ arguments: [String], environment: [String: String])
}

extension CommandRunning {
    func cleanup(_ arguments: [String], environment: [String: String]) {
        _ = try? run(arguments, environment: environment, sensitive: true)
    }
}

final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func cancel() {
        let running = lock.withLock { cancelled = true; return process }
        if let running, running.isRunning { running.terminate() }
    }
    func check() throws {
        if lock.withLock({ cancelled }) { throw ToolError("Operation interrupted; temporary signing material is being cleaned up.") }
    }
    func launch(_ process: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw ToolError("Operation interrupted.") }
            try process.run()
            self.process = process
        }
    }
    func clear(_ process: Process) {
        lock.withLock { if self.process === process { self.process = nil } }
    }
}

final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func set(_ data: Data) { lock.withLock { bytes = data } }
    func get() -> Data { lock.withLock { bytes } }
}

struct ProcessRunner: CommandRunning {
    let directory: URL
    let cancellation: CancellationState

    func run(_ arguments: [String], environment: [String: String], sensitive: Bool) throws -> String {
        try execute(arguments, environment: environment, sensitive: sensitive, cancellable: true)
    }
    func cleanup(_ arguments: [String], environment: [String: String]) {
        _ = try? execute(arguments, environment: environment, sensitive: true, cancellable: false)
    }
    private func execute(_ arguments: [String], environment: [String: String], sensitive: Bool, cancellable: Bool) throws -> String {
        guard let command = arguments.first else { throw ToolError("Empty command") }
        let executable: URL
        if command.contains("/") {
            executable = URL(fileURLWithPath: command, relativeTo: directory).standardizedFileURL
        } else {
            guard let found = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
                .split(separator: ":")
                .map({ URL(fileURLWithPath: String($0)).appendingPathComponent(command) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw ToolError("Required command is unavailable: \(command)")
            }
            executable = found
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = directory
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let out = CapturedOutput(), err = CapturedOutput()
        let group = DispatchGroup()
        if cancellable { try cancellation.launch(process) } else { try process.run() }
        group.enter()
        DispatchQueue.global().async { out.set(output.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { err.set(errors.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        process.waitUntilExit()
        group.wait()
        if cancellable { cancellation.clear(process); try cancellation.check() }
        guard process.terminationStatus == 0 else {
            if !sensitive { FileHandle.standardError.write(err.get()) }
            throw ToolError("\(executable.lastPathComponent) failed (exit \(process.terminationStatus)); \(sensitive ? "credential output suppressed" : "operation stopped").")
        }
        guard let text = String(data: out.get(), encoding: .utf8) else { throw ToolError("Command returned invalid UTF-8") }
        return text
    }
}

struct ToolContext {
    static let signingIdentity = "Developer ID Application: Shanghai Gotehab Information Technology Co., Ltd (AXJQF2CMF2)"
    static let teamID = "AXJQF2CMF2"
    static let repository = "x2x3studio/talkless"
    let root: URL
    let environment: [String: String]
    let runner: any CommandRunning
    var cancellation: CancellationState? = nil

    func run(_ arguments: [String], environment: [String: String]? = nil, sensitive: Bool = false) throws -> String {
        var env = environment ?? self.environment
        if environment == nil { env.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN") }
        return try runner.run(arguments, environment: env, sensitive: sensitive)
    }
    func cleanupRun(_ arguments: [String], environment: [String: String]? = nil) {
        var env = environment ?? self.environment
        env.removeValue(forKey: "OP_SERVICE_ACCOUNT_TOKEN")
        runner.cleanup(arguments, environment: env)
    }
    func checkCancellation() throws { try cancellation?.check() }
    func sleep(seconds: Double) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try checkCancellation()
            Thread.sleep(forTimeInterval: min(0.2, deadline - ProcessInfo.processInfo.systemUptime))
        }
    }
}
