import Foundation
import StacioCoreBindings

/// 远程 SSH 会话的 oh-my-zsh 部署执行接口（可注入 mock 以便测试）。
public protocol RemoteOhMyZshCoreExecuting {
    func runRemoteCommand(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        command: String
    ) throws -> RemoteCommandResult

    func readRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        path: String
    ) throws -> String

    func writeRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        path: String,
        content: String
    ) throws

    func uploadDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        localDirectoryURL: URL,
        remotePath: String
    ) throws

    func uploadFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        localFileURL: URL,
        remotePath: String
    ) throws

    func deleteRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        path: String,
        recursive: Bool
    ) throws
}

public extension RemoteOhMyZshCoreExecuting {
    func uploadFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        localFileURL: URL,
        remotePath: String
    ) throws {
        try uploadDirectory(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            localDirectoryURL: localFileURL,
            remotePath: remotePath
        )
    }
}

public struct RemoteZshInstallationPlan: Equatable, Sendable {
    public enum PackageManager: String, Equatable, Sendable {
        case aptGet = "apt-get"
        case dnf
        case yum
        case pacman
        case zypper
        case apk
        case brew

        public var displayName: String {
            switch self {
            case .aptGet: return "Ubuntu / Debian (apt-get)"
            case .dnf: return "Fedora / RHEL (dnf)"
            case .yum: return "CentOS / RHEL (yum)"
            case .pacman: return "Arch Linux (pacman)"
            case .zypper: return "openSUSE (zypper)"
            case .apk: return "Alpine Linux (apk)"
            case .brew: return "Homebrew"
            }
        }
    }

    public enum Authorization: String, Equatable, Sendable {
        case root
        case passwordlessSudo = "sudo-n"
        case interactiveSudo = "sudo"
        case direct
        case unavailable
    }

    public let packageManager: PackageManager
    public let authorization: Authorization

    public init(packageManager: PackageManager, authorization: Authorization) {
        self.packageManager = packageManager
        self.authorization = authorization
    }

    public var requiresInteractiveAuthorization: Bool {
        authorization == .interactiveSudo
    }

    public var terminalCommand: String {
        switch authorization {
        case .root, .direct, .unavailable:
            return rootCommand
        case .passwordlessSudo, .interactiveSudo:
            return sudoCommand
        }
    }

    private var rootCommand: String {
        switch packageManager {
        case .aptGet:
            return "apt-get update && env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh"
        case .dnf:
            return "dnf install -y zsh"
        case .yum:
            return "yum install -y zsh"
        case .pacman:
            return "pacman -Sy --noconfirm zsh"
        case .zypper:
            return "zypper --non-interactive install zsh"
        case .apk:
            return "apk add zsh"
        case .brew:
            return "brew install zsh"
        }
    }

    private var sudoCommand: String {
        switch packageManager {
        case .aptGet:
            return "sudo apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh"
        case .dnf:
            return "sudo dnf install -y zsh"
        case .yum:
            return "sudo yum install -y zsh"
        case .pacman:
            return "sudo pacman -Sy --noconfirm zsh"
        case .zypper:
            return "sudo zypper --non-interactive install zsh"
        case .apk:
            return "sudo apk add zsh"
        case .brew:
            return "brew install zsh"
        }
    }
}

public enum RemoteZshInstallerError: LocalizedError, Equatable {
    case detectionFailed
    case unsupportedPackageManager
    case authorizationUnavailable

    public var errorDescription: String? {
        switch self {
        case .detectionFailed:
            return "无法检测远端系统的 zsh 安装方式。"
        case .unsupportedPackageManager:
            return "未找到受支持的远端包管理器，请手动安装 zsh。"
        case .authorizationUnavailable:
            return "当前远端账号没有可用的 root 或 sudo 权限，请联系管理员安装 zsh。"
        }
    }
}

/// Detects safe OS-aware zsh installation commands and verifies confirmed terminal installs.
public final class RemoteZshInstaller {
    private static let planMarker = "STACIO_ZSH_INSTALL_PLAN"
    private let executor: RemoteOhMyZshCoreExecuting

    public init(executor: RemoteOhMyZshCoreExecuting = LiveRemoteOhMyZshCoreExecutor()) {
        self.executor = executor
    }

