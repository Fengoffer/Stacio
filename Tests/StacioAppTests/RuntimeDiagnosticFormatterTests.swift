import XCTest
import StacioCoreBindings
@testable import StacioApp

final class RuntimeDiagnosticFormatterTests: XCTestCase {
    func testUserMessageForLocalizedRuntimeErrorPrefersChineseLocalizedDescription() {
        let message = RuntimeDiagnosticFormatter.userMessage(
            for: SshRuntimeError.Transport(message: "Connection refused")
        )

        XCTAssertEqual(message, "SSH 连接被拒绝")
        XCTAssertFalse(message.contains("StacioCoreBindings"))
        XCTAssertFalse(message.contains("SshRuntimeError"))
        XCTAssertFalse(message.contains("Transport"))

        XCTAssertEqual(
            RuntimeDiagnosticFormatter.userMessage(for: SshRuntimeError.AuthFailed),
            "SSH 认证失败"
        )
        XCTAssertEqual(
            RuntimeDiagnosticFormatter.userMessage(for: SSHConnectionCoordinatorError.hostKeyRejected),
            "用户已拒绝主机密钥"
        )
    }

    func testUserMessageTranslatesCommonRuntimeFailuresIntoChinese() {
        let cases: [(String, String)] = [
            ("authentication failed", "认证失败"),
            ("host key verification failed", "主机密钥验证失败"),
            ("connection closed", "连接已关闭"),
            ("connection reset by peer", "连接被远端重置"),
            ("permission denied", "权限被拒绝"),
            ("timed out", "连接超时"),
            ("timeout", "连接超时"),
            ("no route to host", "无法到达主机"),
            ("network is unreachable", "网络不可达"),
            ("connection refused", "连接被拒绝"),
            ("Address already in use", "端口已被占用"),
            ("EADDRINUSE", "端口已被占用")
        ]

        for (input, expected) in cases {
            XCTAssertEqual(RuntimeDiagnosticFormatter.userMessage(input), expected, input)
        }
    }

    func testUserMessageRemovesLowLevelSocketErrorCodeFromSSHReachabilityDiagnostic() {
        let formatted = RuntimeDiagnosticFormatter.userMessage("SSH 无法到达主机 (os error 65)")

        XCTAssertEqual(formatted, "无法到达主机")
        XCTAssertFalse(formatted.contains("os error 65"))
    }

    func testUserMessageRedactsSecretsAndPathsBeforeTranslating() {
        let message = "authentication failed secret /Users/me/.ssh/id_ed25519"

        let formatted = RuntimeDiagnosticFormatter.userMessage(message)

        XCTAssertEqual(formatted, "认证失败 [已隐藏凭据] [已隐藏路径]")
        XCTAssertFalse(formatted.contains("secret"))
        XCTAssertFalse(formatted.contains("/Users/me/.ssh/id_ed25519"))
    }

    func testUserMessageRedactsPasswordTokenAndKeyPathsCaseInsensitively() {
        let message = "authentication failed PASSWORD=ProdPassword TOKEN=api-value key=~/.SSH/id_ed25519"

        let formatted = RuntimeDiagnosticFormatter.userMessage(message)

        XCTAssertFalse(formatted.contains("ProdPassword"))
        XCTAssertFalse(formatted.contains("api-value"))
        XCTAssertFalse(formatted.contains("~/.SSH/id_ed25519"))
        XCTAssertTrue(formatted.contains("[已隐藏凭据]"))
        XCTAssertTrue(formatted.contains("[已隐藏路径]"))
    }

    func testUserMessageRedactsBearerCredentialValuesWithOrWithoutHeaderSpacing() {
        let spaced = RuntimeDiagnosticFormatter.userMessage(
            "authentication failed Authorization: Bearer sk-live-123456"
        )
        let compact = RuntimeDiagnosticFormatter.userMessage(
            "authentication failed Authorization:Bearer sk-live-abcdef"
        )

        XCTAssertEqual(spaced, "认证失败 Authorization: Bearer [已隐藏凭据]")
        XCTAssertEqual(compact, "认证失败 Authorization:Bearer [已隐藏凭据]")
        XCTAssertFalse(spaced.contains("sk-live-123456"))
        XCTAssertFalse(compact.contains("sk-live-abcdef"))
    }

    func testUserMessageRedactsPrivateKeyPassphraseDiagnostics() {
        let message = "private key auth failed PASSPHRASE=key-passphrase passphrase_ref=keychain-item"

        let formatted = RuntimeDiagnosticFormatter.userMessage(message)

        XCTAssertFalse(formatted.contains("key-passphrase"))
        XCTAssertFalse(formatted.contains("keychain-item"))
        XCTAssertTrue(formatted.contains("[已隐藏凭据]"))
    }

