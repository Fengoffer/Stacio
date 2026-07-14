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

    func testDefaultManagerLaunchesPackagedVNCAdapterAndReturnsRunningStatus() throws {
        let launcher = RecordingGraphicsAdapterLauncher()
        let logStore = RecordingGraphicsRuntimeLogStore()
        let manager = DefaultGraphicsRuntimeManager(
            launcher: launcher,
            bundleURL: URL(fileURLWithPath: "/Applications/Stacio.app", isDirectory: true),
            appLog: logStore
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
        XCTAssertEqual(status.presentation, .diagnostic)
        XCTAssertNil(status.attachment)
        XCTAssertEqual(launcher.launches.map(\.executablePath), ["/Applications/Stacio.app/Contents/Adapters/vnc"])
        XCTAssertEqual(launcher.launches.map(\.arguments), [["--password", "vnc-secret", "desktop.example.com:5900"]])
        XCTAssertEqual(launcher.launches.first?.environment, [:])
        XCTAssertTrue(logStore.lines.contains { $0.contains("graphics.start") && $0.contains("desktop.example.com:5900") })
        XCTAssertTrue(logStore.lines.contains { $0.contains("graphics.started") && $0.contains("process=1234") })
        XCTAssertFalse(logStore.lines.joined(separator: "\n").contains("vnc-secret"))
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