    public func detectPlan(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> RemoteZshInstallationPlan? {
        let result = try executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: Self.detectionCommand
        )
        guard result.exitCode == 0 else {
            throw RemoteZshInstallerError.detectionFailed
        }
        guard let markerLine = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("\(Self.planMarker)|") })
        else {
            throw RemoteZshInstallerError.detectionFailed
        }
        let fields = markerLine.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3 else {
            throw RemoteZshInstallerError.detectionFailed
        }
        guard fields[1] != "none" else { return nil }
        guard let packageManager = RemoteZshInstallationPlan.PackageManager(rawValue: fields[1]),
              let authorization = RemoteZshInstallationPlan.Authorization(rawValue: fields[2]) else {
            throw RemoteZshInstallerError.detectionFailed
        }
        return RemoteZshInstallationPlan(
            packageManager: packageManager,
            authorization: authorization
        )
    }

    public func isZshAvailable(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> Bool {
        let result = try executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "command -v zsh >/dev/null 2>&1 && zsh --version"
        )
        return result.exitCode == 0 && result.stdout.isEmpty == false
    }

    public func consumeSuccessfulInstallationMarker(
        _ markerPath: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws -> Bool {
        guard Self.isSafeCompletionMarkerPath(markerPath) else { return false }
        let result = try executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "if test -f \(markerPath) && command -v zsh >/dev/null 2>&1; then rm -f \(markerPath); zsh --version; else exit 1; fi"
        )
        return result.exitCode == 0 && result.stdout.isEmpty == false
    }

    private static func isSafeCompletionMarkerPath(_ path: String) -> Bool {
        guard path.hasPrefix("/tmp/stacio-zsh-install-"), path.hasSuffix(".ready") else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-/.")
        return path.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static let detectionCommand = """
    manager=none
    if command -v apt-get >/dev/null 2>&1; then manager=apt-get
    elif command -v dnf >/dev/null 2>&1; then manager=dnf
    elif command -v yum >/dev/null 2>&1; then manager=yum
    elif command -v pacman >/dev/null 2>&1; then manager=pacman
    elif command -v zypper >/dev/null 2>&1; then manager=zypper
    elif command -v apk >/dev/null 2>&1; then manager=apk
    elif command -v brew >/dev/null 2>&1; then manager=brew
    fi
    authorization=unavailable
    if [ "$manager" = brew ]; then authorization=direct
    elif [ "$(id -u 2>/dev/null)" = 0 ]; then authorization=root
    elif command -v sudo >/dev/null 2>&1; then
      if sudo -n true >/dev/null 2>&1; then authorization=sudo-n
      else authorization=sudo
      fi
    fi
    printf 'STACIO_ZSH_INSTALL_PLAN|%s|%s\n' "$manager" "$authorization"
    """
}

/// 默认实现：直接桥接 CoreBridge（真实 SSH/SCP/SFTP）。
public struct LiveRemoteOhMyZshCoreExecutor: RemoteOhMyZshCoreExecuting {
    public init() {}

    public func runRemoteCommand(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        command: String
    ) throws -> RemoteCommandResult {
        try CoreBridge.runLiveRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: command
        )
    }

    public func readRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        path: String
    ) throws -> String {
        let data = try CoreBridge.readLiveRemoteFile(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: path,
            offset: 0,
            length: nil
        )
        guard let decoded = String(data: data, encoding: .utf8) else {
            // 解码失败必须抛错：回退空串会把用户真实 .zshrc 覆盖为空
            throw RemoteOhMyZshDeployerError.remoteFileDecodeFailed(path: path)
        }
        return decoded
    }

    public func writeRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        path: String,
        content: String
    ) throws {
        _ = try CoreBridge.writeLiveRemoteFile(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: path,
            contents: Data(content.utf8)
        )
    }

    public func uploadDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        localDirectoryURL: URL,
        remotePath: String
    ) throws {
        let job = ScpTransferJob(
            id: "ohmyzsh-\(UUID().uuidString)",
            direction: .upload,
            sourcePath: localDirectoryURL.path,
            destinationPath: remotePath,
            bytesTotal: 0
        )
        _ = try CoreBridge.runLiveSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job
        )
    }

    public func uploadFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        localFileURL: URL,
        remotePath: String
    ) throws {
        let job = ScpTransferJob(
            id: "ohmyzsh-archive-\(UUID().uuidString)",
            direction: .upload,
            sourcePath: localFileURL.path,
            destinationPath: remotePath,
            bytesTotal: 0
        )
        _ = try CoreBridge.runLiveSCPTransfer(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            job: job
        )
    }

    public func deleteRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        path: String,
        recursive: Bool
    ) throws {
        try CoreBridge.deleteLiveRemotePath(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            remotePath: path,
            recursive: recursive
        )
    }
}

