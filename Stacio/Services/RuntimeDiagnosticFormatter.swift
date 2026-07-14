import Foundation

enum RuntimeDiagnosticFormatter {
    static func userMessage(_ diagnostic: String) -> String {
        let normalized = normalize(diagnostic)
        if isRemoteEditLocalCopyMissingDiagnostic(normalized) {
            return "本地编辑副本已丢失，请重新打开远程文件后再保存"
        }
        return translate(redact(normalized))
    }

    static func userMessage(for error: Error) -> String {
        if let sshError = error as? SSHConnectionCoordinatorError {
            switch sshError {
            case .missingPasswordSecret:
                return "缺少 SSH 密码凭据"
            case .missingPrivateKey:
                return "无法读取 SSH 私钥"
            case .hostKeyRejected:
                return "用户已拒绝主机密钥"
            case let .proxyJumpSessionNotFound(id):
                return "找不到跳板机会话：\(id)"
            }
        }
        if let description = (error as? LocalizedError)?
            .errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty
        {
            return userMessage(description)
        }
        return userMessage(String(describing: error))
    }

    private static func normalize(_ input: String) -> String {
        guard let messageRange = input.range(of: "message: ") else {
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var message = String(input[messageRange.upperBound...])
        if message.hasSuffix(")") {
            message.removeLast()
        }
        if message.hasPrefix("\""), message.hasSuffix("\"") {
            message.removeFirst()
            message.removeLast()
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func redact(_ input: String) -> String {
        var shouldRedactNextBearerValue = false
        let redacted = input.split(whereSeparator: \.isWhitespace).map { token -> String in
            let value = String(token)
            let lowercased = value.lowercased()
            if shouldRedactNextBearerValue {
                shouldRedactNextBearerValue = false
                return L10n.Diagnostics.redactedCredential
            }
            if lowercased == "bearer" || lowercased.hasSuffix(":bearer") {
                shouldRedactNextBearerValue = true
                return value
            }
            if lowercased.contains("password")
                || lowercased.contains("passphrase")
                || lowercased.contains("credential")
                || lowercased.contains("secret")
                || lowercased.contains("token")
            {
                return L10n.Diagnostics.redactedCredential
            }
            if value.hasPrefix("/")
                || value.hasPrefix("~")
                || lowercased.contains("/.ssh/")
                || lowercased.contains(".ssh/")
            {
                return L10n.Diagnostics.redactedPath
            }
            return value
        }

        return redacted.reduce(into: [String]()) { result, token in
            if result.last == token, token.hasPrefix("[已隐藏") {
                return
            }
            result.append(token)
        }
        .joined(separator: " ")
    }

    private static func isRemoteEditLocalCopyMissingDiagnostic(_ input: String) -> Bool {
        input.lowercased().contains("localcopymissing")
    }

    private static func translate(_ input: String) -> String {
        var message = input
        let didStripTransportWrapper = message.hasPrefix("StacioCoreBindings.SshRuntimeError.Transport(")
        if message.hasPrefix("StacioCoreBindings.SshRuntimeError.Transport(") {
            message = message.replacingOccurrences(
                of: "StacioCoreBindings.SshRuntimeError.Transport(",
                with: ""
            )
        }
        if didStripTransportWrapper,
           message.hasSuffix(")") {
            message.removeLast()
        }
        message = message.removingLowLevelSocketErrorCode()
        if message.localizedCaseInsensitiveContains("would block") || message.contains("Session(-37)") {
            return "SSH 通道暂时不可用，请稍后重试"
        }
        if let codedMessage = fileTransferMessage(for: message) {
            return codedMessage
        }
        if let codedMessage = deviceMetricsMessage(for: message) {
            return codedMessage
        }
        if message == "FTP_RESUME_UNSUPPORTED" {
            return "FTP 服务器不支持断点续传，请删除本地部分文件后重新下载"
        }
        if message.hasPrefix("FTP_STATUS_") {
            return ftpStatusMessage(for: message)
        }
        let replacements: [(String, String)] = [
            ("StacioCoreBindings.SshRuntimeError.InvalidConfig", "SSH 配置无效"),
            ("StacioCoreBindings.SshRuntimeError.AuthFailed", "SSH 认证失败"),
            ("StacioCoreBindings.SshRuntimeError.Timeout", "SSH 连接超时"),
            ("StacioCoreBindings.SshRuntimeError.HostKeyChanged", "SSH 主机密钥已变更"),
            ("StacioCoreBindings.SshRuntimeError.UnknownHostKey", "SSH 主机密钥未知"),
            ("Terminal runtime I/O error:", "终端读写失败："),
            ("Terminal runtime I/O error", "终端读写失败"),
            ("Device or resource busy", "设备正忙"),
            ("device or resource busy", "设备正忙"),
            ("Input/output error", "设备输入输出错误"),
            ("input/output error", "设备输入输出错误"),
            ("No such file or directory", "设备不存在"),
            ("no such file or directory", "设备不存在"),
            ("Resource busy", "设备正忙"),
            ("resource busy", "设备正忙"),
            ("Device not configured", "设备未就绪"),
            ("device not configured", "设备未就绪"),
            ("Operation not permitted", "没有操作权限"),
            ("operation not permitted", "没有操作权限"),
            ("Inappropriate ioctl for device", "设备不支持该操作"),
            ("inappropriate ioctl for device", "设备不支持该操作"),
            ("Invalid argument", "参数无效"),
            ("invalid argument", "参数无效"),
            ("No such device", "设备不存在"),
            ("no such device", "设备不存在"),
            ("Bad file descriptor", "设备句柄无效"),
            ("bad file descriptor", "设备句柄无效"),
            ("Broken pipe", "连接管道已断开"),
            ("broken pipe", "连接管道已断开"),
            ("Authentication failed", "认证失败"),
            ("authentication failed", "认证失败"),
            ("Host key verification failed", "主机密钥验证失败"),
            ("host key verification failed", "主机密钥验证失败"),
            ("Connection closed", "连接已关闭"),
            ("connection closed", "连接已关闭"),
            ("Permission denied", "权限被拒绝"),
            ("permission denied", "权限被拒绝"),
            ("Connection reset by peer", "连接被远端重置"),
            ("connection reset by peer", "连接被远端重置"),
            ("Network is unreachable", "网络不可达"),
            ("network is unreachable", "网络不可达"),
            ("Connection refused", "连接被拒绝"),
            ("connection refused", "连接被拒绝"),
            ("Address already in use", "端口已被占用"),
            ("address already in use", "端口已被占用"),
            ("EADDRINUSE", "端口已被占用"),
            ("eaddrinuse", "端口已被占用"),
            ("SSH 无法到达主机", "无法到达主机"),
            ("No route to host", "无法到达主机"),
            ("no route to host", "无法到达主机"),
            ("Connection timed out", "连接超时"),
            ("connection timed out", "连接超时"),
            ("Operation timed out", "连接超时"),
            ("operation timed out", "连接超时"),
            ("Timed out", "连接超时"),
            ("timed out", "连接超时"),
            ("Timeout", "连接超时"),
            ("timeout", "连接超时"),
            ("failed at", "失败位置"),
            ("Failed at", "失败位置")
        ]

        for (needle, replacement) in replacements {
            message = message.replacingOccurrences(of: needle, with: replacement)
        }
        message = message.replacingOccurrences(of: "： ", with: "：")
        return message
    }

    private static func fileTransferMessage(for code: String) -> String? {
        switch code {
        case "FILES_PERMISSION_DENIED":
            return "文件传输权限不足"
        case "FILES_TRANSFER_INTERRUPTED":
            return "文件传输中断"
        case "FILES_TRANSFER_TIMEOUT":
            return "网络超时：单次文件读写超过 30 秒，请检查网络稳定性后重试"
        case "FILES_TRANSFER_RETRY_EXHAUSTED":
            return "网络抖动：SSH 通道连续暂不可用，已自动重试 3 次"
        case "FILES_TRANSFER_CANCELED":
            return "文件传输已取消"
        case "FILES_LOCAL_FILE_MISSING":
            return "本地文件不存在"
        case "FILES_LOCAL_WRITE_FAILED":
            return "本地文件写入失败"
        case "FILES_REMOTE_FILE_MISSING":
            return "远端文件不存在"
        case "FILES_DISK_FULL":
            return "磁盘空间不足"
        case "FILES_SIZE_MISMATCH":
            return "文件大小不一致"
        case "FILES_UNSAFE_PATH":
            return "远程路径不安全"
        case "FILES_UNSAFE_MODE":
            return "远程文件权限模式无效"
        case "FILES_INVALID_DIRECTION":
            return "文件传输方向无效"
        case "FILES_REMOTE_COMMAND_FAILED":
            return "远程文件操作失败"
        case "FILES_REMOTE_LIST_PARSE_FAILED":
            return "远程目录列表解析失败"
        default:
            return nil
        }
    }

    private static func deviceMetricsMessage(for code: String) -> String? {
        switch code {
        case "METRICS_PROBE_MISSING_CPU:/proc/stat":
            return "设备看板采集失败：无法读取 /proc/stat，CPU 探针不可用"
        case "METRICS_PROBE_MISSING_MEMORY:/proc/meminfo":
            return "设备看板采集失败：无法读取 /proc/meminfo，内存探针不可用"
        case "METRICS_PROBE_MISSING_NETWORK:/proc/net/dev":
            return "设备看板采集失败：无法读取 /proc/net/dev，网卡探针不可用"
        case "METRICS_PROBE_MISSING_DISK:df":
            return "设备看板采集失败：无法执行 df，磁盘探针不可用"
        default:
            return nil
        }
    }

    private static func ftpStatusMessage(for code: String) -> String {
        switch code {
        case "FTP_STATUS_421":
            return "FTP 连接超时或服务暂不可用"
        case "FTP_STATUS_530":
            return "FTP 认证失败"
        case "FTP_STATUS_550":
            return "FTP 文件或目录不可用"
        default:
            return "FTP 操作失败：\(code)"
        }
    }
}

private extension String {
    func removingLowLevelSocketErrorCode() -> String {
        replacingOccurrences(
            of: #"\s*\(?os error\s+\d+\)?"#,
            with: "",
            options: [.regularExpression]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
