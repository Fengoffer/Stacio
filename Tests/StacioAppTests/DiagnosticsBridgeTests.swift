import XCTest
@testable import StacioApp
import StacioCoreBindings
import Darwin

final class DiagnosticsBridgeTests: XCTestCase {
    func testTunnelValidationIsAvailableFromSwift() throws {
        let profile = TunnelProfile(
            id: "tun_1",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: "127.0.0.1",
            remotePort: 80
        )

        XCTAssertNoThrow(try CoreBridge.validateTunnelProfile(profile))
    }

    func testMockTunnelRuntimeStartStopIsAvailableFromSwift() throws {
        let profile = TunnelProfile(
            id: "tun_1",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: "127.0.0.1",
            remotePort: 80
        )

        let status = try CoreBridge.startMockTunnel(profile: profile, outcome: .started)
        let stopped = try CoreBridge.stopTunnelRuntime(state: status.state)

        XCTAssertEqual(status.profileId, "tun_1")
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.message, "running")
        XCTAssertEqual(stopped, .stopped)
    }

    func testMockTunnelRuntimeReportsPortInUseFromSwift() throws {
        let profile = TunnelProfile(
            id: "tun_1",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 8080,
            remoteHost: "127.0.0.1",
            remotePort: 80
        )

        XCTAssertThrowsError(
            try CoreBridge.startMockTunnel(profile: profile, outcome: .localPortInUse)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("LocalPortInUse"))
        }
    }

    func testLiveTunnelRuntimeRejectsInvalidSSHConfigFromSwift() throws {
        let config = SshConnectionConfig(
            host: "",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )
        let profile = TunnelProfile(
            id: "tun_live_invalid",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: 18080,
            remoteHost: "db.internal",
            remotePort: 5432
        )

        XCTAssertThrowsError(
            try CoreBridge.startLiveLocalTunnelRuntime(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                profile: profile
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("InvalidConfig"))
        }
    }

    func testLiveTunnelRuntimePollAndCloseAreAvailableFromSwift() throws {
        let polled = try CoreBridge.pollLiveTunnelRuntime(profileID: "tun_missing_swift")
        let closed = try CoreBridge.closeLiveTunnelRuntime(profileID: "tun_missing_swift")

        XCTAssertEqual(polled.profileId, "tun_missing_swift")
        XCTAssertEqual(polled.state, .stopped)
        XCTAssertEqual(polled.message, "not_running")
        XCTAssertEqual(closed.profileId, "tun_missing_swift")
        XCTAssertEqual(closed.state, .stopped)
        XCTAssertEqual(closed.message, "stopped")
    }

    func testTunnelLocalPortPreflightReportsPortInUseFromSwift() throws {
        let listener = try BoundTCPPort()
        let profile = TunnelProfile(
            id: "tun_1",
            kind: .local,
            localHost: "127.0.0.1",
            localPort: listener.port,
            remoteHost: "127.0.0.1",
            remotePort: 80
        )

        XCTAssertThrowsError(try CoreBridge.checkTunnelLocalPortAvailable(profile)) { error in
            let description = String(describing: error)
            XCTAssertTrue(
                description.lowercased().contains("localportinuse"),
                description
            )
        }
    }

    func testTunnelProfilesPersistThroughCoreBridge() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-tunnels-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let profile = TunnelProfile(
            id: "tun_profile_swift",
            kind: .remote,
            localHost: "127.0.0.1",
            localPort: 15432,
            remoteHost: "0.0.0.0",
            remotePort: 19000
        )

        try CoreBridge.saveTunnelProfile(
            databasePath: tempURL.path,
            sessionID: nil,
            profile: profile
        )
        let profiles = try CoreBridge.listTunnelProfiles(databasePath: tempURL.path, sessionID: nil)
        try CoreBridge.deleteTunnelProfile(databasePath: tempURL.path, profileID: profile.id)
        let deleted = try CoreBridge.listTunnelProfiles(databasePath: tempURL.path, sessionID: nil)

        XCTAssertEqual(profiles, [profile])
        XCTAssertTrue(deleted.isEmpty)
    }

    func testDiagnosticBundleRedactsSecretsFromSwift() throws {
        let entry = DiagnosticEntry(
            severity: .error,
            message: "credential secret-ref key /Users/me/.ssh/id_ed25519 failed"
        )

        let bundle = CoreBridge.buildDiagnosticBundle(
            sessionID: "session_1",
            tunnelID: "tun_1",
            entries: [entry]
        )

        XCTAssertEqual(bundle.sessionId, "session_1")
        XCTAssertEqual(bundle.tunnelId, "tun_1")
        XCTAssertFalse(bundle.entries[0].message.contains("secret-ref"))
        XCTAssertFalse(bundle.entries[0].message.contains("/Users/me/.ssh/id_ed25519"))
        XCTAssertTrue(bundle.entries[0].message.contains("[redacted-credential]"))
    }
}

private final class BoundTCPPort {
    let fileDescriptor: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        fileDescriptor = fd

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard listen(fd, 1) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.getsockname(fd, sockaddrPointer, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        port = UInt16(bigEndian: boundAddress.sin_port)
    }

    deinit {
        close(fileDescriptor)
    }
}
