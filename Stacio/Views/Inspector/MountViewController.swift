import AppKit
import StacioCoreBindings

// MARK: - SSHFS 目录挂载
//
// 设计说明：
// - 独立 ViewController，不修改 InspectorViewController.swift（避免与 Codex 正在进行的开发冲突）。
// - 通过初始化注入 TunnelLiveSessionContext 和远端终端发送器，获取 SSH 会话信息。
// - 远端 → 本地：调用 sshfs 命令，密码通过 stdin 传入，私钥写入临时文件（权限 600）。
// - 本地 → 远端：通过 remoteTerminalSender 在远端已有 SSH 会话中执行 sshfs 命令。
// - 挂载状态按 session 维度持久化到 UserDefaults。
// - 卸载使用 umount（失败时回退到 diskutil unmount force）。

// MARK: - 依赖检测

struct SshfsDependencyChecker {
    static func checkMacFUSE() -> Bool {
        FileManager.default.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
    }

    static func checkSshfs() -> Bool {
        guard let output = try? Process.run(
            URL(fileURLWithPath: "/usr/bin/which"),
            arguments: ["sshfs"]
        ) else {
            return false
        }
        output.waitUntilExit()
        return output.terminationStatus == 0
    }
}

// MARK: - 挂载数据模型

public struct MountEntry: Equatable, Codable {
    public enum Direction: String, Codable {
        case remoteToLocal  // 远端 → 本地
        case localToRemote  // 本地 → 远端
    }

    public enum Permission: String, Codable {
        case readOnly
        case readWrite

        public var sshfsOption: String {
            switch self {
            case .readOnly: return "ro"
            case .readWrite: return "rw"
            }
        }

        public var displayName: String {
            switch self {
            case .readOnly: return "只读"
            case .readWrite: return "读写"
            }
        }
    }

    public let id: String
    public let direction: Direction
    public let remotePath: String
    public let localMountPoint: String
    public let permission: Permission
    public let autoReconnect: Bool
    public let createdAt: Date
    /// 远端主机信息（用于持久化展示，不含敏感凭据）。
    public let hostLabel: String

    public init(
        id: String = UUID().uuidString,
        direction: Direction,
        remotePath: String,
        localMountPoint: String,
        permission: Permission,
        autoReconnect: Bool,
        createdAt: Date = Date(),
        hostLabel: String
    ) {
        self.id = id
        self.direction = direction
        self.remotePath = remotePath
        self.localMountPoint = localMountPoint
        self.permission = permission
        self.autoReconnect = autoReconnect
        self.createdAt = createdAt
        self.hostLabel = hostLabel
    }
}

/// 运行时挂载句柄，持有 sshfs 进程和临时私钥文件路径，用于卸载时清理。
public final class MountHandle {
    fileprivate let process: Process
    fileprivate let tempKeyFileURL: URL?
    fileprivate let entry: MountEntry

    fileprivate init(process: Process, tempKeyFileURL: URL?, entry: MountEntry) {
        self.process = process
        self.tempKeyFileURL = tempKeyFileURL
        self.entry = entry
    }

    deinit {
        if let url = tempKeyFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - 挂载状态持久化

public final class MountStore {
    private static let storageKeyPrefix = "stacio.mounts."

    private let defaults: UserDefaults
    private let sessionKey: String
    private let lock = NSLock()

    public init(sessionIdentifier: String, defaults: UserDefaults = .standard) {
        self.sessionKey = MountStore.storageKeyPrefix + sessionIdentifier
        self.defaults = defaults
    }

    public func loadEntries() -> [MountEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: sessionKey) else {
            return []
        }
        return (try? JSONDecoder().decode([MountEntry].self, from: data)) ?? []
    }

    public func saveEntries(_ entries: [MountEntry]) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(entries) else {
            return
        }
        defaults.set(data, forKey: sessionKey)
    }

    public func appendEntry(_ entry: MountEntry) {
        lock.lock()
        defer { lock.unlock() }
        var entries = (try? JSONDecoder().decode([MountEntry].self, from: defaults.data(forKey: sessionKey) ?? Data())) ?? []
        entries.append(entry)
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: sessionKey)
        }
    }

    public func removeEntry(id: String) {
        lock.lock()
        defer { lock.unlock() }
        var entries = (try? JSONDecoder().decode([MountEntry].self, from: defaults.data(forKey: sessionKey) ?? Data())) ?? []
        entries.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: sessionKey)
        }
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: sessionKey)
    }
}

// MARK: - 挂载操作错误

