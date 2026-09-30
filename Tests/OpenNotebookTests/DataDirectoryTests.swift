import XCTest
@testable import OpenNotebook

final class DataDirectoryTests: XCTestCase {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "on-data-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPrepareCreatesRequiredSubdirectories() throws {
        let root = try makeTempRoot()
        try DataDirectory.prepare(root: root)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: root.appending(path: "surreal_data").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appending(path: "data/uploads").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appending(path: ".env").path))
    }

    /// The encryption key protects stored provider credentials. Regenerating it on
    /// every launch would make every previously saved credential undecryptable.
    func testExistingEnvIsLeftByteForByteUnchanged() throws {
        let root = try makeTempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sentinel = "OPEN_NOTEBOOK_ENCRYPTION_KEY=sentinel-do-not-touch\nSURREAL_PASSWORD=keepme\n"
        let envURL = root.appending(path: ".env")
        try sentinel.write(to: envURL, atomically: true, encoding: .utf8)

        try DataDirectory.prepare(root: root)

        XCTAssertEqual(try String(contentsOf: envURL, encoding: .utf8), sentinel)
    }

    func testPrepareIsIdempotentAndKeepsTheOriginalKey() throws {
        let root = try makeTempRoot()
        try DataDirectory.prepare(root: root)
        let first = try String(contentsOf: root.appending(path: ".env"), encoding: .utf8)

        try DataDirectory.prepare(root: root)
        let second = try String(contentsOf: root.appending(path: ".env"), encoding: .utf8)

        XCTAssertEqual(first, second)
    }

    func testGeneratedEnvCarriesEveryValueTheBackendRequires() throws {
        let root = try makeTempRoot()
        try DataDirectory.prepare(root: root)
        let env = parseEnvFile(at: root.appending(path: ".env"))

        XCTAssertEqual(env["SURREAL_URL"], "ws://localhost:8000/rpc")
        XCTAssertEqual(env["SURREAL_USER"], "root")
        XCTAssertEqual(env["SURREAL_NAMESPACE"], "open_notebook")
        XCTAssertEqual(env["SURREAL_DATABASE"], "open_notebook")
        // localhost traffic must bypass any corporate HTTP proxy, otherwise the
        // SurrealDB websocket tunnels and the worker dies with HTTP 403.
        XCTAssertEqual(env["NO_PROXY"], "localhost,127.0.0.1")

        let key = try XCTUnwrap(env["OPEN_NOTEBOOK_ENCRYPTION_KEY"])
        XCTAssertFalse(key.isEmpty, "an empty key disables credential encryption")
        XCTAssertGreaterThanOrEqual(key.count, 32)
    }

    func testGeneratedSecretsDifferBetweenRuns() {
        XCTAssertNotEqual(DataDirectory.token(byteCount: 32), DataDirectory.token(byteCount: 32))
    }
}

final class ManagedServiceEnvironmentTests: XCTestCase {
    private func makeSpec(environment: [String: String]) -> ServiceSpec {
        ServiceSpec(
            name: "Test",
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: [],
            workingDirectoryURL: nil,
            environment: environment,
            healthCheckURL: URL(string: "http://127.0.0.1:1/health")!,
            readyTimeoutSeconds: 1
        )
    }

    /// Regression: `Process.environment` replaces the child environment outright,
    /// so the services used to start with no PATH, HOME or TMPDIR at all.
    func testChildInheritsLauncherEnvironmentAlongsideSpecKeys() {
        let spec = makeSpec(environment: ["SURREAL_PASSWORD": "abc", "PYTHONPATH": "/bundle/backend"])
        let managed = ManagedService(config: spec)

        let effective = managed.effectiveEnvironment(base: ["PATH": "/usr/bin", "HOME": "/Users/someone"])

        XCTAssertEqual(effective["PATH"], "/usr/bin")
        XCTAssertEqual(effective["HOME"], "/Users/someone")
        XCTAssertEqual(effective["SURREAL_PASSWORD"], "abc")
        XCTAssertEqual(effective["PYTHONPATH"], "/bundle/backend")
    }

    func testSpecValuesWinOverInheritedOnes() {
        let spec = makeSpec(environment: ["HOME": "/override"])
        let managed = ManagedService(config: spec)

        let effective = managed.effectiveEnvironment(base: ["HOME": "/inherited", "PATH": "/usr/bin"])

        XCTAssertEqual(effective["HOME"], "/override")
        XCTAssertEqual(effective["PATH"], "/usr/bin")
    }

    func testEffectiveEnvironmentIsNonEmptyWithAnEmptySpec() {
        let managed = ManagedService(config: makeSpec(environment: [:]))
        let effective = managed.effectiveEnvironment(base: ["PATH": "/usr/bin"])
        XCTAssertEqual(effective, ["PATH": "/usr/bin"])
    }
}

final class EnvParsingTests: XCTestCase {
    private func makeEnvFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "on-env-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testParsesKeyValuePairsIgnoringBlanksAndComments() throws {
        let url = try makeEnvFile("""
        # a comment

        SURREAL_USER=root
        OPEN_NOTEBOOK_WORKER_MAX_TASKS=1

        # trailing comment
        NO_PROXY=localhost,127.0.0.1
        """)

        let env = parseEnvFile(at: url)

        XCTAssertEqual(env["SURREAL_USER"], "root")
        XCTAssertEqual(env["OPEN_NOTEBOOK_WORKER_MAX_TASKS"], "1")
        XCTAssertEqual(env["NO_PROXY"], "localhost,127.0.0.1")
        XCTAssertEqual(env.count, 3)
    }

    /// Base64 keys contain `=`, so splitting on the first one only is required.
    func testValueContainingEqualsSignIsPreserved() throws {
        let url = try makeEnvFile("OPEN_NOTEBOOK_ENCRYPTION_KEY=YWJjZA==\n")
        XCTAssertEqual(parseEnvFile(at: url)["OPEN_NOTEBOOK_ENCRYPTION_KEY"], "YWJjZA==")
    }

    func testMissingFileYieldsEmptyDictionaryInsteadOfCrashing() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString)/.env")
        XCTAssertEqual(parseEnvFile(at: missing), [:])
    }
}
