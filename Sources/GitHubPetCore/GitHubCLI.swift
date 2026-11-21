import Foundation

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    /// False if a descendant kept a pipe open beyond the bounded post-exit drain.
    public var outputComplete: Bool

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), outputComplete: Bool = true) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.outputComplete = outputComplete
    }

    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum CommandError: Error, Equatable {
    case launchFailed(String)
    case timedOut
    case outputLimitExceeded
    case cancelled
}

/// Runs a program with an explicit argv. Implementations must never go through a shell.
public protocol CommandRunner: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult
    func run(executable: URL, arguments: [String], budget: CommandBudget) throws -> CommandResult
}

/// Finds the `gh` executable without consulting a shell.
public struct GhLocator: Sendable {
    public static let overrideVariable = "GITHUB_PET_GH_PATH"
    public var environment: [String: String]
    public var isExecutable: @Sendable (String) -> Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.environment = environment
        self.isExecutable = isExecutable
    }

    /// Candidate paths in priority order. An explicit override is the only candidate.
    public var candidates: [String] {
        if let override = environment[Self.overrideVariable], !override.isEmpty {
            return [override]
        }
        var paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        for dir in (environment["PATH"] ?? "").split(separator: ":") where dir.hasPrefix("/") {
            let path = "\(dir)/gh"
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    public func locate() -> URL? {
        candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}