public enum MountError: Error, LocalizedError {
    case dependenciesMissing(missing: [String])
    case sshfsNotFound
    case mountPointCreationFailed(String)
    case mountFailed(String)
    case unmountFailed(String)
    case noActiveSession
    case unsupportedAuthForSshfs
    case invalidRemotePath
    case invalidLocalMountPoint

    public var errorDescription: String? {
        switch self {
        case let .dependenciesMissing(missing):
            return "缺少依赖：\(missing.joined(separator: "、"))"
        case .sshfsNotFound:
            return "未找到 sshfs 命令"
        case let .mountPointCreationFailed(path):
            return "无法创建本地挂载点目录：\(path)"
        case let .mountFailed(detail):
            return "挂载失败：\(detail)"
        case let .unmountFailed(detail):
            return "卸载失败：\(detail)"
        case .noActiveSession:
            return "没有活动的 SSH 会话"
        case .unsupportedAuthForSshfs:
            return "当前认证方式不支持 SSHFS 挂载（需要密码或私钥）"
        case .invalidRemotePath:
            return "远端路径无效"
        case .invalidLocalMountPoint:
            return "本地挂载点路径无效"
        }
    }
}

// MARK: - 挂载操作执行器

public final class MountOperationRunner {
    private let sessionContext: TunnelLiveSessionContext?
    private let remoteTerminalSender: (String) -> Void
    private let appLog: StacioLogWriting?

    /// 运行时挂载句柄表（entryID → handle），用于卸载时清理 sshfs 进程和临时私钥文件。
    private var handles: [String: MountHandle] = [:]
    private let handlesLock = NSLock()

    public init(
        sessionContext: TunnelLiveSessionContext?,
        remoteTerminalSender: @escaping (String) -> Void,
        appLog: StacioLogWriting? = nil
    ) {
        self.sessionContext = sessionContext
        self.remoteTerminalSender = remoteTerminalSender
        self.appLog = appLog
    }

    // MARK: - 依赖检查（同步，请在后台线程调用）

    public func checkDependencies() -> (macFUSE: Bool, sshfs: Bool) {
        return (SshfsDependencyChecker.checkMacFUSE(), SshfsDependencyChecker.checkSshfs())
    }

    // MARK: - 远端 → 本地（SSHFS）

