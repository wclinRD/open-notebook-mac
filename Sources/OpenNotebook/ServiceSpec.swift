import Foundation

public struct ServiceSpec: Sendable {
    public let name: String
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL?
    public var environment: [String: String]
    public let healthCheckURL: URL
    public let readyTimeoutSeconds: TimeInterval

    public init(
        name: String,
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL?,
        environment: [String: String] = [:],
        healthCheckURL: URL,
        readyTimeoutSeconds: TimeInterval
    ) {
        self.name = name
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
        self.healthCheckURL = healthCheckURL
        self.readyTimeoutSeconds = readyTimeoutSeconds
    }
}

public enum ServiceName: String, Sendable {
    case surrealDB = "SurrealDB"
    case fastAPI = "FastAPI"
    case nextJS = "Next.js"
}

public extension ServiceSpec {
    /// - Parameters:
    ///   - resourcesURL: Read-only code inside the .app bundle.
    ///   - dataRoot: Writable per-user state, see `DataDirectory`.
    static func buildAll(from resourcesURL: URL, dataRoot: URL) -> [ServiceSpec] {
        // Read the password from the same .env the API will use, so the two cannot
        // drift apart and leave the API locked out of its own database.
        let dataEnv = parseEnvFile(at: dataRoot.appending(path: ".env"))
        let surrealPassword = dataEnv["SURREAL_PASSWORD"] ?? "root"

        let surrealDB = ServiceSpec(
            name: ServiceName.surrealDB.rawValue,
            executableURL: resourcesURL.appending(path: "surreal/surreal"),
            arguments: [
                "start",
                "--log", "info",
                "--user", dataEnv["SURREAL_USER"] ?? "root",
                "--pass", surrealPassword,
                "rocksdb:\(dataRoot.appending(path: "surreal_data/open_notebook.db").path)"
            ],
            workingDirectoryURL: dataRoot,
            environment: [:],
            healthCheckURL: URL(string: "http://127.0.0.1:8000/health")!,
            readyTimeoutSeconds: 60
        )

        // The Python packages ship in the bundle, but the process runs from the data
        // root because the API writes uploads to `data/uploads` relative to its own
        // working directory. PYTHONPATH is what bridges the two.
        let backendSource = resourcesURL.appending(path: "backend", directoryHint: .isDirectory)
        var fastAPIEnv = dataEnv
        fastAPIEnv["PYTHONPATH"] = backendSource.path
        fastAPIEnv["PYTHONDONTWRITEBYTECODE"] = "1"
        // ai_prompter otherwise looks for prompt templates under the working
        // directory, which is now the data root rather than the code root.
        fastAPIEnv["PROMPTS_PATH"] = backendSource.appending(path: "prompts").path

        let fastAPI = ServiceSpec(
            name: ServiceName.fastAPI.rawValue,
            executableURL: backendSource.appending(path: ".venv/bin/python"),
            arguments: ["\(backendSource.path)/run_api.py"],
            workingDirectoryURL: dataRoot,
            environment: fastAPIEnv,
            healthCheckURL: URL(string: "http://127.0.0.1:5055/health")!,
            readyTimeoutSeconds: 60
        )

        let webDir = resourcesURL.appending(path: "web", directoryHint: .isDirectory)
        let nextJS = ServiceSpec(
            name: ServiceName.nextJS.rawValue,
            executableURL: resourcesURL.appending(path: "node/bin/node"),
            arguments: ["server.js"],
            workingDirectoryURL: webDir,
            environment: ["PORT": "8502", "HOSTNAME": "127.0.0.1"],
            healthCheckURL: URL(string: "http://127.0.0.1:8502/api/notebooks")!,
            readyTimeoutSeconds: 90
        )

        return [surrealDB, fastAPI, nextJS]
    }
}

public func parseEnvFile(at url: URL) -> [String: String] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return [:]
    }

    do {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var env: [String: String] = [:]
        let lines = contents.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            if !key.isEmpty {
                env[key] = value
            }
        }

        return env
    } catch {
        return [:]
    }
}