/// 远程终端 Oh My Zsh 部署器。
///
/// 状态机：检测 zsh → 检测目录 → 压缩上传并解包（含 custom/ 保留）→ 写入 .zshrc 区块（备份）
/// → 交互式校验 → 失败回滚。卸载：移除区块；仅删除 Stacio 创建（有 .stacio-managed 标记）的目录。
///
/// 线程：同步阻塞，调用方须在后台队列执行。
public final class RemoteOhMyZshDeployer {
    public static let managedMarkerFileName = ".stacio-managed"

    private let executor: RemoteOhMyZshCoreExecuting
    private let bundleOhMyZshURL: URL?

    public init(
        executor: RemoteOhMyZshCoreExecuting = LiveRemoteOhMyZshCoreExecutor(),
        bundleOhMyZshURL: URL? = nil
    ) {
        self.executor = executor
        self.bundleOhMyZshURL = bundleOhMyZshURL
            ?? OhMyZshResourceManager.shared.installedDirectoryURL
    }

    public struct RemoteStatus: Equatable {
        public let zshAvailable: Bool
        public let directoryExists: Bool
        public let managedByStacio: Bool
        public let zshrcHasBlock: Bool

        public var isDeployed: Bool {
            zshAvailable && directoryExists && zshrcHasBlock
        }
    }

    // MARK: - 部署

    public func deploy(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        global: AppSettings
    ) throws {
        guard let bundleOhMyZshURL else {
            throw RemoteOhMyZshDeployerError.bundleUnavailable
        }
        let resolved = OhMyZshConfigResolver.resolve(global: global, session: .default)
        guard resolved.enabled else {
            try remove(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256)
            return
        }

        // 1) 检测 zsh
        let probe = try executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "command -v zsh && zsh --version"
        )
        guard probe.exitCode == 0, !probe.stdout.isEmpty else {
            throw RemoteOhMyZshDeployerError.zshNotAvailable
        }

