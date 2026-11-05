import XCTest
@testable import StacioApp
import StacioCoreBindings

final class SSHBridgeTests: XCTestCase {
    func testSSHConfigValidationIsAvailableFromSwift() throws {
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        XCTAssertNoThrow(try CoreBridge.validateSSHConfig(config))
    }

    func testSSHDiagnosticsAreRedactedFromSwift() throws {
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .password(credentialRef: "secret-ref"),
            connectTimeoutMs: 10_000
        )

        let status = try CoreBridge.diagnoseSSHConfig(config)

        XCTAssertFalse(status.connected)
        XCTAssertEqual(status.authMethod, "password")
        XCTAssertFalse(status.diagnostic.contains("secret-ref"))
        XCTAssertTrue(status.diagnostic.contains("[redacted-credential]"))
    }

    func testSshRuntimeLocalizedDescriptionIsUserFacingChinese() {
        let description = SshRuntimeError.Transport(message: "[Session(-37)] Would block")
            .localizedDescription

        XCTAssertEqual(description, "SSH 通道暂时不可用，请稍后重试")
        XCTAssertFalse(description.contains("StacioCoreBindings"))
        XCTAssertFalse(description.contains("SshRuntimeError"))
        XCTAssertFalse(description.contains("Transport"))
        XCTAssertFalse(description.localizedCaseInsensitiveContains("Would block"))

        let refused = SshRuntimeError.Transport(message: "Connection refused")
            .localizedDescription
        XCTAssertEqual(refused, "SSH 连接被拒绝")

        let transfer = SshRuntimeError.Transport(message: "FILES_TRANSFER_INTERRUPTED")
            .localizedDescription
        XCTAssertEqual(transfer, "文件传输中断")
    }

    func testTerminalRuntimeLocalizedDescriptionIsUserFacingChinese() {
        let ioDescription = TerminalRuntimeError.RuntimeIo(message: "Input/output error")
            .localizedDescription

        XCTAssertEqual(ioDescription, "终端读写失败：设备输入输出错误")
        XCTAssertFalse(ioDescription.contains("StacioCoreBindings"))
        XCTAssertFalse(ioDescription.contains("TerminalRuntimeError"))
        XCTAssertFalse(ioDescription.localizedCaseInsensitiveContains("Input/output error"))

        let closed = TerminalRuntimeError.RuntimeClosed(runtimeId: "runtime-1")
            .localizedDescription
        XCTAssertEqual(closed, "终端会话已关闭")

        let serialPermission = TerminalRuntimeError.RuntimeIo(message: "Operation not permitted")
            .localizedDescription
        XCTAssertEqual(serialPermission, "终端读写失败：没有操作权限")
    }

    func testFileTransferLocalizedDescriptionsAreUserFacingChinese() {
        XCTAssertEqual(
            ScpTransferError.PermissionDenied.localizedDescription,
            "文件传输权限不足"
        )
        XCTAssertEqual(
            ScpTransferError.Interrupted.localizedDescription,
            "文件传输中断"
        )
        XCTAssertEqual(
            FilesError.UnsafePath.localizedDescription,
            "远程路径不安全"
        )
    }

    func testHostKeyHelpersAreAvailableFromSwift() throws {
        let hostKey = Array("host-key".utf8)
        let fingerprint = CoreBridge.fingerprintHostKey(hostKey)
        let known = HostKeyRecord(
            host: "example.com",
            port: 22,
            fingerprintSha256: fingerprint
        )

        let verification = try CoreBridge.verifyKnownHost(
            host: "example.com",
            port: 22,
            hostKey: hostKey,
            knownHosts: [known]
        )

        XCTAssertEqual(verification, .trusted)
        XCTAssertEqual(CoreBridge.hostKeyTrustDecisionLabel(.trustAndSave), "trust_and_save")
    }

    func testChangedHostKeyIsRejectedFromSwift() throws {
        let known = HostKeyRecord(
            host: "example.com",
            port: 22,
            fingerprintSha256: CoreBridge.fingerprintHostKey(Array("old-key".utf8))
        )

        XCTAssertThrowsError(
            try CoreBridge.verifyKnownHost(
                host: "example.com",
                port: 22,
                hostKey: Array("new-key".utf8),
                knownHosts: [known]
            )
        )
    }

    func testLiveSSHAuthSecretDescriptionsAreRedacted() throws {
        let password = SshAuthSecret.password(value: "super-secret")

        XCTAssertFalse(String(describing: password).contains("super-secret"))
    }

    func testDatabaseBackedHostKeyDecisionIsAvailableFromSwift() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let hostKey = Array("host-key".utf8)
        let verification = try CoreBridge.applyHostKeyDecisionInDatabase(
            databasePath: tempURL.path,
            host: "example.com",
            port: 22,
            hostKey: hostKey,
            decision: .trustAndSave
        )

        XCTAssertEqual(verification, .trusted)
        let reprobe = try CoreBridge.applyHostKeyDecisionInDatabase(
            databasePath: tempURL.path,
            host: "example.com",
            port: 22,
            hostKey: hostKey,
            decision: .reject
        )
        XCTAssertEqual(reprobe, .trusted)
    }

    func testRemoteTerminalRuntimeBridgeQueuesInputWithoutSystemCommand() throws {
        let runtime = CoreBridge.openRemoteSSHRuntime(
            host: "example.com",
            port: 22,
            username: "deploy",
            cols: 80,
            rows: 24
        )

        XCTAssertEqual(runtime.kind, "remote_ssh")
        XCTAssertEqual(runtime.remoteHost, "example.com")
        XCTAssertEqual(runtime.remotePort, 22)
        XCTAssertEqual(runtime.username, "deploy")
        XCTAssertFalse(String(describing: runtime).contains("ssh "))
        XCTAssertFalse(String(describing: runtime).contains("scp "))
        XCTAssertFalse(String(describing: runtime).contains("sftp "))
        XCTAssertFalse(String(describing: runtime).contains("rsync "))

        try CoreBridge.writeTerminalInput(runtimeID: runtime.id, bytes: Array("pwd\n".utf8))
        let batch = try CoreBridge.takeTerminalInputBatch(runtimeID: runtime.id)

        XCTAssertEqual(Array(batch.bytes), Array("pwd\n".utf8))
        XCTAssertEqual(batch.droppedByteCount, 0)
    }

    func testLiveShellStatusBridgeTypesAreAvailableFromSwift() throws {
        let runtime = CoreBridge.openRemoteSSHRuntime(
            host: "example.com",
            port: 22,
            username: "deploy",
            cols: 80,
            rows: 24
        )

        let status = try CoreBridge.pollLiveSSHShell(runtimeID: runtime.id)

        XCTAssertEqual(status.runtimeId, runtime.id)
        XCTAssertEqual(status.status, "not_running")
        XCTAssertFalse(status.diagnostic.contains("secret"))
    }

    func testStartLiveSSHShellRejectsInvalidConfigBeforeNetwork() {
        let config = SshConnectionConfig(
            host: "",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        XCTAssertThrowsError(
            try CoreBridge.startLiveSSHShellRuntime(
                config: config,
                secret: .agent,
                expectedFingerprintSHA256: "SHA256:test",
                cols: 80,
                rows: 24
            )
        )
    }

    func testStartLiveSerialShellRejectsInvalidConfigBeforeOpeningDevice() {
        let config = SerialConnectionConfig(
            devicePath: "",
            baudRate: 9_600,
            dataBits: 8,
            stopBits: 1,
            parity: "none",
            flowControl: "none",
            backspaceMode: "del"
        )

        XCTAssertThrowsError(
            try CoreBridge.startLiveSerialShellRuntime(
                config: config,
                cols: 80,
                rows: 24
            )
        )
        XCTAssertFalse(String(describing: config).contains("screen "))
        XCTAssertFalse(String(describing: config).contains("minicom "))
        XCTAssertFalse(String(describing: config).contains("password"))
        XCTAssertFalse(String(describing: config).contains("secret"))
    }
}
