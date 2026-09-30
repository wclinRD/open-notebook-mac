import Foundation

public final class ManagedService: @unchecked Sendable {
    private let config: ServiceSpec
    private let logQueue = DispatchQueue(label: "com.opennotebook.logqueue")
    private var process: Process?
    private var spawnedFlag: Bool = false
    private var cachedLogFileURL: URL?

    public init(config: ServiceSpec) {
        self.config = config
    }

    public var name: String { config.name }
    public var isRunning: Bool { process != nil && process?.isRunning == true }
    public var isSpawned: Bool { spawnedFlag }

    /// Setting `Process.environment` replaces the child's environment outright, so
    /// the spec's keys have to be layered onto the launcher's rather than used
    /// alone. Without the inherited values these children start with no `PATH`,
    /// `HOME` or `TMPDIR`, and both Python and SurrealDB fail on startup.
    func effectiveEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        base.merging(config.environment) { _, specValue in specValue }
    }

    private func resolveLogFileURL() throws -> URL {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/OpenNotebook")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appending(path: "\(config.name).log")
        return url
    }

    public func start() throws {
        guard !isRunning else { return }

        let logURL = try resolveLogFileURL()
        self.cachedLogFileURL = logURL

        let process = Process()
        process.executableURL = config.executableURL
        process.arguments = config.arguments
        if let cwd = config.workingDirectoryURL {
            process.currentDirectoryURL = cwd
        }
        process.environment = effectiveEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw ServiceError.spawnFailed(config.name, error)
        }

        self.process = process
        spawnedFlag = true

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                self.writeLog(data)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                self.writeLog(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.process = nil
        }
    }

    private func writeLog(_ data: Data) {
        logQueue.sync {
            guard let url = self.cachedLogFileURL else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { handle.closeFile() }
                    handle.seekToEndOfFile()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url)
                }
            } catch {}
        }
    }

    public func terminate() async throws {
        guard isSpawned else { return }
        guard let proc = process, proc.isRunning else { return }

        proc.terminate()

        // SIGTERM is advisory. SurrealDB and the Next.js server both keep worker
        // children alive and can ignore it, which would leave orphaned processes
        // holding the database lock after the app quits.
        let deadline = DispatchTime.now() + DispatchTimeInterval.seconds(5)
        while proc.isRunning && DispatchTime.now() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }

        self.process = nil
        spawnedFlag = false
    }

    public func cleanup() {
        process?.terminate()
        process = nil
        spawnedFlag = false
    }
}

public enum ServiceError: Error, LocalizedError {
    case spawnFailed(String, Error)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let name, let error):
            return "Failed to spawn \(name): \(error.localizedDescription)"
        }
    }
}
