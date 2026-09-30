import XCTest
@testable import OpenNotebook

final class ServiceSpecTests: XCTestCase {
    private func makeSandbox() throws -> (resources: URL, data: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "on-spec-\(UUID().uuidString)", directoryHint: .isDirectory)
        let resources = tmp.appending(path: "resources", directoryHint: .isDirectory)
        let data = tmp.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        return (resources, data)
    }

    func testBuildAllProducesThreeServicesWithCorrectProbes() throws {
        let (resources, data) = try makeSandbox()
        let specs = ServiceSpec.buildAll(from: resources, dataRoot: data)

        XCTAssertEqual(specs.count, 3)

        let surrealDB = specs.first { $0.name == "SurrealDB" }
        XCTAssertEqual(surrealDB?.healthCheckURL.absoluteString, "http://127.0.0.1:8000/health")
        XCTAssertEqual(surrealDB?.readyTimeoutSeconds, 60)
        XCTAssertEqual(surrealDB?.executableURL.lastPathComponent, "surreal")

        let fastAPI = specs.first { $0.name == "FastAPI" }
        XCTAssertEqual(fastAPI?.healthCheckURL.absoluteString, "http://127.0.0.1:5055/health")
        XCTAssertEqual(fastAPI?.executableURL.lastPathComponent, "python")

        let nextJS = specs.first { $0.name == "Next.js" }
        XCTAssertEqual(nextJS?.healthCheckURL.absoluteString, "http://127.0.0.1:8502/api/notebooks")
        XCTAssertEqual(nextJS?.readyTimeoutSeconds, 90)
        XCTAssertEqual(nextJS?.executableURL.lastPathComponent, "node")
    }

    /// The web service health check must hit the proxied API, never `/` — a plain
    /// GET on `/` answers 307 and is not a readiness signal.
    func testWebProbeUsesProxiedAPIEndpoint() {
        let specs = ServiceSpec.buildAll(
            from: URL(fileURLWithPath: "/tmp/fake-resources"),
            dataRoot: URL(fileURLWithPath: "/tmp/fake-data")
        )
        let nextJS = specs.first { $0.name == "Next.js" }

        XCTAssertEqual(nextJS?.healthCheckURL.path, "/api/notebooks")
        XCTAssertEqual(nextJS?.healthCheckURL.host, "127.0.0.1")
    }

    /// The store must live under the data root so replacing the bundle keeps notes.
    func testSurrealStorePathIsUnderDataRootNotBundle() throws {
        let (resources, data) = try makeSandbox()
        let specs = ServiceSpec.buildAll(from: resources, dataRoot: data)
        let surrealDB = specs.first { $0.name == "SurrealDB" }

        let storeArg = try XCTUnwrap(surrealDB?.arguments.last)
        XCTAssertTrue(storeArg.hasPrefix("rocksdb:"), storeArg)
        let path = String(storeArg.dropFirst("rocksdb:".count))
        XCTAssertTrue(path.hasPrefix(data.path), "store \(path) escaped data root \(data.path)")
        XCTAssertFalse(path.hasPrefix(resources.path), "store must not live inside the bundle")
    }

    /// The server and the API must agree on the password, or the API gets locked
    /// out of its own database.
    func testSurrealPasswordMatchesEnvFile() throws {
        let (resources, data) = try makeSandbox()
        try "SURREAL_PASSWORD=from_env_file\n".write(
            to: data.appending(path: ".env"), atomically: true, encoding: .utf8
        )

        let specs = ServiceSpec.buildAll(from: resources, dataRoot: data)
        let surrealDB = try XCTUnwrap(specs.first { $0.name == "SurrealDB" })

        XCTAssertTrue(surrealDB.arguments.contains("--pass=from_env_file"), "\(surrealDB.arguments)")
    }

    /// A password starting with a dash must stay attached to --pass=; as a
    /// separate token SurrealDB would read it as a flag and refuse to start.
    func testDashLeadingPasswordStaysAttachedToItsFlag() throws {
        let (resources, data) = try makeSandbox()
        try "SURREAL_PASSWORD=-nSecret\n".write(
            to: data.appending(path: ".env"), atomically: true, encoding: .utf8
        )

        let specs = ServiceSpec.buildAll(from: resources, dataRoot: data)
        let surrealDB = try XCTUnwrap(specs.first { $0.name == "SurrealDB" })

        XCTAssertTrue(surrealDB.arguments.contains("--pass=-nSecret"), "\(surrealDB.arguments)")
        XCTAssertFalse(surrealDB.arguments.contains("-nSecret"), "must not appear as a bare token")
    }

    /// Regression: the spec used to fabricate an empty encryption key when the
    /// .env lacked one, which silently disabled credential encryption.
    func testMissingEncryptionKeyIsAbsentNotEmptied() throws {
        let (resources, data) = try makeSandbox()
        try "SURREAL_PASSWORD=abc\n".write(
            to: data.appending(path: ".env"), atomically: true, encoding: .utf8
        )

        let specs = ServiceSpec.buildAll(from: resources, dataRoot: data)
        let fastAPI = try XCTUnwrap(specs.first { $0.name == "FastAPI" })

        XCTAssertNil(
            fastAPI.environment["OPEN_NOTEBOOK_ENCRYPTION_KEY"],
            "must not invent an empty encryption key"
        )
    }

    func testFastAPIRunsFromDataRootWithBundledSources() throws {
        let (resources, data) = try makeSandbox()
        let specs = ServiceSpec.buildAll(from: resources, dataRoot: data)
        let fastAPI = try XCTUnwrap(specs.first { $0.name == "FastAPI" })

        XCTAssertEqual(fastAPI.workingDirectoryURL?.standardizedFileURL, data.standardizedFileURL)
        XCTAssertEqual(
            fastAPI.environment["PYTHONPATH"],
            resources.appending(path: "backend").path
        )
        // ai_prompter resolves prompt templates from the working directory unless
        // PROMPTS_PATH points at the bundled prompts.
        XCTAssertEqual(
            fastAPI.environment["PROMPTS_PATH"],
            resources.appending(path: "backend/prompts").path
        )
        XCTAssertTrue(fastAPI.arguments[0].hasSuffix("run_api.py"))
    }
}
