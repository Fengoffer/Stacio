import AppKit

@MainActor
public enum StacioApplication {
    private static var delegate: AppDelegate?

    static var retainedDelegate: AppDelegate? {
        delegate
    }

    @discardableResult
    static func installDelegate(on app: NSApplication) -> AppDelegate {
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        return delegate
    }

    static func releaseRetainedDelegate() {
        delegate = nil
    }

    static func configureStateRestorationDefaults(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            "ApplePersistenceIgnoreStateQuietly": true,
            "ApplePersistenceIgnoreState": true
        ])
    }

    public static func run() {
        configureStateRestorationDefaults()
        let app = NSApplication.shared
        installDelegate(on: app)
        app.setActivationPolicy(.regular)
        app.run()
    }
}
