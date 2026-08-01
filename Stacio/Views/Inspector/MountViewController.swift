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

// MARK: - 挂载状态持久化

public final class MountStore {
    private static let storageKeyPrefix = "stacio.mounts."

    private let defaults: UserDefaults
    private let sessionKey: String

    public init(sessionIdentifier: String, defaults: UserDefaults = .standard) {
        self.sessionKey = MountStore.storageKeyPrefix + sessionIdentifier
        self.defaults = defaults
    }

    public func loadEntries() -> [MountEntry] {
        guard let data = defaults.data(forKey: sessionKey) else {
            return []
        }
        return (try? JSONDecoder().decode([MountEntry].self, from: data)) ?? []
    }

    public func saveEntries(_ entries: [MountEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            return
        }
        defaults.set(data, forKey: sessionKey)
    }

    public func appendEntry(_ entry: MountEntry) {
        var entries = loadEntries()
        entries.append(entry)
        saveEntries(entries)
    }

    public func removeEntry(id: String) {
        var entries = loadEntries()
        entries.removeAll { $0.id == id }
        saveEntries(entries)
    }

    public func clearAll() {
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

    public init(
        sessionContext: TunnelLiveSessionContext?,
        remoteTerminalSender: @escaping (String) -> Void,
        appLog: StacioLogWriting? = nil
    ) {
        self.sessionContext = sessionContext
        self.remoteTerminalSender = remoteTerminalSender
        self.appLog = appLog
    }

    // MARK: - 依赖检查

    public func checkDependencies() -> (macFUSE: Bool, sshfs: Bool) {
        return (SshfsDependencyChecker.checkMacFUSE(), SshfsDependencyChecker.checkSshfs())
    }

    // MARK: - 远端 → 本地（SSHFS）

    /// 执行 SSHFS 挂载。密码通过 stdin 传入，私钥写入临时文件（权限 600）。
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

        // 构建 sshfs 参数
        var sshfsArgs: [String] = [
            target,
            expandedLocalPath,
            "-o", "StrictHostKeyChecking=no",
            "-o", "allow_other",
            "-o", "defer_permissions",
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

        switch context.secret {
        case let .password(value):
            passwordToStdin = value
            sshfsArgs.append(contentsOf: ["-o", "password_stdin"])

        case let .privateKey(privateKeyPem, passphrase):
            // 私钥写入临时文件
            tempKeyFileURL = try writeTemporaryPrivateKey(pem: privateKeyPem)
            sshfsArgs.append(contentsOf: ["-o", "IdentityFile=\(tempKeyFileURL!.path)"])
            if let passphrase, !passphrase.isEmpty {
                // sshfs 不直接支持口令，需要通过 SSH_ASKPASS 或 password_stdin 传口令
                passwordToStdin = passphrase
                sshfsArgs.append(contentsOf: ["-o", "password_stdin"])
            }

        case .agent:
            // 使用 SSH agent，无需额外凭据
            break
        }

        defer {
            if let url = tempKeyFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // 执行 sshfs 命令
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshfsPath)
        process.arguments = sshfsArgs

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

        // 等待最多 15 秒
        let timeout = Date().addingTimeInterval(15)
        while process.isRunning && Date() < timeout {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            // 进程仍在运行表示挂载成功（sshfs 是前台守护进程）
            appLog?.append(level: .info, category: "mount", message: "sshfs.started target=\(host):\(remotePath) -> \(expandedLocalPath)")
            return MountEntry(
                direction: .remoteToLocal,
                remotePath: remotePath,
                localMountPoint: expandedLocalPath,
                permission: permission,
                autoReconnect: autoReconnect,
                hostLabel: "\(user)@\(host):\(port)"
            )
        } else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            appLog?.append(level: .error, category: "mount", message: "sshfs.failed status=\(process.terminationStatus) error=\(stderrText)")
            throw MountError.mountFailed(stderrText.isEmpty ? "退出码 \(process.terminationStatus)" : stderrText)
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
            throw MountError.invalidLocalPath
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

        appLog?.append(level: .info, category: "mount", message: "local-to-remote sent: \(remoteCommand)")

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
        case .localToRemote:
            // 通过远端终端执行 umount
            remoteTerminalSender("umount \(shellEscape(entry.remotePath))\n")
            appLog?.append(level: .info, category: "mount", message: "unmount.local-to-remote sent: umount \(entry.remotePath)")
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
                appLog?.append(level: .info, category: "mount", message: "unmount.success path=\(expandedPath)")
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
            appLog?.append(level: .info, category: "mount", message: "unmount.diskutil.success path=\(expandedPath)")
        } else {
            let stderrData = diskutilPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            appLog?.append(level: .error, category: "mount", message: "unmount.failed path=\(expandedPath) error=\(stderrText)")
            throw MountError.unmountFailed(stderrText.isEmpty ? "退出码 \(diskutil.terminationStatus)" : stderrText)
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
        // 设置权限 600
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func shellEscape(_ value: String) -> String {
        // 简单的 shell 转义：用单引号包裹，内部单引号转义
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 便捷错误扩展

extension MountError {
    static var invalidLocalPath: MountError {
        return .invalidLocalMountPoint
    }
}

// MARK: - MountViewController

public final class MountViewController: NSViewController {
    private let operationRunner: MountOperationRunner
    private let mountStore: MountStore

    private var entries: [MountEntry] = []
    private var isDependenciesInstalled = true

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
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(container)
        view = container

        configureControls()
        layoutViews()
        refreshDependencies()
        refreshEntries()
    }

    // MARK: - 控件配置

    private func configureControls() {
        directionControl.target = self
        directionControl.action = #selector(directionChanged)
        directionControl.selectSegment(at: 0)
        directionControl.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSegmentedControl(directionControl)

        remotePathField.placeholderString = "/var/www"
        remotePathField.target = self
        remotePathField.action = #selector(validateInputs)
        remotePathField.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleTextField(remotePathField)

        localMountPointField.placeholderString = "~/Desktop/Remote-www"
        localMountPointField.target = self
        localMountPointField.action = #selector(validateInputs)
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
        mountButton.bezelStyle = .rounded
        mountButton.keyEquivalent = "\r"
        mountButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(mountButton)

        dependencyHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dependencyHintLabel.textColor = StacioDesignSystem.theme.warningColor
        dependencyHintLabel.lineBreakMode = .byWordWrapping
        dependencyHintLabel.maximumNumberOfLines = 3
        dependencyHintLabel.translatesAutoresizingMaskIntoConstraints = false

        installMacFUSEButton.target = self
        installMacFUSEButton.action = #selector(openMacFUSEWebsite)
        installMacFUSEButton.bezelStyle = .rounded
        installMacFUSEButton.translatesAutoresizingMaskIntoConstraints = false

        copySshfsCommandButton.target = self
        copySshfsCommandButton.action = #selector(copySshfsInstallCommand)
        copySshfsCommandButton.bezelStyle = .rounded
        copySshfsCommandButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        mountsTableView.dataSource = self
        mountsTableView.delegate = self
        mountsTableView.headerView = nil
        mountsTableView.backgroundColor = .clear
        mountsTableView.selectionHighlightStyle = .none
        mountsTableView.rowHeight = 44
        mountsTableView.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleTable(mountsTableView)

        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mount"))
        tableColumn.resizingMask = .autoresizingMask
        mountsTableView.addTableColumn(tableColumn)

        mountsScrollView.documentView = mountsTableView
        mountsScrollView.hasVerticalScroller = true
        mountsScrollView.drawsBackground = false
        mountsScrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - 布局

    private func layoutViews() {
        let titleLabel = NSTextField(labelWithString: "SSHFS 目录挂载")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let directionRow = makeRow(label: "方向", control: directionControl)
        let remotePathRow = makeRow(label: "远端路径", control: remotePathField)
        let localMountRow = makeRow(label: "本地挂载点", control: localMountPointField)
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

        let mountsTitleLabel = NSTextField(labelWithString: "当前挂载")
        mountsTitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        mountsTitleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        mountsTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            titleLabel,
            dependencyRow,
            directionRow,
            remotePathRow,
            localMountRow,
            permissionRow,
            autoReconnectRow,
            buttonRow,
            statusLabel,
            mountsTitleLabel,
            mountsScrollView
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

            remotePathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            localMountPointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            mountsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            mountsScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func makeRow(label: String, control: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        labelField.textColor = StacioDesignSystem.theme.secondaryTextColor
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

    private func refreshDependencies() {
        let (macFUSE, sshfs) = operationRunner.checkDependencies()
        isDependenciesInstalled = macFUSE && sshfs

        if isDependenciesInstalled {
            dependencyHintLabel.stringValue = ""
            installMacFUSEButton.isHidden = true
            copySshfsCommandButton.isHidden = true
            mountButton.isEnabled = true
        } else {
            var missing: [String] = []
            if !macFUSE { missing.append("macFUSE") }
            if !sshfs { missing.append("sshfs") }
            dependencyHintLabel.stringValue = "缺少依赖：\(missing.joined(separator: "、"))。请先安装后再使用挂载功能。"
            installMacFUSEButton.isHidden = macFUSE
            copySshfsCommandButton.isHidden = sshfs
            mountButton.isEnabled = false
        }
        validateInputs()
    }

    private func refreshEntries() {
        entries = mountStore.loadEntries()
        mountsTableView.reloadData()
    }

    private func validateInputs() {
        guard isDependenciesInstalled else {
            mountButton.isEnabled = false
            return
        }
        let remotePath = remotePathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let localPath = localMountPointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        mountButton.isEnabled = !remotePath.isEmpty && !localPath.isEmpty
    }

    private func updateStatusLabel(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError
            ? StacioDesignSystem.theme.dangerColor
            : StacioDesignSystem.theme.secondaryTextColor
    }

    // MARK: - 动作

    @objc private func directionChanged() {
        let isRemoteToLocal = directionControl.selectedSegment == 0
        if isRemoteToLocal {
            remotePathField.placeholderString = "/var/www"
            localMountPointField.placeholderString = "~/Desktop/Remote-www"
        } else {
            // 本地 → 远端：远端路径是远端挂载点，本地路径是 Mac 上的目录
            remotePathField.placeholderString = "/mnt/mac-share"
            localMountPointField.placeholderString = "~/Documents/Share"
        }
        validateInputs()
    }

    @objc private func validateInputs(_: Any? = nil) {
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

private final class MountTableCellView: NSTableCellView {
    private let infoLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "在 Finder 中打开", target: nil, action: nil)
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
        infoLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        infoLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(revealPressed)
        revealButton.translatesAutoresizingMaskIntoConstraints = false

        unmountButton.bezelStyle = .rounded
        unmountButton.controlSize = .small
        unmountButton.contentTintColor = StacioDesignSystem.theme.dangerColor
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

        let container = NSStackView(views: [textStack, buttonStack])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 12
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
        let directionText = entry.direction == .remoteToLocal ? "远端 → 本地" : "本地 → 远端"
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "SSHFS 目录挂载"
        sheet.contentView = controller.view
        sheet.isReleasedWhenClosed = false
        sheet.minSize = NSSize(width: 480, height: 560)

        window.beginSheet(sheet)
    }
}
