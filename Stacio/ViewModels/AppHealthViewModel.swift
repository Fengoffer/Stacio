import Foundation

public final class AppHealthViewModel {
    public private(set) var appName: String = ""
    public private(set) var isHealthy: Bool = false

    public init() {}

    public func refresh() throws {
        let health = try CoreBridge.health()
        appName = health.app
        isHealthy = health.ok
    }
}

