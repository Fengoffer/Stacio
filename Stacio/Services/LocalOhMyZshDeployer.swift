import Darwin
import Foundation

/// 本地终端 Oh My Zsh 部署器。
///
/// 职责：把已验证的按需 oh-my-zsh 快照部署到本机 `~/.oh-my-zsh`，
/// 在 `~/.zshrc` 中非破坏式写入 Stacio 配置区块（带时间戳备份），
/// 支持验证失败回滚与分场景卸载（仅删除 Stacio 创建的目录）。
///
/// 线程：调用方需在后台队列执行（本类型所有方法为同步阻塞，不触碰 UI）。
public final class LocalOhMyZshDeployer {
    public static let managedMarkerFileName = ".stacio-managed"
    public static let blockStartMarker = OhMyZshConfigResolver.blockStartMarker

    private let fileManager: FileManager
    private let homeDirectoryURL: URL
    private let bundleOhMyZshURL: URL?
    /// 可注入的 zsh 交互校验器（默认走真实 `zsh -i -c`）；测试可注入假实现。
    private let zshVerifier: (() throws -> Void)?

    public init(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil,
        bundleOhMyZshURL: URL? = nil,
        zshVerifier: (() throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL ?? fileManager.homeDirectoryForCurrentUser
        self.bundleOhMyZshURL = bundleOhMyZshURL
            ?? OhMyZshResourceManager.shared.installedDirectoryURL
        self.zshVerifier = zshVerifier
    }

    public var ohMyZshDirectoryURL: URL {
        homeDirectoryURL.appendingPathComponent(".oh-my-zsh", isDirectory: true)
    }

    public var zshrcURL: URL {
        homeDirectoryURL.appendingPathComponent(".zshrc")
    }

    public struct DeploymentStatus: Equatable {
        public let directoryExists: Bool
        public let managedByStacio: Bool
        public let zshrcHasBlock: Bool
        public let zshAvailable: Bool

        public var isDeployed: Bool {
            directoryExists && zshrcHasBlock
        }
    }

    // MARK: - 状态

    public func status() -> DeploymentStatus {
        let directoryExists = fileManager.fileExists(atPath: ohMyZshDirectoryURL.path)
        let markerPath = ohMyZshDirectoryURL.appendingPathComponent(Self.managedMarkerFileName).path
        let managed = directoryExists && fileManager.fileExists(atPath: markerPath)
        let zshrc = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        let hasBlock = OhMyZshConfigResolver.containsBlock(in: zshrc)
        let zshAvailable = fileManager.fileExists(atPath: "/bin/zsh")
            || resolveExecutable("zsh") != nil
        return DeploymentStatus(
            directoryExists: directoryExists,
            managedByStacio: managed,
            zshrcHasBlock: hasBlock,
            zshAvailable: zshAvailable
        )
    }

    // MARK: - 部署

    /// 部署（幂等）。任一步失败回滚：恢复 .zshrc 与原有 ~/.oh-my-zsh 目录。
    public func deploy(global: AppSettings, catalog: OhMyZshCatalog) throws {
        let currentStatus = status()
        guard currentStatus.zshAvailable else {
            throw LocalOhMyZshDeployerError.zshNotAvailable
        }
        guard let bundleOhMyZshURL else {
            throw LocalOhMyZshDeployerError.bundleUnavailable
        }
        let resolved = OhMyZshConfigResolver.resolve(global: global, session: .default)
        guard resolved.enabled else {
            // 未启用：若已部署则移除，避免残留配置
            try remove()
            return
        }

        // 1) 备份现有 .zshrc（任何写操作前）
        let hadZshrc = fileManager.fileExists(atPath: zshrcURL.path)
        let zshrcBackupURL = try backupZshrcIfNeeded()

        // 2) 目录：整体备份后替换（保留 custom 于备份中）
        let directoryExists = fileManager.fileExists(atPath: ohMyZshDirectoryURL.path)
        let directoryBackupURL = directoryExists
            ? ohMyZshDirectoryURL.deletingLastPathComponent()
                .appendingPathComponent(".oh-my-zsh.stacio-backup-\(backupSuffix())")
            : nil
        if let directoryBackupURL {
            try fileManager.moveItem(at: ohMyZshDirectoryURL, to: directoryBackupURL)
        }

        do {
            try fileManager.createDirectory(
                at: ohMyZshDirectoryURL,
                withIntermediateDirectories: true
            )
            try copyDirectoryContents(from: bundleOhMyZshURL, to: ohMyZshDirectoryURL)
            // 写 Stacio 管理标记
            let marker = "stacio-managed\ninstalled-at: \(ISO8601DateFormatter().string(from: Date()))\n"
            try marker.write(
                to: ohMyZshDirectoryURL.appendingPathComponent(Self.managedMarkerFileName),
                atomically: true,
                encoding: .utf8
            )
            // 恢复用户 custom/（从整体备份）
            if let directoryBackupURL {
                let customBackup = directoryBackupURL.appendingPathComponent("custom", isDirectory: true)
                if fileManager.fileExists(atPath: customBackup.path) {
                    let customURL = ohMyZshDirectoryURL.appendingPathComponent("custom", isDirectory: true)
                    try? fileManager.removeItem(at: customURL)
                    // 恢复失败必须 throw（进回滚恢复整体备份）：吞错会让用户自定义主题/插件丢失
                    try fileManager.moveItem(at: customBackup, to: customURL)
                }
            }

            // 3) 写入 .zshrc 区块（非破坏式）
            // 读失败/解码失败必须中止（不吞错）：回退空串会把用户真实 .zshrc 覆盖为仅 Stacio 区块且原内容永久丢失。
            let oldZshrc: String
            if fileManager.fileExists(atPath: zshrcURL.path) {
                guard let decoded = try? String(contentsOf: zshrcURL, encoding: .utf8) else {
                    throw LocalOhMyZshDeployerError.zshrcDecodeFailed
                }
                oldZshrc = decoded
            } else {
                oldZshrc = ""
            }
            let newZshrc = OhMyZshConfigResolver.upsertBlock(in: oldZshrc, config: resolved)
            try newZshrc.write(to: zshrcURL, atomically: true, encoding: .utf8)

            // 4) 验证
            if let zshVerifier {
                try zshVerifier()
            } else {
                try verifyInteractiveZsh()
            }
        } catch {
            // 回滚：恢复 .zshrc（原有内容或删除新写入的）
            var zshrcRollbackFailed = false
            if let zshrcBackupURL {
                try? fileManager.removeItem(at: zshrcURL)
                do {
                    try fileManager.moveItem(at: zshrcBackupURL, to: zshrcURL)
                } catch {
                    // 恢复失败必须抛含备份路径的错误（与远程 rollbackZshrcFailed 对齐），备份保留供手动恢复
                    zshrcRollbackFailed = true
                }
            } else if hadZshrc == false {
                try? fileManager.removeItem(at: zshrcURL)
            }
            // 回滚：删除新目录并恢复原目录（若原目录存在）
            try? fileManager.removeItem(at: ohMyZshDirectoryURL)
            if let directoryBackupURL, fileManager.fileExists(atPath: directoryBackupURL.path) {
                try? fileManager.moveItem(at: directoryBackupURL, to: ohMyZshDirectoryURL)
            }
            if zshrcRollbackFailed, let zshrcBackupURL {
                throw LocalOhMyZshDeployerError.rollbackZshrcFailed(backupPath: zshrcBackupURL.path)
            }
            throw error
        }

        // 成功：清理备份
        if let zshrcBackupURL {
            try? fileManager.removeItem(at: zshrcBackupURL)
        }
        if let directoryBackupURL {
            try? fileManager.removeItem(at: directoryBackupURL)
        }
    }

    /// 卸载：移除 .zshrc 区块；仅当目录由 Stacio 创建（有标记）时删除目录。
    public func remove() throws {
        // 独立重读 .zshrc（不依赖 status() 的只读降级——其解码失败会静默判无块，导致区块残留却照删目录）
        let zshrcText = try? String(contentsOf: zshrcURL, encoding: .utf8)
        if let zshrcText, OhMyZshConfigResolver.containsBlock(in: zshrcText) {
            // 读失败/解码失败必须中止（不吞错）：空串会把用户 .zshrc 覆盖为空文件
            guard let decoded = try? String(contentsOf: zshrcURL, encoding: .utf8) else {
                throw LocalOhMyZshDeployerError.zshrcDecodeFailed
            }
            let newZshrc = OhMyZshConfigResolver.removeBlock(from: decoded)
            try newZshrc.write(to: zshrcURL, atomically: true, encoding: .utf8)
        }
        let managed = fileManager.fileExists(
            atPath: ohMyZshDirectoryURL.appendingPathComponent(Self.managedMarkerFileName).path
        )
        if managed {
            try? fileManager.removeItem(at: ohMyZshDirectoryURL)
        }
    }

    // MARK: - 私有

    private func backupZshrcIfNeeded() throws -> URL? {
        guard fileManager.fileExists(atPath: zshrcURL.path) else {
            return nil
        }
        let backup = zshrcURL.deletingLastPathComponent()
            .appendingPathComponent(".zshrc.stacio-backup-\(backupSuffix())")
        try fileManager.copyItem(at: zshrcURL, to: backup)
        return backup
    }

    private func verifyInteractiveZsh() throws {
        guard let zshPath = resolveExecutable("zsh") ?? (fileManager.fileExists(atPath: "/bin/zsh") ? "/bin/zsh" : nil) else {
            throw LocalOhMyZshDeployerError.zshNotAvailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zshPath)
        process.arguments = ["-i", "-c", "echo OMZ_OK"]
        process.environment = ProcessInfo.processInfo.environment
        // 用临时文件接收输出而非 pipe：用户 .zshrc 中后台子进程若继承 stdout fd，
        // pipe 的 readDataToEndOfFile 会永久阻塞；文件读取不阻塞，进程退出后即可读取。
        // 权限 0600：文件可能含 .zshrc 校验输出（如 API_KEY=...），不得同机其他用户可读。
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("stacio-omz-verify-\(UUID().uuidString).out")
        fileManager.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        process.currentDirectoryURL = homeDirectoryURL
        try process.run()
        // 带超时的等待（用户 .zshrc 中可能有阻塞命令）
        let timeout: TimeInterval = 30
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate() // SIGTERM；若被 .zshrc 的 trap 拦截，二次 SIGKILL 兜底（不可被拦截）
            let killDeadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                // Foundation Process 无 SIGKILL API：直接 Darwin kill，SIGKILL 不可被 trap 拦截
                Darwin.kill(process.processIdentifier, SIGKILL)
                let sigkillDeadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < sigkillDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.waitUntilExit() // 理论上 SIGKILL 后必退出；兜底等待避免僵尸
                }
            }
            process.waitUntilExit()
            try? outputHandle.close()
            try? fileManager.removeItem(at: outputURL)
            throw LocalOhMyZshDeployerError.verificationTimeout
        }
        process.waitUntilExit()
        try? outputHandle.close()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        try? fileManager.removeItem(at: outputURL)
        guard process.terminationStatus == 0, output.contains("OMZ_OK") else {
            throw LocalOhMyZshDeployerError.verificationFailed(output: output)
        }
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            try fileManager.copyItem(at: item, to: target)
        }
    }

    private func resolveExecutable(_ name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func temporaryDirectoryURL() -> URL {
        fileManager.temporaryDirectory
    }

    /// 备份后缀：秒级时间戳 + 随机后缀（防同秒重试覆盖/同名冲突）。
    private func backupSuffix() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let random = UUID().uuidString.prefix(8)
        return "\(formatter.string(from: Date()))-\(random)"
    }
}

