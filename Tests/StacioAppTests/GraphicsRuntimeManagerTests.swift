import XCTest
@testable import StacioApp

final class GraphicsRuntimeManagerTests: XCTestCase {
    func testDefaultManagerRejectsAdapterOutsideBundleAdaptersDirectory() {
        let launcher = RecordingGraphicsAdapterLauncher()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true)
        )

        XCTAssertThrowsError(
            try manager.start(
                request: GraphicsRuntimeStartRequest(
                    protocolName: "VNC",
                    adapterPath: "/usr/bin/open",
                    arguments: ["desktop.example.com:5900"],
                    host: "desktop.example.com",
                    port: 5900
                )
            )
        ) { error in
            XCTAssertEqual(error as? GraphicsRuntimeError, .adapterOutsideBundle("/usr/bin/open"))
        }
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testDefaultManagerRejectsAdapterInsideDifferentAppBundle() {
        let launcher = RecordingGraphicsAdapterLauncher()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true)
        )

        XCTAssertThrowsError(
            try manager.start(
                request: GraphicsRuntimeStartRequest(
                    protocolName: "VNC",
                    adapterPath: "/tmp/Fake.app/Contents/Adapters/vnc",
                    arguments: ["desktop.example.com:5900"],
                    host: "desktop.example.com",
                    port: 5900
                )
            )
        ) { error in
            XCTAssertEqual(error as? GraphicsRuntimeError, .adapterOutsideBundle("/tmp/Fake.app/Contents/Adapters/vnc"))
        }
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testDefaultManagerRejectsAdapterSymlinkThatEscapesBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StacioGraphicsRuntimeManagerTests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("Stacio.app", isDirectory: true)
        let adaptersURL = bundleURL.appendingPathComponent("Contents/Adapters", isDirectory: true)
        try FileManager.default.createDirectory(at: adaptersURL, withIntermediateDirectories: true)
        let symlinkURL = adaptersURL.appendingPathComponent("vnc")
        try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "/usr/bin/open")
        defer { try? FileManager.default.removeItem(at: root) }

        let launcher = RecordingGraphicsAdapterLauncher()
        let manager = DefaultGraphicsRuntimeManager(launcher: launcher, bundleURL: bundleURL)

        XCTAssertThrowsError(
            try manager.start(
                request: GraphicsRuntimeStartRequest(
                    protocolName: "VNC",
                    adapterPath: symlinkURL.path,
                    arguments: ["desktop.example.com:5900"],
                    host: "desktop.example.com",
                    port: 5900
                )
            )
        ) { error in
            XCTAssertEqual(error as? GraphicsRuntimeError, .adapterOutsideBundle(symlinkURL.path))
        }
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testDefaultManagerCreatesEmbeddedVNCSessionAndReturnsRunningStatus() throws {
        let launcher = RecordingGraphicsAdapterLauncher()
        let logStore = RecordingGraphicsRuntimeLogStore()
        let factory = RecordingVNCGraphicsSessionFactory()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            appLog: logStore,
            sessionFactory: factory
        )

        let status = try manager.start(
            request: GraphicsRuntimeStartRequest(
                protocolName: "VNC",
                adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
                arguments: ["--password", "vnc-secret", "desktop.example.com:5900"],
                host: "desktop.example.com",
                port: 5900
            )
        )

        XCTAssertTrue(status.runtimeID.hasPrefix("graphics_"))
        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(status.diagnostic, "已启动 Stacio 内置 VNC 适配器，正在建立图形连接。")
        XCTAssertEqual(status.presentation, .embeddedSurface)
        XCTAssertNotNil(status.attachment)
        // VNC 走嵌入式会话路径，不应调用 launcher
        XCTAssertTrue(launcher.launches.isEmpty)
        // 工厂应被调用一次，传入正确的参数
        XCTAssertEqual(factory.sessions.count, 1)
        let created = factory.sessions.first
        XCTAssertEqual(created?.host, "desktop.example.com")
        XCTAssertEqual(created?.port, 5900)
        XCTAssertEqual(created?.password, "vnc-secret")
        XCTAssertEqual(created?.quality, 7)
        XCTAssertEqual(created?.maxFps, 30)
        XCTAssertEqual(created?.adapterExecutablePath, "/Applications/Stacio.app/Contents/Adapters/vnc")
        XCTAssertTrue(created?.didStart ?? false)
        // 日志验证
        XCTAssertTrue(logStore.lines.contains { $0.contains("graphics.start") && $0.contains("desktop.example.com:5900") })
        XCTAssertTrue(logStore.lines.contains { $0.contains("graphics.started") && $0.contains("mode=embedded") })
        XCTAssertFalse(logStore.lines.joined(separator: "\n").contains("vnc-secret"))
    }

    func testDefaultManagerPassesEnvironmentOnlyVNCPasswordToEmbeddedSession() throws {
        let factory = RecordingVNCGraphicsSessionFactory()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: RecordingGraphicsAdapterLauncher(),
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            appLog: nil,
            sessionFactory: factory
        )

        _ = try manager.start(
            request: GraphicsRuntimeStartRequest(
                protocolName: "VNC",
                adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
                arguments: ["desktop.example.com:5900"],
                host: "desktop.example.com",
                port: 5900,
                environment: ["STACIO_VNC_PASSWORD": "environment-secret"]
            )
        )

        XCTAssertEqual(factory.sessions.first?.password, "environment-secret")
    }

    func testDefaultManagerRedactsShortFlagVNCPasswordFromFailureDiagnosticAndLogs() throws {
        let secret = "short-flag-vnc-secret"
        let logStore = RecordingGraphicsRuntimeLogStore()
        let factory = RecordingVNCGraphicsSessionFactory()
        factory.startError = GraphicsRuntimeManagerTestError(
            message: "adapter echoed \(secret)"
        )
        let manager = DefaultGraphicsRuntimeManager(
            launcher: RecordingGraphicsAdapterLauncher(),
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            appLog: logStore,
            sessionFactory: factory
        )

        let status = try manager.start(
            request: GraphicsRuntimeStartRequest(
                protocolName: "VNC",
                adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
                arguments: ["-p", secret, "desktop.example.com:5900"],
                host: "desktop.example.com",
                port: 5900
            )
        )

        XCTAssertEqual(status.status, "failed")
        XCTAssertFalse(status.diagnostic.contains(secret))
        XCTAssertFalse(logStore.lines.joined(separator: "\n").contains(secret))
    }

    func testDefaultManagerStopsEmbeddedVNCSessionOnStop() throws {
        let launcher = RecordingGraphicsAdapterLauncher()
        let factory = RecordingVNCGraphicsSessionFactory()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            sessionFactory: factory
        )

        let startStatus = try manager.start(
            request: GraphicsRuntimeStartRequest(
                protocolName: "VNC",
                adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
                arguments: ["desktop.example.com:5900"],
                host: "desktop.example.com",
                port: 5900
            )
        )
        let runtimeID = startStatus.runtimeID
        XCTAssertTrue(factory.sessions.first?.didStart ?? false)

        let stopStatus = manager.stop(runtimeID: runtimeID)
        XCTAssertEqual(stopStatus.status, "closed")
        XCTAssertTrue(factory.sessions.first?.didStop ?? false)
    }

    func testDefaultManagerPropagatesQualityAndMaxFpsToEmbeddedSession() throws {
        let launcher = RecordingGraphicsAdapterLauncher()
        let factory = RecordingVNCGraphicsSessionFactory()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            sessionFactory: factory
        )

        _ = try manager.start(
            request: GraphicsRuntimeStartRequest(
                protocolName: "VNC",
                adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
                arguments: ["--password", "secret", "--quality", "3", "--max-fps", "15", "host.example.com:5901"],
                host: "host.example.com",
                port: 5901
            )
        )

        let created = factory.sessions.first
        XCTAssertEqual(created?.quality, 3)
        XCTAssertEqual(created?.maxFps, 15)
        XCTAssertEqual(created?.host, "host.example.com")
        XCTAssertEqual(created?.port, 5901)
    }

    func testDefaultManagerCreatesEmbeddedRDPSessionAndReturnsRunningStatus() throws {
        let launcher = RecordingGraphicsAdapterLauncher()
        let logStore = RecordingGraphicsRuntimeLogStore()
        let factory = RecordingRDPGraphicsSessionFactory()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            appLog: logStore,
            rdpSessionFactory: factory
        )

        let status = try manager.start(
            request: GraphicsRuntimeStartRequest(
                protocolName: "RDP",
                adapterPath: "/Applications/Stacio.app/Contents/Adapters/rdp",
                arguments: [
                    "--host", "win.example.com",
                    "--port", "3389",
                    "--user", "Administrator",
                    "--password", "rdp-secret",
                    "--domain", "CORP",
                    "--width", "1920",
                    "--height", "1080",
                    "--quality", "5",
                    "--security", "tls",
                    "--drive", "Shared:/tmp/stacio-rdp-drive",
                    "--ignore-cert"
                ],
                host: "win.example.com",
                port: 3389
            )
        )

        XCTAssertTrue(status.runtimeID.hasPrefix("graphics_"))
        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(status.presentation, .embeddedSurface)
        XCTAssertNotNil(status.attachment)
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(factory.sessions.count, 1)
        let created = factory.sessions.first
        XCTAssertEqual(created?.options.host, "win.example.com")
        XCTAssertEqual(created?.options.port, 3389)
        XCTAssertEqual(created?.options.user, "Administrator")
        XCTAssertEqual(created?.options.password, "rdp-secret")
        XCTAssertEqual(created?.options.domain, "CORP")
        XCTAssertEqual(created?.options.width, 1920)
        XCTAssertEqual(created?.options.height, 1080)
        XCTAssertEqual(created?.options.quality, 5)
        XCTAssertEqual(created?.options.security, .tls)
        XCTAssertEqual(created?.options.drive, "Shared:/tmp/stacio-rdp-drive")
        XCTAssertTrue(created?.options.ignoreCert ?? false)
        XCTAssertTrue(created?.didStart ?? false)
        XCTAssertFalse(logStore.lines.joined(separator: "\n").contains("rdp-secret"))
    }

    func testDefaultManagerStartsEmbeddedRDPWithEmptyAdapterPath() throws {
        let launcher = RecordingGraphicsAdapterLauncher()
        let factory = RecordingRDPGraphicsSessionFactory()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            appLog: nil,
            rdpSessionFactory: factory
        )

        let status = try manager.start(
            request: GraphicsRuntimeStartRequest(
                protocolName: "RDP",
                adapterPath: "",
                arguments: [
                    "--host", "win.example.com",
                    "--port", "3389",
                    "--user", "Administrator",
                    "--password", "rdp-secret"
                ],
                host: "win.example.com",
                port: 3389
            )
        )

        XCTAssertEqual(status.status, "running")
        XCTAssertEqual(status.presentation, .embeddedSurface)
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertTrue(factory.sessions.first?.didStart ?? false)
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testDefaultManagerParsesRDPSecurityCaseInsensitively() throws {
        let factory = RecordingRDPGraphicsSessionFactory()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: RecordingGraphicsAdapterLauncher(),
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            appLog: nil,
            rdpSessionFactory: factory
        )

        _ = try manager.start(
            request: GraphicsRuntimeStartRequest(
                protocolName: "RDP",
                adapterPath: "",
                arguments: ["--security", "TLS"],
                host: "win.example.com",
                port: 3389
            )
        )

        XCTAssertEqual(factory.sessions.first?.options.security, .tls)
    }

    func testDefaultManagerRejectsUnknownRDPSecurityBeforeCreatingSession() {
        let factory = RecordingRDPGraphicsSessionFactory()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: RecordingGraphicsAdapterLauncher(),
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            appLog: nil,
            rdpSessionFactory: factory
        )

        XCTAssertThrowsError(
            try manager.start(
                request: GraphicsRuntimeStartRequest(
                    protocolName: "RDP",
                    adapterPath: "",
                    arguments: ["--security", "kerberos"],
                    host: "win.example.com",
                    port: 3389
                )
            )
        ) { error in
            XCTAssertEqual(error as? GraphicsRuntimeError, .invalidRDPSecurity("kerberos"))
        }
        XCTAssertTrue(factory.sessions.isEmpty)
    }

    func testDefaultManagerStopsEmbeddedRDPSessionOnStop() throws {
        let launcher = RecordingGraphicsAdapterLauncher()
        let factory = RecordingRDPGraphicsSessionFactory()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            rdpSessionFactory: factory
        )

        let startStatus = try manager.start(
            request: GraphicsRuntimeStartRequest(
                protocolName: "RDP",
                adapterPath: "/Applications/Stacio.app/Contents/Adapters/rdp",
                arguments: [
                    "--host", "win.example.com",
                    "--port", "3389",
                    "--user", "Admin",
                    "--password", "secret"
                ],
                host: "win.example.com",
                port: 3389
            )
        )
        let runtimeID = startStatus.runtimeID
        XCTAssertTrue(factory.sessions.first?.didStart ?? false)

        let stopStatus = manager.stop(runtimeID: runtimeID)
        XCTAssertEqual(stopStatus.status, "closed")
        XCTAssertTrue(factory.sessions.first?.didStop ?? false)
    }

    func testDefaultManagerRejectsUnsupportedGraphicsProtocolRequestsWithoutLaunchingAdapter() throws {
        let launcher = RecordingGraphicsAdapterLauncher()
        let logStore = RecordingGraphicsRuntimeLogStore()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            appLog: logStore
        )

        XCTAssertThrowsError(
            try manager.start(
                request: GraphicsRuntimeStartRequest(
                    protocolName: "X11",
                    adapterPath: "/Applications/Stacio.app/Contents/Adapters/x11",
                    arguments: ["desktop.example.com:6000"],
                    host: "desktop.example.com",
                    port: 6000
                )
            )
        ) { error in
            XCTAssertEqual(error as? GraphicsRuntimeError, .unsupportedProtocol("X11"))
        }

        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertTrue(logStore.lines.contains { $0.contains("reason=unsupported-protocol") })
        XCTAssertFalse(logStore.lines.contains { $0.contains("graphics.started") })
    }

    func testDefaultManagerRejectsUnsupportedGraphicsProtocolBeforeAdapterPathValidation() throws {
        let launcher = RecordingGraphicsAdapterLauncher()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true)
        )

        XCTAssertThrowsError(
            try manager.start(
                request: GraphicsRuntimeStartRequest(
                    protocolName: "X11",
                    adapterPath: "/usr/bin/open",
                    arguments: ["desktop.example.com:6000"],
                    host: "desktop.example.com",
                    port: 6000
                )
            )
        ) { error in
            XCTAssertEqual(error as? GraphicsRuntimeError, .unsupportedProtocol("X11"))
        }

        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testProcessGraphicsAdapterLauncherPassesEnvironmentOverridesToAdapter() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StacioGraphicsAdapterEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("capture-env.sh")
        let outputURL = root.appendingPathComponent("captured-env.txt")
        let outputPath = outputURL.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        #!/usr/bin/env bash
        printf '%s' "$STACIO_TEST_LAUNCH_ENV" > "\(outputPath)"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let launcher = ProcessGraphicsAdapterLauncher(immediateFailureProbeInterval: 0.1, appLog: nil)
        _ = try launcher.launchAdapter(
            executablePath: scriptURL.path,
            arguments: [],
            environment: ["STACIO_TEST_LAUNCH_ENV": "vnc-adapter"]
        )

        XCTAssertTrue(waitForFileContents(at: outputURL, matching: "vnc-adapter"))
    }

    func testProcessGraphicsAdapterLauncherSurfacesImmediateFailureOutput() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StacioGraphicsAdapterFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("fail.sh")
        let script = """
        #!/usr/bin/env bash
        echo "adapter failed"
        exit 42
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let launcher = ProcessGraphicsAdapterLauncher(immediateFailureProbeInterval: 0.5, appLog: nil)

        XCTAssertThrowsError(try launcher.launchAdapter(executablePath: scriptURL.path, arguments: [], environment: [:])) { error in
            XCTAssertEqual(error as? GraphicsAdapterLaunchError, .immediateFailure(exitCode: 42, output: "adapter failed"))
        }
    }

    private func waitForFileContents(
        at url: URL,
        matching expectedContents: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? String(contentsOf: url, encoding: .utf8)) == expectedContents {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return false
    }
}

private struct RecordingGraphicsAdapterLaunch {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

private final class RecordingGraphicsAdapterLauncher: GraphicsAdapterLaunching {
    private(set) var launches: [RecordingGraphicsAdapterLaunch] = []
    private(set) var terminatedProcessIdentifiers: [Int32] = []

    func launchAdapter(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> GraphicsAdapterLaunchHandle {
        launches.append(
            RecordingGraphicsAdapterLaunch(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment
            )
        )
        return GraphicsAdapterLaunchHandle(processIdentifier: 1234)
    }

    func terminateAdapter(processIdentifier: Int32) {
        terminatedProcessIdentifiers.append(processIdentifier)
    }
}

private final class RecordingGraphicsRuntimeLogStore: StacioLogWriting {
    private(set) var lines: [String] = []

    func append(
        level: StacioLogLevel,
        category: String,
        message: String,
        sensitiveValues: [String]
    ) {
        var sanitized = message
        for value in sensitiveValues where !value.isEmpty {
            sanitized = sanitized.replacingOccurrences(of: value, with: "<redacted>")
        }
        lines.append("[\(level.rawValue)] [\(category)] \(sanitized)")
    }
}

// MARK: - VNC 嵌入式会话 mock

private final class RecordingVNCGraphicsSession: EmbeddedGraphicsSessionLifecycle {
    var onFrame: ((GraphicsFrame) -> Void)?
    var onPointerPosition: ((_ x: Int, _ y: Int) -> Void)?
    var onPointerVisibilityChanged: ((_ isVisible: Bool) -> Void)?
    var onPointerBitmap: ((GraphicsPointerBitmap) -> Void)?
    var onConnected: ((_ width: Int, _ height: Int, _ name: String) -> Void)?
    var onDisconnected: ((_ reason: String) -> Void)?
    var onClipboard: ((_ text: String) -> Void)?
    var onNetworkStatus: ((_ rttMs: Int, _ mode: String) -> Void)?
    var onError: ((_ message: String) -> Void)?

    let host: String
    let port: UInt16
    let password: String?
    let quality: Int
    let maxFps: Int
    let adapterExecutablePath: String
    let startError: Error?
    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var inputs: [GraphicsInputEvent] = []

    init(
        host: String,
        port: UInt16,
        password: String?,
        quality: Int,
        maxFps: Int,
        adapterExecutablePath: String,
        startError: Error? = nil
    ) {
        self.host = host
        self.port = port
        self.password = password
        self.quality = quality
        self.maxFps = maxFps
        self.adapterExecutablePath = adapterExecutablePath
        self.startError = startError
    }

    func start() throws {
        if let startError {
            throw startError
        }
        didStart = true
    }

    func stop() {
        didStop = true
    }

    func sendInput(_ event: GraphicsInputEvent) {
        inputs.append(event)
    }
}

private final class RecordingVNCGraphicsSessionFactory: EmbeddedVNCGraphicsSessionFactory {
    private(set) var sessions: [RecordingVNCGraphicsSession] = []
    var startError: Error?

    func makeSession(
        host: String,
        port: UInt16,
        password: String?,
        quality: Int,
        maxFps: Int,
        adapterExecutablePath: String,
        appLog: StacioLogWriting?
    ) -> EmbeddedGraphicsSessionLifecycle {
        let session = RecordingVNCGraphicsSession(
            host: host,
            port: port,
            password: password,
            quality: quality,
            maxFps: maxFps,
            adapterExecutablePath: adapterExecutablePath,
            startError: startError
        )
        sessions.append(session)
        return session
    }
}

private struct GraphicsRuntimeManagerTestError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

// MARK: - RDP 嵌入式会话 mock

private final class RecordingRDPGraphicsSession: EmbeddedGraphicsSessionLifecycle {
    var onFrame: ((GraphicsFrame) -> Void)?
    var onPointerPosition: ((_ x: Int, _ y: Int) -> Void)?
    var onPointerVisibilityChanged: ((_ isVisible: Bool) -> Void)?
    var onPointerBitmap: ((GraphicsPointerBitmap) -> Void)?
    var onConnected: ((_ width: Int, _ height: Int, _ name: String) -> Void)?
    var onDisconnected: ((_ reason: String) -> Void)?
    var onClipboard: ((_ text: String) -> Void)?
    var onNetworkStatus: ((_ rttMs: Int, _ mode: String) -> Void)?
    var onError: ((_ message: String) -> Void)?

    let options: EmbeddedRDPSessionOptions
    let adapterExecutablePath: String
    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var inputs: [GraphicsInputEvent] = []

    init(options: EmbeddedRDPSessionOptions, adapterExecutablePath: String) {
        self.options = options
        self.adapterExecutablePath = adapterExecutablePath
    }

    func start() throws {
        didStart = true
    }

    func stop() {
        didStop = true
    }

    func sendInput(_ event: GraphicsInputEvent) {
        inputs.append(event)
    }
}

private final class RecordingRDPGraphicsSessionFactory: EmbeddedRDPGraphicsSessionFactory {
    private(set) var sessions: [RecordingRDPGraphicsSession] = []

    func makeSession(
        options: EmbeddedRDPSessionOptions,
        adapterExecutablePath: String,
        appLog: StacioLogWriting?
    ) -> EmbeddedGraphicsSessionLifecycle {
        let session = RecordingRDPGraphicsSession(
            options: options,
            adapterExecutablePath: adapterExecutablePath
        )
        sessions.append(session)
        return session
    }
}