        // Thousands of individual SCP operations are slow and prone to timing out on high-latency
        // links. Build one local archive first, then upload and extract it atomically on the host.
        let archiveURL = try makeDeploymentArchive(from: bundleOhMyZshURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let remoteArchivePath = "~/.stacio-ohmyzsh-\(UUID().uuidString.lowercased()).tar.gz"
        defer {
            _ = try? executor.runRemoteCommand(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                command: "rm -f \(remoteArchivePath) 2>/dev/null || true"
            )
        }

        // 2) 检测既有目录并整体备份（含 custom/，任一步失败可完整恢复）
        let dirCheck = try executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "test -d ~/.oh-my-zsh && echo EXISTS || echo MISSING"
        )
        let directoryExists = dirCheck.stdout.contains("EXISTS")
        let directoryBackupPath = "~/.oh-my-zsh.stacio-backup-\(backupSuffix())"
        if directoryExists {
            _ = try? executor.runRemoteCommand(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                command: "rm -rf \(directoryBackupPath) 2>/dev/null || true"
            )
            // 整体备份必须成功；失败立即中止（不进入后续可能删除原目录的回滚路径）
            let backupResult = try executor.runRemoteCommand(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                command: "mv ~/.oh-my-zsh \(directoryBackupPath)"
            )
            guard backupResult.exitCode == 0 else {
                throw RemoteOhMyZshDeployerError.directoryBackupFailed
            }
        }
        let zshrcBackupPath = "~/.zshrc.stacio-backup-\(backupSuffix())"
        // 原本是否存在 .zshrc（供回滚区分恢复/删除）；探针失败保守视为存在（true），
        // 避免误走 rm -f 分支删除用户原有 .zshrc。
        let probeResult = try? executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "test -f ~/.zshrc && echo YES || echo NO"
        )
        let hadZshrc = probeResult?.stdout.contains("YES") ?? true
        // 仅当备份写入成功（新 .zshrc 可能已被写）后才允许回滚触碰 .zshrc；
        // 部署在写 .zshrc 之前失败时（如上传中断）不得删/改用户原有 .zshrc。
        var zshrcBackupWritten = false

        do {
            // 3) 单文件上传并解压到目标目录。
            try executor.uploadFile(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                localFileURL: archiveURL,
                remotePath: remoteArchivePath
            )
            let extraction = try executor.runRemoteCommand(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                command: "mkdir -p ~/.oh-my-zsh && tar -xzf \(remoteArchivePath) -C ~/.oh-my-zsh"
            )
            guard extraction.exitCode == 0 else {
                throw RemoteOhMyZshDeployerError.archiveExtractionFailed
            }

            // 4) 恢复用户 custom/（从整体备份；失败必须抛错进回滚，避免用户自定义内容丢失且无感知）
            if directoryExists {
                // 先探测备份中是否有 custom 目录：无则跳过（对齐本地 fileExists 检查，避免 cp 源缺失误报失败）
                let customProbe = try executor.runRemoteCommand(
                    config: config,
                    secret: secret,
                    expectedFingerprintSHA256: expectedFingerprintSHA256,
                    command: "test -d \(directoryBackupPath)/custom && echo YES || echo NO"
                )
                if customProbe.stdout.contains("YES") {
                    let restore = try executor.runRemoteCommand(
                        config: config,
                        secret: secret,
                        expectedFingerprintSHA256: expectedFingerprintSHA256,
                        command: "mkdir -p ~/.oh-my-zsh/custom && cp -R \(directoryBackupPath)/custom/. ~/.oh-my-zsh/custom/"
                    )
                    guard restore.exitCode == 0 else {
                        throw RemoteOhMyZshDeployerError.customRestoreFailed
                    }
                }
            }

            // 5) 写 Stacio 管理标记
            let marker = "stacio-managed\ninstalled-at: \(ISO8601DateFormatter().string(from: Date()))\n"
            try executor.writeRemoteFile(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                path: "~/.oh-my-zsh/.stacio-managed",
                content: marker
            )

            // 6) 写入 .zshrc 区块（先备份到精确路径）
            // 先探针：远端无 .zshrc 时用空串（与本地一致），避免 SFTP 读不存在文件抛错；
            // 存在但读/解码失败必须中止（不吞错），否则空备份会覆盖用户真实配置。
            let existsProbe = try executor.runRemoteCommand(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                command: "test -f ~/.zshrc && echo YES || echo NO"
            )
            let oldZshrc: String
            if existsProbe.stdout.contains("YES") {
                oldZshrc = try executor.readRemoteFile(
                    config: config,
                    secret: secret,
                    expectedFingerprintSHA256: expectedFingerprintSHA256,
                    path: "~/.zshrc"
                )
            } else {
                oldZshrc = ""
            }
            try executor.writeRemoteFile(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                path: zshrcBackupPath,
                content: oldZshrc
            )
            zshrcBackupWritten = true
            let newZshrc = OhMyZshConfigResolver.upsertBlock(in: oldZshrc, config: resolved)
            try executor.writeRemoteFile(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                path: "~/.zshrc",
                content: newZshrc
            )

            // 7) 校验：zsh -i 加载 .zshrc 区块（带 30 秒超时；后台 sleep 重定向，避免其持有 stdout fd 导致通道 EOF 延迟）
            let verify = try executor.runRemoteCommand(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                // 校验：zsh 输出重定向到远端临时文件再 cat —— 若 .zshrc 启动的后台进程持有 stdout fd，
                // 通道 EOF 会被延迟导致 read_to_end 永久挂起；文件重定向后仅 zsh 主进程写该文件，wait 返回即可读到输出。
                command: "f=$HOME/.stacio-omz-verify-$$.out; rm -f \"$f\"; (zsh -i -c 'echo OMZ_OK' </dev/null >\"$f\" 2>&1 & p=$!; (sleep 30 >/dev/null 2>&1 && kill -- -$p 2>/dev/null || kill $p 2>/dev/null) </dev/null >/dev/null 2>&1 & wait $p; r=$?; kill -- -$p 2>/dev/null || true; cat \"$f\" 2>/dev/null; rm -f \"$f\"; exit $r)"
            )
            guard verify.exitCode == 0, verify.stdout.contains("OMZ_OK") else {
                throw RemoteOhMyZshDeployerError.verificationFailed(output: verify.stderr)
            }
        } catch {
            // 回滚：仅当备份已写入（新 .zshrc 可能已被写）才触碰 .zshrc
            var zshrcRollbackFailed = false
            if zshrcBackupWritten {
                if hadZshrc {
                    // 恢复 .zshrc；失败必须保留备份（供手动恢复），不得无条件删除
                    let restore = try? executor.runRemoteCommand(
                        config: config,
                        secret: secret,
                        expectedFingerprintSHA256: expectedFingerprintSHA256,
                        command: "cp -f \(zshrcBackupPath) ~/.zshrc"
                    )
                    if restore?.exitCode != 0 {
                        zshrcRollbackFailed = true
                    } else {
                        _ = try? executor.runRemoteCommand(
                            config: config,
                            secret: secret,
                            expectedFingerprintSHA256: expectedFingerprintSHA256,
                            command: "rm -f \(zshrcBackupPath) 2>/dev/null || true"
                        )
                    }
                } else {
                    // 原本无 .zshrc：删除新写入的（避免留下空文件）
                    _ = try? executor.runRemoteCommand(
                        config: config,
                        secret: secret,
                        expectedFingerprintSHA256: expectedFingerprintSHA256,
                        command: "rm -f ~/.zshrc 2>/dev/null || true"
                    )
                }
            }
            // 目录回滚（与 .zshrc 无关，先完成；不因 .zshrc 回滚失败而跳过，避免用户目录停留在 Stacio 新上传状态）
            if directoryExists {
                _ = try? executor.runRemoteCommand(
                    config: config,
                    secret: secret,
                    expectedFingerprintSHA256: expectedFingerprintSHA256,
                    command: "rm -rf ~/.oh-my-zsh && mv \(directoryBackupPath) ~/.oh-my-zsh"
                )
            } else {
                _ = try? executor.deleteRemotePath(
                    config: config,
                    secret: secret,
                    expectedFingerprintSHA256: expectedFingerprintSHA256,
                    path: "~/.oh-my-zsh",
                    recursive: true
                )
            }
            if zshrcRollbackFailed {
                // 备份保留：不删除 zshrcBackupPath，提示用户手动恢复（目录已回滚）
                throw RemoteOhMyZshDeployerError.rollbackZshrcFailed(backupPath: zshrcBackupPath)
            }
            throw error
        }

        // 成功：清理备份
        if directoryExists {
            _ = try? executor.runRemoteCommand(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                command: "rm -rf \(directoryBackupPath) 2>/dev/null || true"
            )
        }
        _ = try? executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "rm -f \(zshrcBackupPath) 2>/dev/null || true"
        )
    }

    // MARK: - 卸载

    public func remove(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) throws {
        // 移除区块（先探针确认存在，避免远端无 .zshrc 时 SFTP 读抛错；读失败/解码失败仍须中止）
        let existsProbe = try executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "test -f ~/.zshrc && echo YES || echo NO"
        )
        if existsProbe.stdout.contains("YES") {
            let oldZshrc = try executor.readRemoteFile(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                path: "~/.zshrc"
            )
            let newZshrc = OhMyZshConfigResolver.removeBlock(from: oldZshrc)
            if newZshrc != oldZshrc {
                try executor.writeRemoteFile(
                    config: config,
                    secret: secret,
                    expectedFingerprintSHA256: expectedFingerprintSHA256,
                    path: "~/.zshrc",
                    content: newZshrc
                )
            }
        }
        // 仅删除 Stacio 创建的目录（有标记）
        let markerProbe = try? executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "test -f ~/.oh-my-zsh/.stacio-managed && echo MANAGED || echo UNMANAGED"
        )
        if markerProbe?.stdout.contains("MANAGED") == true {
            _ = try? executor.deleteRemotePath(
                config: config,
                secret: secret,
                expectedFingerprintSHA256: expectedFingerprintSHA256,
                path: "~/.oh-my-zsh",
                recursive: true
            )
        }
    }

    // MARK: - 状态

    public func status(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String
    ) -> RemoteStatus {
        let probe = try? executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "command -v zsh"
        )
        let zshAvailable = probe?.exitCode == 0

        let dirCheck = try? executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "test -d ~/.oh-my-zsh && echo EXISTS || echo MISSING"
        )
        let directoryExists = dirCheck?.stdout.contains("EXISTS") == true

        let markerProbe = try? executor.runRemoteCommand(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            command: "test -f ~/.oh-my-zsh/.stacio-managed && echo MANAGED || echo UNMANAGED"
        )
        let managed = markerProbe?.stdout.contains("MANAGED") == true

        let zshrc = try? executor.readRemoteFile(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            path: "~/.zshrc"
        )
        let hasBlock = OhMyZshConfigResolver.containsBlock(in: zshrc ?? "")

        return RemoteStatus(
            zshAvailable: zshAvailable,
            directoryExists: directoryExists,
            managedByStacio: managed,
            zshrcHasBlock: hasBlock
        )
    }

    // MARK: - 私有

    /// 备份后缀：秒级时间戳 + 随机后缀，避免同秒重试时 rm -rf 误删上一次残留的含用户数据的备份。
    private func backupSuffix() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let random = UUID().uuidString.prefix(8)
        return "\(formatter.string(from: Date()))-\(random)"
    }

    private func makeDeploymentArchive(from directoryURL: URL) throws -> URL {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-ohmyzsh-\(UUID().uuidString.lowercased()).tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archiveURL.path, "-C", directoryURL.path, "."]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw RemoteOhMyZshDeployerError.archiveCreationFailed
        }
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: archiveURL.path) else {
            try? FileManager.default.removeItem(at: archiveURL)
            throw RemoteOhMyZshDeployerError.archiveCreationFailed
        }
        return archiveURL
    }
}