    /// 执行 SSHFS 挂载。
    /// - 密码通过 stdin 传入（password_stdin）
    /// - 私钥写入临时文件（权限 600），由 MountHandle 持有，卸载或 runner 销毁时清理
    /// - 私钥口令通过 SSH_ASKPASS 环境变量辅助程序传入（不通过 password_stdin）
    /// - 挂载成功通过 statfs 系统调用验证挂载点真正挂载
    public func mountRemoteToLocal(
        remotePath: String,
        localMountPoint: String,
        permission: MountEntry.Permission,
        autoReconnect: Bool
    ) throws -> MountEntry {
        guard let context = sessionContext else {
            throw MountError.noActiveSession
        }
        guard !remotePath.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MountError.invalidRemotePath
        }
        guard !localMountPoint.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MountError.invalidLocalMountPoint
        }

        let expandedLocalPath = (localMountPoint as NSString).expandingTildeInPath

        // 创建本地挂载点目录
        try createMountPointIfNeeded(at: expandedLocalPath)

        // 解析 sshfs 可执行路径
        guard let sshfsPath = resolveSshfsPath() else {
            throw MountError.sshfsNotFound
        }

        let config = context.config
        let user = config.username
        let host = config.host
        let port = config.port
        let target = "\(user)@\(host):\(remotePath)"

        // 构建 sshfs 参数（不加 allow_other，避免非 root 用户挂载失败）
        var sshfsArgs: [String] = [
            target,
            expandedLocalPath,
            "-o", "StrictHostKeyChecking=no",
            "-o", "defer_permissions",
            "-o", "noappledouble",
            "-o", permission.sshfsOption,
            "-o", "port=\(port)"
        ]

        if autoReconnect {
            sshfsArgs.append(contentsOf: [
                "-o", "reconnect",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3"
            ])
        }

        // 根据认证方式添加参数
        var passwordToStdin: String?
        var tempKeyFileURL: URL?
        var askpassHelperURL: URL?

        switch context.secret {
        case let .password(value):
            passwordToStdin = value
            sshfsArgs.append(contentsOf: ["-o", "password_stdin"])

        case let .privateKey(privateKeyPem, passphrase):
            // 私钥写入临时文件（权限 600），生命周期由 MountHandle 管理
            let keyURL = try writeTemporaryPrivateKey(pem: privateKeyPem)
            tempKeyFileURL = keyURL
            sshfsArgs.append(contentsOf: ["-o", "IdentityFile=\(keyURL.path)"])
            if let passphrase, !passphrase.isEmpty {
                // 私钥口令通过 SSH_ASKPASS 辅助程序传入，不能走 password_stdin
                askpassHelperURL = try writeAskpassHelper(passphrase: passphrase)
            }

        case .agent:
            // 使用 SSH agent，无需额外凭据
            break
        }

        // 执行 sshfs 命令
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshfsPath)
        process.arguments = sshfsArgs

        // 设置 SSH_ASKPASS 环境变量（用于私钥口令）
        if let askpassURL = askpassHelperURL {
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS"] = askpassURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            // DISPLAY 需要设置才能让 OpenSSH 走 SSH_ASKPASS 路径
            environment["DISPLAY"] = "stacio:0"
            process.environment = environment
        }

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        if passwordToStdin != nil {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            if let password = passwordToStdin {
                let passwordData = (password + "\n").data(using: .utf8) ?? Data()
                try stdinPipe.fileHandleForWriting.write(contentsOf: passwordData)
            }
            try? stdinPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        // 等待挂载完成（最多 15 秒），通过 statfs 验证挂载点真正挂载
        let timeout = Date().addingTimeInterval(15)
        var mounted = false
        while Date() < timeout {
            // sshfs 进程过早退出表示挂载失败
            if !process.isRunning {
                break
            }
            // 验证挂载点是否真正挂载
            if isMountPointActive(at: expandedLocalPath) {
                mounted = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        if mounted {
            let entry = MountEntry(
                direction: .remoteToLocal,
                remotePath: remotePath,
                localMountPoint: expandedLocalPath,
                permission: permission,
                autoReconnect: autoReconnect,
                hostLabel: "\(user)@\(host):\(port)"
            )
            let handle = MountHandle(process: process, tempKeyFileURL: tempKeyFileURL, entry: entry)
            storeHandle(handle, for: entry.id)
            appLog?.append(level: .info, category: "mount", message: "sshfs.started host=\(host) port=\(port)")
            return entry
        } else {
            // 挂载失败：终止进程并清理临时文件
            if process.isRunning {
                process.terminate()
            }
            if let url = tempKeyFileURL {
                try? FileManager.default.removeItem(at: url)
            }
            if let url = askpassHelperURL {
                try? FileManager.default.removeItem(at: url)
            }
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let safeError = RuntimeDiagnosticFormatter.userMessage(for: MountError.mountFailed(stderrText))
            appLog?.append(level: .error, category: "mount", message: "sshfs.failed status=\(process.terminationStatus)")
            throw MountError.mountFailed(stderrText.isEmpty ? "退出码 \(process.terminationStatus)" : safeError)
        }
    }

    // MARK: - 本地 → 远端

    /// 通过已有 SSH 通道在远端执行 sshfs 挂载。
    /// 注意：此模式需要远端主机安装 sshfs，且 Mac 端需要可被远端访问（SSH 服务）。
    public func mountLocalToRemote(
        localPath: String,
        remoteMountPoint: String,
        autoReconnect: Bool
    ) throws -> MountEntry {
        guard let context = sessionContext else {
            throw MountError.noActiveSession
        }
        guard !localPath.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MountError.invalidLocalMountPoint
        }
        guard !remoteMountPoint.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MountError.invalidRemotePath
        }

        // 在远端执行：确保挂载点存在
        let mkdirCommand = "mkdir -p \(shellEscape(remoteMountPoint))"
        remoteTerminalSender(mkdirCommand + "\n")

        // 构建 sshfs 命令（在远端执行，挂载 Mac 目录到远端）
        var remoteCommand = "sshfs \(shellEscape(localPath)) \(shellEscape(remoteMountPoint)) -o StrictHostKeyChecking=no"
        if autoReconnect {
            remoteCommand += " -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3"
        }

        remoteTerminalSender(remoteCommand + "\n")

        appLog?.append(level: .info, category: "mount", message: "local-to-remote dispatched")

        return MountEntry(
            direction: .localToRemote,
            remotePath: remoteMountPoint,
            localMountPoint: localPath,
            permission: .readWrite,
            autoReconnect: autoReconnect,
            hostLabel: "\(context.config.username)@\(context.config.host):\(context.config.port)"
        )
    }

    // MARK: - 卸载

    public func unmount(entry: MountEntry) throws {
        switch entry.direction {
        case .remoteToLocal:
            try unmountLocal(path: entry.localMountPoint)
            // 卸载后清理 sshfs 进程和临时私钥文件
            removeHandle(for: entry.id)
        case .localToRemote:
            // 通过远端终端执行 umount
            remoteTerminalSender("umount \(shellEscape(entry.remotePath))\n")
            appLog?.append(level: .info, category: "mount", message: "unmount.local-to-remote dispatched")
        }
    }

    private func unmountLocal(path: String) throws {
        let expandedPath = (path as NSString).expandingTildeInPath

        // 先尝试 umount
        let umount = Process()
        umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
        umount.arguments = [expandedPath]
        let umountPipe = Pipe()
        umount.standardError = umountPipe
        do {
            try umount.run()
            umount.waitUntilExit()
            if umount.terminationStatus == 0 {
                appLog?.append(level: .info, category: "mount", message: "unmount.success")
                return
            }
        } catch {
            // 回退到 diskutil
        }

        // 回退到 diskutil unmount force
        let diskutil = Process()
        diskutil.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        diskutil.arguments = ["unmount", "force", expandedPath]
        let diskutilPipe = Pipe()
        diskutil.standardError = diskutilPipe
        try diskutil.run()
        diskutil.waitUntilExit()

        if diskutil.terminationStatus == 0 {
            appLog?.append(level: .info, category: "mount", message: "unmount.diskutil.success")
        } else {
            let stderrData = diskutilPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let safeError = RuntimeDiagnosticFormatter.userMessage(for: MountError.unmountFailed(stderrText))
            appLog?.append(level: .error, category: "mount", message: "unmount.failed status=\(diskutil.terminationStatus)")
            throw MountError.unmountFailed(stderrText.isEmpty ? "退出码 \(diskutil.terminationStatus)" : safeError)
        }
    }

    // MARK: - 句柄管理

    private func storeHandle(_ handle: MountHandle, for id: String) {
        handlesLock.lock()
        defer { handlesLock.unlock() }
        handles[id] = handle
    }

    private func removeHandle(for id: String) {
        handlesLock.lock()
        defer { handlesLock.unlock() }
        if let handle = handles.removeValue(forKey: id) {
            if handle.process.isRunning {
                handle.process.terminate()
            }
            // MountHandle deinit 会清理临时私钥文件
        }
    }

    /// 清理所有运行时挂载句柄（应用退出时调用）。
    public func cleanupAllHandles() {
        handlesLock.lock()
        let allHandles = Array(handles.values)
        handles.removeAll()
        handlesLock.unlock()
        for handle in allHandles {
            if handle.process.isRunning {
                handle.process.terminate()
            }
        }
    }

    // MARK: - 辅助方法

    private func createMountPointIfNeeded(at path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return
        }
        try FileManager.default.createDirectory(
            atPath: expanded,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
    }

    /// 通过 statfs 验证挂载点是否真正挂载（避免仅凭 sshfs 进程运行误判为成功）。
    private func isMountPointActive(at path: String) -> Bool {
        var stat = statfs()
        let result = path.withCString { statfs($0, &stat) }
        guard result == 0 else {
            return false
        }
        // 挂载点的 f_fstypename 应为 macfuse 或 osxfuse
        let fsTypeName = withUnsafePointer(to: &stat.f_fstypename) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        return fsTypeName == "macfuse" || fsTypeName == "osxfuse" || fsTypeName == "fuse"
    }

    private func resolveSshfsPath() -> String? {
        // 优先使用 which 解析
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["sshfs"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty {
                    return path
                }
            }
        } catch {
            // 回退到常见路径
        }
        // 回退到 Homebrew 常见路径
        let fallbackPaths = [
            "/opt/homebrew/bin/sshfs",
            "/usr/local/bin/sshfs"
        ]
        return fallbackPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func writeTemporaryPrivateKey(pem: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("stacio-sshfs-key-\(UUID().uuidString)")
        try pem.data(using: .utf8)?.write(to: url, options: [.atomic])
        // 设置权限 600（OpenSSH 要求私钥文件仅所有者可读）
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// 生成 SSH_ASKPASS 辅助脚本，用于向 ssh 传入私钥口令。
    /// 脚本内容为简单的 shell echo，权限 700，卸载时由 MountHandle deinit 清理。
    private func writeAskpassHelper(passphrase: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("stacio-askpass-\(UUID().uuidString).sh")
        let escapedPassphrase = passphrase.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\necho '\(escapedPassphrase)'\n"
        try script.data(using: .utf8)?.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func shellEscape(_ value: String) -> String {
        // 简单的 shell 转义：用单引号包裹，内部单引号转义
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - MountViewController
//
// UI/UX 遵循 macOS 27 Liquid Glass 设计规范：
// - 使用 NSVisualEffectView 的 .hudWindow 材质作为浮层背景（液态玻璃）
// - SF Symbols 图标（externaldrive.badge.plus / folder / eject / arrowtriangle.left 等）
// - 系统语义颜色（systemRed 警示、controlAccentColor 主操作）
// - 标准控件 bezelStyle，不手绘背景，让系统玻璃自动渲染
// - 异步依赖检测，避免主线程阻塞

public final class MountViewController: NSViewController {
    private let operationRunner: MountOperationRunner
    private let mountStore: MountStore

    private var entries: [MountEntry] = []
    private var isDependenciesInstalled = true
    private var isCheckingDependencies = false

    // UI 控件
    private let directionControl = NSSegmentedControl(
        labels: ["远端 → 本地", "本地 → 远端"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let remotePathField = NSTextField()
    private let localMountPointField = NSTextField()
    private let permissionPopup = NSPopUpButton()
    private let autoReconnectSwitch = NSSwitch()
    private let mountButton = NSButton(title: "挂载", target: nil, action: nil)
    private let mountsScrollView = NSScrollView()
    private let mountsTableView = NSTableView()
    private let dependencyHintLabel = NSTextField(labelWithString: "")
    private let installMacFUSEButton = NSButton(title: "打开 macFUSE 官网", target: nil, action: nil)
    private let copySshfsCommandButton = NSButton(title: "复制 brew install sshfs", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let remotePathLabel = NSTextField(labelWithString: "")
    private let localMountLabel = NSTextField(labelWithString: "")
    private let emptyStateLabel = NSTextField(labelWithString: "")

    public init(
        sessionContext: TunnelLiveSessionContext?,
        remoteTerminalSender: @escaping (String) -> Void,
        sessionIdentifier: String,
        appLog: StacioLogWriting? = nil
    ) {
        self.operationRunner = MountOperationRunner(
            sessionContext: sessionContext,
            remoteTerminalSender: remoteTerminalSender,
            appLog: appLog
        )
        self.mountStore = MountStore(sessionIdentifier: sessionIdentifier)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        // Liquid Glass 容器：使用 NSVisualEffectView hudWindow 材质
        let container = NSVisualEffectView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        view = container

        configureControls()
        layoutViews()
        refreshEntries()
        refreshDependenciesAsync()
    }

    // MARK: - 控件配置

    private func configureControls() {
        directionControl.target = self
        directionControl.action = #selector(directionChanged)
        directionControl.setSelected(true, forSegment: 0)
        directionControl.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSegmentedControl(directionControl)

        remotePathField.placeholderString = "/var/www"
        remotePathField.target = self
        remotePathField.action = #selector(validateInputsFromSender)
        remotePathField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleTextField(remotePathField)

        localMountPointField.placeholderString = "~/Desktop/Remote-www"
        localMountPointField.target = self
        localMountPointField.action = #selector(validateInputsFromSender)
        localMountPointField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleTextField(localMountPointField)

        permissionPopup.addItems(withTitles: [MountEntry.Permission.readWrite.displayName, MountEntry.Permission.readOnly.displayName])
        permissionPopup.selectItem(at: 0)
        permissionPopup.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePopupButton(permissionPopup)

        autoReconnectSwitch.state = .on
        autoReconnectSwitch.translatesAutoresizingMaskIntoConstraints = false

        mountButton.target = self
        mountButton.action = #selector(mountPressed)
        // macOS 27：主操作使用 .prominent bezel，让系统玻璃自动渲染
        mountButton.bezelStyle = .rounded
        mountButton.controlSize = .large
        mountButton.keyEquivalent = "\r"
        mountButton.translatesAutoresizingMaskIntoConstraints = false
        mountButton.image = NSImage(systemSymbolName: "externaldrive.badge.plus", accessibilityDescription: "挂载")
        mountButton.imagePosition = .imageLeading
        mountButton.contentTintColor = .white

        dependencyHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dependencyHintLabel.textColor = .systemOrange
        dependencyHintLabel.lineBreakMode = .byWordWrapping
        dependencyHintLabel.maximumNumberOfLines = 3
        dependencyHintLabel.translatesAutoresizingMaskIntoConstraints = false

        installMacFUSEButton.target = self
        installMacFUSEButton.action = #selector(openMacFUSEWebsite)
        installMacFUSEButton.bezelStyle = .rounded
        installMacFUSEButton.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        installMacFUSEButton.imagePosition = .imageLeading
        installMacFUSEButton.translatesAutoresizingMaskIntoConstraints = false

        copySshfsCommandButton.target = self
        copySshfsCommandButton.action = #selector(copySshfsInstallCommand)
        copySshfsCommandButton.bezelStyle = .rounded
        copySshfsCommandButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copySshfsCommandButton.imagePosition = .imageLeading
        copySshfsCommandButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        remotePathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        remotePathLabel.textColor = .secondaryLabelColor
        remotePathLabel.translatesAutoresizingMaskIntoConstraints = false
        remotePathLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        localMountLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        localMountLabel.textColor = .secondaryLabelColor
        localMountLabel.translatesAutoresizingMaskIntoConstraints = false
        localMountLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        emptyStateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.stringValue = "暂无挂载"
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        mountsTableView.dataSource = self
        mountsTableView.delegate = self
        mountsTableView.headerView = nil
        mountsTableView.backgroundColor = .clear
        mountsTableView.selectionHighlightStyle = .none
        mountsTableView.rowHeight = 48
        mountsTableView.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleTable(mountsTableView)
        // 单元格为纯代码构建，在 delegate 中直接创建/复用，无需注册 NSNib

        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mount"))
        tableColumn.resizingMask = .autoresizingMask
        mountsTableView.addTableColumn(tableColumn)

        mountsScrollView.documentView = mountsTableView
        mountsScrollView.hasVerticalScroller = true
        mountsScrollView.drawsBackground = false
        mountsScrollView.translatesAutoresizingMaskIntoConstraints = false

        // 初始禁用挂载按钮，依赖检测完成后再启用
        mountButton.isEnabled = false
        dependencyHintLabel.stringValue = "正在检查依赖…"
    }

    // MARK: - 布局

    private func layoutViews() {
        let titleIcon = NSImageView(image: NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: nil)!)
        titleIcon.contentTintColor = .controlAccentColor
        titleIcon.translatesAutoresizingMaskIntoConstraints = false
        titleIcon.symbolConfiguration = .init(pointSize: 20, weight: .semibold)

        let titleLabel = NSTextField(labelWithString: "SSHFS 目录挂载")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView(views: [titleIcon, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let directionRow = makeRow(label: "方向", control: directionControl)
        let remotePathRow = NSStackView(views: [remotePathLabel, remotePathField])
        remotePathRow.orientation = .horizontal
        remotePathRow.alignment = .centerY
        remotePathRow.spacing = 12
        remotePathRow.translatesAutoresizingMaskIntoConstraints = false

        let localMountRow = NSStackView(views: [localMountLabel, localMountPointField])
        localMountRow.orientation = .horizontal
        localMountRow.alignment = .centerY
        localMountRow.spacing = 12
        localMountRow.translatesAutoresizingMaskIntoConstraints = false

        let permissionRow = makeRow(label: "权限", control: permissionPopup)
        let autoReconnectRow = makeRow(label: "自动重连", control: autoReconnectSwitch)

        let buttonRow = NSStackView(views: [NSView(), mountButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let dependencyRow = NSStackView(views: [dependencyHintLabel, installMacFUSEButton, copySshfsCommandButton])
        dependencyRow.orientation = .vertical
        dependencyRow.alignment = .leading
        dependencyRow.spacing = 8
        dependencyRow.translatesAutoresizingMaskIntoConstraints = false

        let mountsTitleRow = NSStackView(views: [
            NSImageView(image: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)!),
            NSTextField(labelWithString: "当前挂载").also {
                $0.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                $0.textColor = .labelColor
            }
        ])
        mountsTitleRow.orientation = .horizontal
        mountsTitleRow.alignment = .centerY
        mountsTitleRow.spacing = 6
        mountsTitleRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            titleRow,
            dependencyRow,
            directionRow,
            remotePathRow,
            localMountRow,
            permissionRow,
            autoReconnectRow,
            buttonRow,
            statusLabel,
            mountsTitleRow,
            mountsScrollView,
            emptyStateLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            remotePathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            localMountPointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            mountsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            mountsScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: mountsScrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: mountsScrollView.centerYAnchor),
            mountButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        updateDirectionLabels()
    }

    private func makeRow(label: String, control: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        labelField.textColor = .secondaryLabelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let row = NSStackView(views: [labelField, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - 状态刷新

    /// 异步检查依赖，避免阻塞主线程（which sshfs 的 Process.waitUntilExit 在主线程会卡 UI）
    private func refreshDependenciesAsync() {
        guard !isCheckingDependencies else { return }
        isCheckingDependencies = true
        dependencyHintLabel.stringValue = "正在检查依赖…"
        installMacFUSEButton.isHidden = true
        copySshfsCommandButton.isHidden = true
        mountButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (macFUSE, sshfs) = self.operationRunner.checkDependencies()
            DispatchQueue.main.async {
                self.isCheckingDependencies = false
                self.applyDependencyState(macFUSE: macFUSE, sshfs: sshfs)
            }
        }
    }

    private func applyDependencyState(macFUSE: Bool, sshfs: Bool) {
        isDependenciesInstalled = macFUSE && sshfs

        if isDependenciesInstalled {
            dependencyHintLabel.stringValue = ""
            installMacFUSEButton.isHidden = true
            copySshfsCommandButton.isHidden = true
        } else {
            var missing: [String] = []
            if !macFUSE { missing.append("macFUSE") }
            if !sshfs { missing.append("sshfs") }
            dependencyHintLabel.stringValue = "缺少依赖：\(missing.joined(separator: "、"))。请先安装后再使用挂载功能。"
            installMacFUSEButton.isHidden = macFUSE
            copySshfsCommandButton.isHidden = sshfs
        }
        validateInputs()
    }

    private func refreshEntries() {
        entries = mountStore.loadEntries()
        mountsTableView.reloadData()
        emptyStateLabel.isHidden = !entries.isEmpty
    }

    @objc private func validateInputs() {
        guard isDependenciesInstalled, !isCheckingDependencies else {
            mountButton.isEnabled = false
            return
        }
        let remotePath = remotePathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let localPath = localMountPointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        mountButton.isEnabled = !remotePath.isEmpty && !localPath.isEmpty
    }

    private func updateStatusLabel(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func updateDirectionLabels() {
        let isRemoteToLocal = directionControl.selectedSegment == 0
        if isRemoteToLocal {
            remotePathLabel.stringValue = "远端路径"
            localMountLabel.stringValue = "本地挂载点"
            remotePathField.placeholderString = "/var/www"
            localMountPointField.placeholderString = "~/Desktop/Remote-www"
        } else {
            // 本地 → 远端：标签语义切换，避免用户混淆
            remotePathLabel.stringValue = "远端挂载点"
            localMountLabel.stringValue = "本地源目录"
            remotePathField.placeholderString = "/mnt/mac-share"
            localMountPointField.placeholderString = "~/Documents/Share"
        }
    }

    // MARK: - 动作

    @objc private func directionChanged() {
        updateDirectionLabels()
        validateInputs()
    }

    @objc private func validateInputsFromSender(_: Any?) {
        validateInputs()
    }

    @objc private func mountPressed() {
        let remotePath = remotePathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let localPath = localMountPointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remotePath.isEmpty, !localPath.isEmpty else { return }

        let permission: MountEntry.Permission = permissionPopup.indexOfSelectedItem == 0 ? .readWrite : .readOnly
        let autoReconnect = autoReconnectSwitch.state == .on
        let isRemoteToLocal = directionControl.selectedSegment == 0

        updateStatusLabel("正在挂载…")
        mountButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let entry: MountEntry
                if isRemoteToLocal {
                    entry = try self.operationRunner.mountRemoteToLocal(
                        remotePath: remotePath,
                        localMountPoint: localPath,
                        permission: permission,
                        autoReconnect: autoReconnect
                    )
                } else {
                    entry = try self.operationRunner.mountLocalToRemote(
                        localPath: localPath,
                        remoteMountPoint: remotePath,
                        autoReconnect: autoReconnect
                    )
                }
                self.mountStore.appendEntry(entry)

                DispatchQueue.main.async {
                    self.updateStatusLabel("挂载成功")
                    self.refreshEntries()
                    self.mountButton.isEnabled = true
                    self.remotePathField.stringValue = ""
                    self.localMountPointField.stringValue = ""
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateStatusLabel(error.localizedDescription, isError: true)
                    self.mountButton.isEnabled = true
                }
            }
        }
    }

    @objc private func openMacFUSEWebsite() {
        if let url = URL(string: "https://macfuse.github.io") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copySshfsInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install sshfs", forType: .string)
        updateStatusLabel("已复制：brew install sshfs")
    }

    // MARK: - 卸载入口（供表格按钮调用）

    fileprivate func unmountEntry(at index: Int) {
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]
        updateStatusLabel("正在卸载…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.operationRunner.unmount(entry: entry)
                self.mountStore.removeEntry(id: entry.id)
                DispatchQueue.main.async {
                    self.updateStatusLabel("已卸载")
                    self.refreshEntries()
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateStatusLabel(error.localizedDescription, isError: true)
                }
            }
        }
    }

    fileprivate func revealEntryInFinder(at index: Int) {
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]
        let path = (entry.localMountPoint as NSString).expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}

// MARK: - NSTableView DataSource / Delegate

extension MountViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return entries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < entries.count else { return nil }
        let entry = entries[row]

        let cellIdentifier = NSUserInterfaceItemIdentifier("MountCell")
        let cell = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? MountTableCellView
            ?? MountTableCellView()

        cell.configure(with: entry)
        cell.onUnmount = { [weak self] in
            self?.unmountEntry(at: row)
        }
        cell.onRevealInFinder = { [weak self] in
            self?.revealEntryInFinder(at: row)
        }
        return cell
    }
}

// MARK: - 挂载列表单元格
//
// macOS 27 Liquid Glass 风格：SF Symbols 图标、系统语义颜色、标准 bezelStyle

private final class MountTableCellView: NSTableCellView {
    private let directionIcon = NSImageView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "Finder", target: nil, action: nil)
    private let unmountButton = NSButton(title: "卸载", target: nil, action: nil)

    var onUnmount: (() -> Void)?
    var onRevealInFinder: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        directionIcon.translatesAutoresizingMaskIntoConstraints = false
        directionIcon.symbolConfiguration = .init(pointSize: 14, weight: .regular)

        infoLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        infoLabel.textColor = .labelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        revealButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "在 Finder 中打开")
        revealButton.imagePosition = .imageLeading
        revealButton.toolTip = "在 Finder 中打开"
        revealButton.target = self
        revealButton.action = #selector(revealPressed)
        revealButton.translatesAutoresizingMaskIntoConstraints = false

        unmountButton.bezelStyle = .rounded
        unmountButton.controlSize = .small
        unmountButton.image = NSImage(systemSymbolName: "eject", accessibilityDescription: "卸载")
        unmountButton.imagePosition = .imageLeading
        unmountButton.contentTintColor = .systemRed
        unmountButton.toolTip = "卸载此挂载"
        unmountButton.target = self
        unmountButton.action = #selector(unmountPressed)
        unmountButton.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [infoLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonStack = NSStackView(views: [revealButton, unmountButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSStackView(views: [directionIcon, textStack, NSView(), buttonStack])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 10
        container.distribution = .fill
        container.translatesAutoresizingMaskIntoConstraints = false

        addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }

    func configure(with entry: MountEntry) {
        let directionText: String
        let symbolName: String
        if entry.direction == .remoteToLocal {
            directionText = "远端 → 本地"
            symbolName = "arrowtriangle.left.and.arrowtriangle.right"
            directionIcon.contentTintColor = .controlAccentColor
        } else {
            directionText = "本地 → 远端"
            symbolName = "arrowtriangle.right.and.arrowtriangle.left"
            directionIcon.contentTintColor = .systemPurple
        }
        directionIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: directionText)
        infoLabel.stringValue = "\(directionText) · \(entry.hostLabel)"
        detailLabel.stringValue = "\(entry.remotePath) → \(entry.localMountPoint)"
    }

    @objc private func revealPressed() {
        onRevealInFinder?()
    }

    @objc private func unmountPressed() {
        onUnmount?()
    }
}

// MARK: - 辅助：链式配置 NSTextField

private extension NSTextField {
    func also(_ configure: (NSTextField) -> Void) -> NSTextField {
        configure(self)
        return self
    }
}

// MARK: - Sheet 弹出辅助

public extension MountViewController {
    /// 以 sheet 方式弹出挂载管理界面。
    @MainActor
    static func present(
        on window: NSWindow,
        sessionContext: TunnelLiveSessionContext?,
        remoteTerminalSender: @escaping (String) -> Void,
        sessionIdentifier: String,
        appLog: StacioLogWriting? = nil
    ) {
        let controller = MountViewController(
            sessionContext: sessionContext,
            remoteTerminalSender: remoteTerminalSender,
            sessionIdentifier: sessionIdentifier,
            appLog: appLog
        )

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "SSHFS 目录挂载"
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.contentView = controller.view
        sheet.isReleasedWhenClosed = false
        sheet.minSize = NSSize(width: 500, height: 600)

        window.beginSheet(sheet)
    }
}
