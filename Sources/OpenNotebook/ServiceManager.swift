import Foundation
import Combine

public final class ServiceManager: ObservableObject {
    @MainActor
    public enum Phase: Sendable {
        case idle
        case starting(serviceName: String)
        case ready
        case failed(String)
    }

    @MainActor
    @Published public var phase: Phase = .idle
    @MainActor
    @Published public var services: [ServiceStatus] = []

    private let healthProbe: HealthProbeable
    private var specs: [ServiceSpec] = []
    private var managedServices: [String: ManagedService] = [:]

    /// The view tree and the app delegate must drive the *same* instance, otherwise
    /// quitting tears down a manager that never started anything.
    @MainActor
    public static let shared = ServiceManager()

    /// The bundle's resource directory, where all bundled code and runtimes live.
    @MainActor
    public static var bundledResources: URL {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    public init(healthProbe: HealthProbeable = DefaultHealthProbe()) {
        self.healthProbe = healthProbe
    }

    @MainActor
    public func startAll(from resourcesURL: URL, dataRoot: URL? = nil) async {
        phase = .starting(serviceName: "準備資料目錄")

        // Must happen before the specs are built: they read SURREAL_PASSWORD out of
        // the data-root .env, and the store must exist before SurrealDB opens it.
        let resolvedDataRoot: URL
        do {
            resolvedDataRoot = try DataDirectory.prepare(root: dataRoot)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        specs = ServiceSpec.buildAll(from: resourcesURL, dataRoot: resolvedDataRoot)
        services = specs.map { ServiceStatus(name: $0.name) }

        phase = .idle
        for spec in specs {
            let statusIndex = services.firstIndex { $0.name == spec.name } ?? 0
            services[statusIndex].isRunning = false
            services[statusIndex].isReused = false
        }

        let probeResult = await probeExistingServices()
        for (index, _) in specs.enumerated() {
            if probeResult[index] {
                services[index].isReused = true
            } else {
                services[index].isReused = false
            }
        }

        for (index, spec) in specs.enumerated() {
            if !probeResult[index] {
                do {
                    let managed = ManagedService(config: spec)
                    try managed.start()
                    managedServices[spec.name] = managed

                    let healthy = await pollUntilHealthy(spec)
                    if !healthy {
                        throw ServiceError.spawnFailed(spec.name, NSError(domain: "OpenNotebook", code: -1, userInfo: [NSLocalizedDescriptionKey: "Service did not become healthy within timeout"]))
                    }

                    services[index].isRunning = true
                } catch {
                    phase = .failed(error.localizedDescription)
                    return
                }
            } else {
                services[index].isRunning = true
            }

            phase = .starting(serviceName: spec.name)
        }

        phase = .ready
    }

    @MainActor
    private func probeExistingServices() async -> [Bool] {
        var results: [Bool] = []
        for spec in specs {
            let healthy = await healthProbe.probe(url: spec.healthCheckURL, timeoutSeconds: 1.5)
            results.append(healthy)
        }
        return results
    }

    @MainActor
    private func pollUntilHealthy(_ spec: ServiceSpec) async -> Bool {
        let deadline = DispatchTime.now() + DispatchTimeInterval.seconds(Int(spec.readyTimeoutSeconds))

        while DispatchTime.now() < deadline {
            let healthy = await healthProbe.probe(url: spec.healthCheckURL, timeoutSeconds: 1.5)
            if healthy { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return false
    }

    @MainActor
    public func stopAll() async {
        for (name, managed) in managedServices {
            do {
                try await managed.terminate()
            } catch {
                print("Failed to terminate \(name): \(error)")
            }
        }
        managedServices.removeAll()

        for index in services.indices {
            if !services[index].isReused {
                services[index].isRunning = false
            }
        }

        phase = .idle
    }

    @MainActor
    public func retry() {
        if case .failed = phase {
            Task {
                await startAll(from: Self.bundledResources)
            }
        }
    }

    /// Stops what we spawned, then starts again. Used by the Restart command; a
    /// crashed service leaves a half-open port that a plain retry would reuse.
    @MainActor
    public func restart(from resourcesURL: URL) async {
        await stopAll()
        await startAll(from: resourcesURL)
    }
}