public enum LocalOhMyZshDeployerError: LocalizedError, Equatable {
    case zshNotAvailable
    case bundleUnavailable
    case verificationFailed(output: String)
    case verificationTimeout
    case zshrcDecodeFailed
    case rollbackZshrcFailed(backupPath: String)

    public var errorDescription: String? {
        switch self {
        case .zshNotAvailable:
            return "本机未安装 zsh，无法部署 Oh My Zsh。"
        case .bundleUnavailable:
            return "内置 Oh My Zsh 资源不可用，请重新安装 Stacio。"
        case let .verificationFailed(output):
            // 不展示本地原始输出（可能含用户 .zshrc 中的敏感值如 API_KEY=...）；只给固定提示
            return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Oh My Zsh 校验失败，已回滚。"
                : "Oh My Zsh 校验失败（有输出），已回滚。请在目标终端手动查看报错。"
        case .verificationTimeout:
            return "Oh My Zsh 校验超时（你的 .zshrc 中可能有阻塞命令），已回滚。"
        case .zshrcDecodeFailed:
            return "本机 .zshrc 编码解析失败，已中止部署（未改动你的配置）。"
        case let .rollbackZshrcFailed(backupPath):
            return "部署失败且 .zshrc 恢复失败。备份已保留在 \(backupPath)，请手动恢复。"
        }
    }
}