    func testUserMessageTurnsLibssh2WouldBlockEnumIntoChineseDiagnostic() {
        let formatted = RuntimeDiagnosticFormatter.userMessage(
            #"StacioCoreBindings.SshRuntimeError.Transport(message: "[Session(-37)] Would block")"#
        )

        XCTAssertEqual(formatted, "SSH 通道暂时不可用，请稍后重试")
        XCTAssertFalse(formatted.contains("StacioCoreBindings"))
        XCTAssertFalse(formatted.contains("SshRuntimeError"))
        XCTAssertFalse(formatted.contains("Transport"))
        XCTAssertFalse(formatted.localizedCaseInsensitiveContains("Would block"))
    }

    func testUserMessageTranslatesFileTransferAndFtpMachineCodes() {
        let cases: [(String, String)] = [
            ("FILES_REMOTE_COMMAND_FAILED", "远程文件操作失败"),
            ("FILES_REMOTE_LIST_PARSE_FAILED", "远程目录列表解析失败"),
            ("FILES_LOCAL_FILE_MISSING", "本地文件不存在"),
            ("FILES_LOCAL_WRITE_FAILED", "本地文件写入失败"),
            ("FILES_SIZE_MISMATCH", "文件大小不一致"),
            ("FILES_TRANSFER_INTERRUPTED", "文件传输中断"),
            ("FILES_TRANSFER_CANCELED", "文件传输已取消"),
            ("FILES_UNSAFE_PATH", "远程路径不安全"),
            ("FILES_UNSAFE_MODE", "远程文件权限模式无效"),
            ("FILES_INVALID_DIRECTION", "文件传输方向无效"),
            ("FTP_RESUME_UNSUPPORTED", "FTP 服务器不支持断点续传，请删除本地部分文件后重新下载"),
            ("FTP_STATUS_530", "FTP 认证失败"),
            ("FTP_STATUS_550", "FTP 文件或目录不可用")
        ]

        for (input, expected) in cases {
            XCTAssertEqual(RuntimeDiagnosticFormatter.userMessage(input), expected, input)
        }
    }

    func testUserMessageTranslatesDeviceMetricsProbeDiagnostics() {
        let cases: [(String, String)] = [
            ("METRICS_PROBE_MISSING_CPU:/proc/stat", "设备看板采集失败：无法读取 /proc/stat，CPU 探针不可用"),
            ("METRICS_PROBE_MISSING_MEMORY:/proc/meminfo", "设备看板采集失败：无法读取 /proc/meminfo，内存探针不可用"),
            ("METRICS_PROBE_MISSING_NETWORK:/proc/net/dev", "设备看板采集失败：无法读取 /proc/net/dev，网卡探针不可用"),
            ("METRICS_PROBE_MISSING_DISK:df", "设备看板采集失败：无法执行 df，磁盘探针不可用")
        ]

        for (input, expected) in cases {
            XCTAssertEqual(RuntimeDiagnosticFormatter.userMessage(input), expected, input)
        }
    }

    func testUserMessageTranslatesSerialRuntimeIoFailures() {
        let cases: [(String, String)] = [
            ("Terminal runtime I/O error: Input/output error", "终端读写失败：设备输入输出错误"),
            ("Terminal runtime I/O error: No such file or directory", "终端读写失败：设备不存在"),
            ("Terminal runtime I/O error: Resource busy", "终端读写失败：设备正忙"),
            ("Terminal runtime I/O error: Device not configured", "终端读写失败：设备未就绪"),
            ("Terminal runtime I/O error: Operation not permitted", "终端读写失败：没有操作权限"),
            ("Terminal runtime I/O error: Inappropriate ioctl for device", "终端读写失败：设备不支持该操作"),
            ("Terminal runtime I/O error: Invalid argument", "终端读写失败：参数无效"),
            ("Terminal runtime I/O error: No such device", "终端读写失败：设备不存在"),
            ("Terminal runtime I/O error: Bad file descriptor", "终端读写失败：设备句柄无效"),
            ("Terminal runtime I/O error: Broken pipe", "终端读写失败：连接管道已断开")
        ]

        for (input, expected) in cases {
            XCTAssertEqual(RuntimeDiagnosticFormatter.userMessage(input), expected, input)
        }
    }

    func testUserMessageForMissingRemoteEditLocalCopyExplainsRecoveryAndRedactsPath() {
        let formatted = RuntimeDiagnosticFormatter.userMessage(
            for: RemoteEditCacheError.localCopyMissing("/tmp/secret/file.txt")
        )

        XCTAssertEqual(formatted, "本地编辑副本已丢失，请重新打开远程文件后再保存")
        XCTAssertFalse(formatted.contains("/tmp/secret/file.txt"))
        XCTAssertFalse(formatted.contains("/tmp"))
        XCTAssertFalse(formatted.contains("secret"))
    }
}