public enum RemoteOhMyZshDeployerError: LocalizedError, Equatable {
    case zshNotAvailable
    case bundleUnavailable
    case verificationFailed(output: String)
    case noActiveSession
    case directoryBackupFailed
    case customRestoreFailed
    case archiveCreationFailed
    case archiveExtractionFailed
    case remoteFileDecodeFailed(path: String)
    case rollbackZshrcFailed(backupPath: String)

    public var errorDescription: String? {
        switch self {
        case .zshNotAvailable:
            return "远程主机未安装 zsh，无法部署 Oh My Zsh。"
        case .bundleUnavailable:
            return "内置 Oh My Zsh 资源不可用，请重新安装 Stacio。"
        case let .verificationFailed(output):
            // 不展示远端原始输出（可能含用户 .zshrc 中的敏感值如 API_KEY=...）；只给固定提示
            return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "远程 Oh My Zsh 校验失败，已回滚。"
                : "远程 Oh My Zsh 校验失败（有输出），已回滚。请在目标终端手动查看报错。"
        case .noActiveSession:
            return "当前没有活动的远程 SSH 会话，无法部署。请先连接一个 SSH 会话。"
        case .directoryBackupFailed:
            return "远程原有 ~/.oh-my-zsh 目录备份失败，已中止部署（未改动你的目录）。"
        case .customRestoreFailed:
            return "远程用户自定义配置恢复失败，已回滚部署。"
        case .archiveCreationFailed:
            return "Oh My Zsh 部署包创建失败，未改动远程主机。"
        case .archiveExtractionFailed:
            return "远程 Oh My Zsh 部署包解压失败，已回滚部署。"
        case let .remoteFileDecodeFailed(path):
            return "远程文件 \(path) 编码解析失败，已中止部署（未改动你的配置）。"
        case let .rollbackZshrcFailed(backupPath):
            return "部署失败且 .zshrc 恢复失败。备份已保留在 \(backupPath)，请手动恢复。"
        }
    }
}
