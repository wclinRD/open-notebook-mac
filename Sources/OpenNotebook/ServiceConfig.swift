import Foundation

public struct ServiceStatus: Sendable {
    public let name: String
    public var isRunning: Bool
    public var isReused: Bool
    public var errorMessage: String?

    public init(name: String, isRunning: Bool = false, isReused: Bool = false, errorMessage: String? = nil) {
        self.name = name
        self.isRunning = isRunning
        self.isReused = isReused
        self.errorMessage = errorMessage
    }
}
