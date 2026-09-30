import Foundation

public protocol HealthProbeable: Sendable {
    func probe(url: URL, timeoutSeconds: TimeInterval) async -> Bool
}

public struct DefaultHealthProbe: HealthProbeable {
    public init() {}

    public func probe(url: URL, timeoutSeconds: TimeInterval) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds

        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }
}
