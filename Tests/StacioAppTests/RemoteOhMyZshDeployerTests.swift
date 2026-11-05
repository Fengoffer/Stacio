import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

/// 内存 mock：模拟远程主机文件系统与命令执行。
private final class MockRemoteExecutor: RemoteOhMyZshCoreExecuting {
    var remoteFiles: [String: String] = [:]
    var remoteDirs: Set<String> = []
    var zshAvailable = true
    var verifySucceeds = true
    var extractionSucceeds = true
    var zshInstallPackageManager = "apt-get"
    var zshInstallAuthorization = "root"
    var zshInstallMarkerReady = false
    var uploadedDirectories: [String] = []
    var commands: [String] = []

    func runRemoteCommand(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        command: String
    ) throws -> RemoteCommandResult {
        commands.append(command)
        if command.contains("test -f /tmp/stacio-zsh-install-") {
            let ready = zshInstallMarkerReady && zshAvailable
            zshInstallMarkerReady = false
            return RemoteCommandResult(
                exitCode: ready ? 0 : 1,
                stdout: ready ? "zsh 5.9\n" : "",
                stderr: ""
            )
        }
        if command.contains("command -v zsh") {
            return RemoteCommandResult(
                exitCode: zshAvailable ? 0 : 127,
                stdout: zshAvailable ? "/usr/bin/zsh\n" : "",
                stderr: zshAvailable ? "" : "zsh: command not found"
            )
        }
        if command.contains("STACIO_ZSH_INSTALL_PLAN") {
            return RemoteCommandResult(
                exitCode: 0,
                stdout: "STACIO_ZSH_INSTALL_PLAN|\(zshInstallPackageManager)|\(zshInstallAuthorization)\n",
                stderr: ""
            )
        }
        if command.contains("tar -xzf ") && command.contains("-C ~/.oh-my-zsh") {
            guard extractionSucceeds else {
                return RemoteCommandResult(exitCode: 2, stdout: "", stderr: "tar failed")
            }
            remoteDirs.insert("~/.oh-my-zsh")
            remoteFiles["~/.oh-my-zsh/oh-my-zsh.sh"] = "# fake"
            return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        if command == "test -d ~/.oh-my-zsh && echo EXISTS || echo MISSING" {
            return RemoteCommandResult(
                exitCode: 0,
                stdout: remoteDirs.contains("~/.oh-my-zsh") ? "EXISTS\n" : "MISSING\n",
                stderr: ""
            )
        }
        if command.contains("test -d ~/.oh-my-zsh.stacio-backup-") && command.contains("/custom") {
            // custom 探针：检查备份目录中是否有 custom（精确匹配，避免被 test -d ~/.oh-my-zsh 前缀拦截）
            let hasCustom = remoteDirs.contains { $0.hasPrefix("~/.oh-my-zsh.stacio-backup-") && $0.hasSuffix("/custom") }
                || remoteFiles.keys.contains { $0.contains("stacio-backup-") && $0.contains("/custom/") }
            return RemoteCommandResult(
                exitCode: 0,
                stdout: hasCustom ? "YES\n" : "NO\n",
                stderr: ""
            )
        }
        if command.contains("test -f ~/.oh-my-zsh/.stacio-managed") {
            let managed = remoteFiles["~/.oh-my-zsh/.stacio-managed"] != nil
            return RemoteCommandResult(
                exitCode: 0,
                stdout: managed ? "MANAGED\n" : "UNMANAGED\n",
                stderr: ""
            )
        }
        if command.hasPrefix("mv ~/.oh-my-zsh ") {
            // 模拟整体目录备份
            let backup = command.dropFirst("mv ~/.oh-my-zsh ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if remoteDirs.contains("~/.oh-my-zsh") {
                remoteDirs.remove("~/.oh-my-zsh")
                remoteDirs.insert(String(backup))
                // 移动目录内文件（backup 需带尾斜杠拼接）
                let prefix = "~/.oh-my-zsh/"
                for (path, content) in remoteFiles where path.hasPrefix(prefix) {
                    remoteFiles[String(backup) + "/" + path.dropFirst(prefix.count)] = content
                    remoteFiles[path] = nil
                }
                return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
            return RemoteCommandResult(exitCode: 1, stdout: "", stderr: "mv: no such file")
        }
        if command.contains("rm -rf ~/.oh-my-zsh && mv") {
            // 回滚：先删除本次上传的新目录（含文件），再完整恢复备份目录（含文件）
            for path in Array(remoteFiles.keys) where path.hasPrefix("~/.oh-my-zsh/") {
                remoteFiles[path] = nil
            }
            remoteDirs.remove("~/.oh-my-zsh")
            if let backup = remoteDirs.first(where: { $0.hasPrefix("~/.oh-my-zsh.stacio-backup-") }) {
                remoteDirs.remove(backup)
                remoteDirs.insert("~/.oh-my-zsh")
                let prefix = backup + "/"
                for (path, content) in remoteFiles where path.hasPrefix(prefix) {
                    remoteFiles["~/.oh-my-zsh/" + path.dropFirst(prefix.count)] = content
                    remoteFiles[path] = nil
                }
            }
            return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        if command.hasPrefix("mv ~/.oh-my-zsh.stacio-backup-") {
            // 独立 mv 恢复（无 rm 前缀）
            if let backup = remoteDirs.first(where: { $0.hasPrefix("~/.oh-my-zsh.stacio-backup-") }) {
                remoteDirs.remove(backup)
                remoteDirs.insert("~/.oh-my-zsh")
                let prefix = backup + "/"
                for (path, content) in remoteFiles where path.hasPrefix(prefix) {
                    remoteFiles["~/.oh-my-zsh/" + path.dropFirst(prefix.count)] = content
                    remoteFiles[path] = nil
                }
            }
            return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        if command.contains("rm -rf ~/.oh-my-zsh.stacio-backup-") {
            // 只删除备份目录（含文件），不影响 ~/.oh-my-zsh 本身
            for dir in Array(remoteDirs) where dir.hasPrefix("~/.oh-my-zsh.stacio-backup-") {
                remoteDirs.remove(dir)
            }
            for path in Array(remoteFiles.keys) where path.hasPrefix("~/.oh-my-zsh.stacio-backup-") {
                remoteFiles[path] = nil
            }
            return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        if command == "rm -rf ~/.oh-my-zsh" {
            remoteDirs.remove("~/.oh-my-zsh")
            for path in Array(remoteFiles.keys) where path.hasPrefix("~/.oh-my-zsh/") {
                remoteFiles[path] = nil
            }
            return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        if command.contains("rm -f ~/.zshrc.stacio-backup-") {
            // 只删除 .zshrc 备份文件，不影响目录备份（~/.oh-my-zsh.stacio-backup-*）下的用户文件
            for path in Array(remoteFiles.keys) where path.hasPrefix("~/.zshrc.stacio-backup-") {
                remoteFiles[path] = nil
            }
            return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        if command.hasPrefix("cp -f ") {
            // 回滚 .zshrc：cp -f <src> <dst>（-f 是标志，src/dst 从 args[2]/args[3] 取）
            let args = command.split(separator: " ").map(String.init)
            if args.count >= 4, let content = remoteFiles[args[2]] {
                remoteFiles[args[3]] = content
            }
            return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        if command.contains("cp -R ") && command.contains("custom/.") {
            // custom 恢复：cp -R <backup>/custom/. ~/.oh-my-zsh/custom/
            let marker = "/custom/."
            if let backup = remoteDirs.first(where: { $0.hasPrefix("~/.oh-my-zsh.stacio-backup-") }) {
                let sourcePrefix = backup + "/custom/"
                for (path, content) in remoteFiles where path.hasPrefix(sourcePrefix) {
                    let relative = String(path.dropFirst(sourcePrefix.count))
                    remoteFiles["~/.oh-my-zsh/custom/" + relative] = content
                }
            }
            _ = marker
            return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        if command.contains("test -f ~/.zshrc && echo YES || echo NO") {
            let exists = remoteFiles["~/.zshrc"] != nil
            return RemoteCommandResult(
                exitCode: 0,
                stdout: exists ? "YES\n" : "NO\n",
                stderr: ""
            )
        }
        if command.contains("rm -f ~/.zshrc ") || command == "rm -f ~/.zshrc" {
            remoteFiles["~/.zshrc"] = nil
            return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        if command.contains("echo OMZ_OK") {
            return RemoteCommandResult(
                exitCode: verifySucceeds ? 0 : 1,
                stdout: verifySucceeds ? "OMZ_OK\n" : "",
                stderr: verifySucceeds ? "" : "boom"
            )
        }
        // 文件操作命令（cp/rm）视为成功
        return RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func readRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        path: String
    ) throws -> String {
        // 缺失路径抛错（对齐真实 Live SFTP 行为），避免测试掩盖"无探针读不存在文件"缺陷
        guard let content = remoteFiles[path] else {
            throw RemoteOhMyZshDeployerError.bundleUnavailable
        }
        return content
    }

    func writeRemoteFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        path: String,
        content: String
    ) throws {
        remoteFiles[path] = content
    }

    func uploadDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        localDirectoryURL: URL,
        remotePath: String
    ) throws {
        uploadedDirectories.append(remotePath)
        remoteDirs.insert(remotePath)
        remoteFiles["\(remotePath)/oh-my-zsh.sh"] = "# fake"
    }

    func uploadFile(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        localFileURL: URL,
        remotePath: String
    ) throws {
        uploadedDirectories.append(remotePath)
        remoteFiles[remotePath] = "archive"
    }

    func deleteRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        path: String,
        recursive: Bool
    ) throws {
        remoteFiles[path] = nil
        remoteDirs.remove(path)
    }
}

final class RemoteOhMyZshDeployerTests: XCTestCase {
    private var config: SshConnectionConfig!
    private var secret: SshAuthSecret!
    private var bundleURL: URL!

    override func setUpWithError() throws {
        config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "root",
            authMethod: .agent,
            connectTimeoutMs: 5_000
        )
        secret = .agent
        bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "# fake".write(
            to: bundleURL.appendingPathComponent("oh-my-zsh.sh"),
            atomically: true,
            encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundleURL)
    }

    private func makeSettings() -> AppSettings {
        var settings = AppSettings()
        settings.ohmyzshEnabled = true
        settings.ohmyzshTheme = "robbyrussell"
        settings.ohmyzshPlugins = ["git"]
        return settings
    }

    func testDeployRunsFullStateMachine() throws {
        let mock = MockRemoteExecutor()
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        try deployer.deploy(config: config, secret: secret, expectedFingerprintSHA256: "", global: makeSettings())

        XCTAssertTrue(mock.uploadedDirectories.contains { $0.hasPrefix("~/.stacio-ohmyzsh-") })
        XCTAssertTrue(mock.commands.contains { $0.contains("tar -xzf ") })
        XCTAssertNotNil(mock.remoteFiles["~/.oh-my-zsh/.stacio-managed"])
        let zshrc = mock.remoteFiles["~/.zshrc"] ?? ""
        XCTAssertTrue(OhMyZshConfigResolver.containsBlock(in: zshrc))
        XCTAssertTrue(zshrc.contains("ZSH_THEME=\"robbyrussell\""))
        XCTAssertTrue(mock.commands.contains { $0.contains("echo OMZ_OK") })
    }

    func testDeployRejectsMissingZsh() {
        let mock = MockRemoteExecutor()
        mock.zshAvailable = false
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        XCTAssertThrowsError(try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        )) { error in
            XCTAssertEqual(error as? RemoteOhMyZshDeployerError, .zshNotAvailable)
        }
        XCTAssertTrue(mock.uploadedDirectories.isEmpty, "zsh 缺失时不得上传")
    }

    func testZshInstallerDetectsRootAptPlan() throws {
        let mock = MockRemoteExecutor()
        mock.zshInstallPackageManager = "apt-get"
        mock.zshInstallAuthorization = "root"
        let installer = RemoteZshInstaller(executor: mock)

        let plan = try XCTUnwrap(installer.detectPlan(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: ""
        ))

        XCTAssertEqual(plan.packageManager, .aptGet)
        XCTAssertEqual(plan.authorization, .root)
        XCTAssertFalse(plan.requiresInteractiveAuthorization)
        XCTAssertEqual(
            plan.terminalCommand,
            "apt-get update && env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh"
        )
    }

    func testZshInstallerBuildsInteractiveSudoCommand() throws {
        let mock = MockRemoteExecutor()
        mock.zshInstallPackageManager = "dnf"
        mock.zshInstallAuthorization = "sudo"
        let installer = RemoteZshInstaller(executor: mock)

        let plan = try XCTUnwrap(installer.detectPlan(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: ""
        ))

        XCTAssertEqual(plan.packageManager, .dnf)
        XCTAssertEqual(plan.authorization, .interactiveSudo)
        XCTAssertTrue(plan.requiresInteractiveAuthorization)
        XCTAssertEqual(plan.terminalCommand, "sudo dnf install -y zsh")
    }

    func testZshInstallerReturnsNoPlanWithoutSupportedPackageManager() throws {
        let mock = MockRemoteExecutor()
        mock.zshInstallPackageManager = "none"
        mock.zshInstallAuthorization = "unavailable"
        let installer = RemoteZshInstaller(executor: mock)

        XCTAssertNil(try installer.detectPlan(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: ""
        ))
    }

    func testZshInstallerPreservesUnavailableAuthorizationForUIGuard() throws {
        let mock = MockRemoteExecutor()
        mock.zshInstallPackageManager = "apt-get"
        mock.zshInstallAuthorization = "unavailable"
        let installer = RemoteZshInstaller(executor: mock)

        let plan = try XCTUnwrap(installer.detectPlan(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: ""
        ))

        XCTAssertEqual(plan.authorization, .unavailable)
    }

    func testZshInstallPlanCoversSupportedPackageManagers() {
        let expected: [(RemoteZshInstallationPlan.PackageManager, String)] = [
            (.aptGet, "apt-get update && env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh"),
            (.dnf, "dnf install -y zsh"),
            (.yum, "yum install -y zsh"),
            (.pacman, "pacman -Sy --noconfirm zsh"),
            (.zypper, "zypper --non-interactive install zsh"),
            (.apk, "apk add zsh"),
            (.brew, "brew install zsh")
        ]

        for (packageManager, command) in expected {
            XCTAssertEqual(
                RemoteZshInstallationPlan(
                    packageManager: packageManager,
                    authorization: .root
                ).terminalCommand,
                command
            )
        }
    }

    func testZshInstallerReportsRemoteAvailability() throws {
        let mock = MockRemoteExecutor()
        mock.zshAvailable = false
        let installer = RemoteZshInstaller(executor: mock)

        XCTAssertFalse(try installer.isZshAvailable(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: ""
        ))

        mock.zshAvailable = true
        XCTAssertTrue(try installer.isZshAvailable(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: ""
        ))
    }

    func testZshInstallerWaitsForAndConsumesSafeCompletionMarker() throws {
        let mock = MockRemoteExecutor()
        mock.zshAvailable = true
        let installer = RemoteZshInstaller(executor: mock)
        let marker = "/tmp/stacio-zsh-install-1234abcd.ready"

        XCTAssertFalse(try installer.consumeSuccessfulInstallationMarker(
            marker,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: ""
        ))

        mock.zshInstallMarkerReady = true
        XCTAssertTrue(try installer.consumeSuccessfulInstallationMarker(
            marker,
            config: config,
            secret: secret,
            expectedFingerprintSHA256: ""
        ))
        XCTAssertFalse(mock.zshInstallMarkerReady)
        XCTAssertFalse(try installer.consumeSuccessfulInstallationMarker(
            "/tmp/not-stacio;touch-pwned.ready",
            config: config,
            secret: secret,
            expectedFingerprintSHA256: ""
        ))
    }

    func testDeployVerificationFailureRollsBackZshrc() throws {
        let mock = MockRemoteExecutor()
        mock.verifySucceeds = false
        mock.remoteFiles["~/.zshrc"] = "original-content\n"
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        XCTAssertThrowsError(try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        ))
        // 校验失败：.zshrc 必须实际恢复为原内容（mock 的 cp -f 分支支持此断言）
        XCTAssertEqual(mock.remoteFiles["~/.zshrc"], "original-content\n")
        XCTAssertFalse(mock.remoteFiles.keys.contains { $0.contains("stacio-backup") }, "回滚后不应残留备份")
    }

    func testDeployDisabledRemovesExisting() throws {
        let mock = MockRemoteExecutor()
        mock.remoteDirs.insert("~/.oh-my-zsh")
        mock.remoteFiles["~/.oh-my-zsh/.stacio-managed"] = "stacio-managed"
        mock.remoteFiles["~/.zshrc"] = "content\n# >>> STACIO OH-MY-ZSH >>>\nZSH_THEME=\"x\"\n# <<< STACIO OH-MY-ZSH <<<\n"
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        var settings = AppSettings()
        settings.ohmyzshEnabled = false
        try deployer.deploy(config: config, secret: secret, expectedFingerprintSHA256: "", global: settings)

        XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: mock.remoteFiles["~/.zshrc"] ?? ""))
        XCTAssertFalse(mock.remoteDirs.contains("~/.oh-my-zsh"), "禁用时应移除 Stacio 创建的目录")
    }

    func testStatusReportsDeploymentState() throws {
        let mock = MockRemoteExecutor()
        mock.remoteDirs.insert("~/.oh-my-zsh")
        mock.remoteFiles["~/.oh-my-zsh/.stacio-managed"] = "stacio-managed"
        mock.remoteFiles["~/.zshrc"] = "x\n# >>> STACIO OH-MY-ZSH >>>\n# <<< STACIO OH-MY-ZSH <<<\n"
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        let status = deployer.status(config: config, secret: secret, expectedFingerprintSHA256: "")
        XCTAssertTrue(status.zshAvailable)
        XCTAssertTrue(status.directoryExists)
        XCTAssertTrue(status.managedByStacio)
        XCTAssertTrue(status.zshrcHasBlock)
        XCTAssertTrue(status.isDeployed)
    }

    func testDeployVerificationFailureRestoresUserDirectory() throws {
        let mock = MockRemoteExecutor()
        mock.verifySucceeds = false
        // 用户自装目录（无标记，含用户文件）
        mock.remoteDirs.insert("~/.oh-my-zsh")
        mock.remoteFiles["~/.oh-my-zsh/user-data.txt"] = "precious"
        mock.remoteFiles["~/.zshrc"] = "original\n"
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        XCTAssertThrowsError(try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        ))
        // 用户目录必须完整恢复（含用户文件），且无备份残留
        XCTAssertTrue(mock.remoteDirs.contains("~/.oh-my-zsh"))
        XCTAssertEqual(mock.remoteFiles["~/.oh-my-zsh/user-data.txt"], "precious")
        XCTAssertEqual(mock.remoteFiles["~/.zshrc"], "original\n")
        XCTAssertFalse(mock.remoteDirs.contains { $0.hasPrefix("~/.oh-my-zsh.stacio-backup-") })
        XCTAssertFalse(mock.remoteFiles.keys.contains { $0.contains("stacio-backup") })
    }

    func testDeployVerificationFailureWithoutZshrcRemovesNewlyWrittenFile() throws {
        let mock = MockRemoteExecutor()
        mock.verifySucceeds = false
        // 原本无 .zshrc
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        XCTAssertThrowsError(try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        ))
        // 原本无 .zshrc 时回滚应删除新写入的文件（不留空文件）
        XCTAssertNil(mock.remoteFiles["~/.zshrc"])
    }

    func testDeployUploadFailureBeforeZshrcWriteLeavesUserZshrcUntouched() throws {
        // 上传在写 .zshrc 之前失败：回滚不得删/改用户原有 .zshrc
        struct FailingUploadExecutor: RemoteOhMyZshCoreExecuting {
            let inner: MockRemoteExecutor
            func runRemoteCommand(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, command: String) throws -> RemoteCommandResult {
                try inner.runRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, command: command)
            }
            func readRemoteFile(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String) throws -> String {
                try inner.readRemoteFile(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path)
            }
            func writeRemoteFile(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String, content: String) throws {
                try inner.writeRemoteFile(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path, content: content)
            }
            func uploadDirectory(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, localDirectoryURL: URL, remotePath: String) throws {
                throw RemoteOhMyZshDeployerError.bundleUnavailable // 模拟上传中断
            }
            func deleteRemotePath(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String, recursive: Bool) throws {
                try inner.deleteRemotePath(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path, recursive: recursive)
            }
        }
        let mock = MockRemoteExecutor()
        mock.remoteFiles["~/.zshrc"] = "precious-original\n"
        let deployer = RemoteOhMyZshDeployer(executor: FailingUploadExecutor(inner: mock), bundleOhMyZshURL: bundleURL)

        XCTAssertThrowsError(try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        ))
        // 上传失败（备份未写入）时 .zshrc 必须原样保留
        XCTAssertEqual(mock.remoteFiles["~/.zshrc"], "precious-original\n")
    }

    func testDeployExtractionFailureRollsBackBeforeWritingZshrc() throws {
        let mock = MockRemoteExecutor()
        mock.extractionSucceeds = false
        mock.remoteFiles["~/.zshrc"] = "precious-original\n"
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        XCTAssertThrowsError(try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        )) { error in
            XCTAssertEqual(error as? RemoteOhMyZshDeployerError, .archiveExtractionFailed)
        }
        XCTAssertEqual(mock.remoteFiles["~/.zshrc"], "precious-original\n")
        XCTAssertTrue(mock.commands.contains { $0.contains("rm -f ~/.stacio-ohmyzsh-") })
    }

    func testDeployReadZshrcFailureAbortsWithoutTouchingUserFile() throws {
        // 读 ~/.zshrc 失败必须中止部署：不得用空备份覆盖用户配置
        struct FailingReadExecutor: RemoteOhMyZshCoreExecuting {
            let inner: MockRemoteExecutor
            func runRemoteCommand(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, command: String) throws -> RemoteCommandResult {
                try inner.runRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, command: command)
            }
            func readRemoteFile(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String) throws -> String {
                if path == "~/.zshrc" {
                    throw RemoteOhMyZshDeployerError.zshNotAvailable // 模拟读失败
                }
                return try inner.readRemoteFile(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path)
            }
            func writeRemoteFile(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String, content: String) throws {
                try inner.writeRemoteFile(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path, content: content)
            }
            func uploadDirectory(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, localDirectoryURL: URL, remotePath: String) throws {
                try inner.uploadDirectory(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, localDirectoryURL: localDirectoryURL, remotePath: remotePath)
            }
            func deleteRemotePath(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String, recursive: Bool) throws {
                try inner.deleteRemotePath(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path, recursive: recursive)
            }
        }
        let mock = MockRemoteExecutor()
        mock.remoteFiles["~/.zshrc"] = "precious-original\n"
        let deployer = RemoteOhMyZshDeployer(executor: FailingReadExecutor(inner: mock), bundleOhMyZshURL: bundleURL)

        XCTAssertThrowsError(try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        ))
        // 用户 .zshrc 必须原样保留（未被空备份覆盖）
        XCTAssertEqual(mock.remoteFiles["~/.zshrc"], "precious-original\n")
        // 不得写入任何 stacio-backup 备份
        XCTAssertFalse(mock.remoteFiles.keys.contains { $0.contains("stacio-backup") })
    }

    func testRemoveWithoutZshrcIsNoOp() throws {
        let mock = MockRemoteExecutor()
        // 远端无 .zshrc、无目录：remove 应为安全 no-op（不抛错）
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)
        XCTAssertNoThrow(try deployer.remove(config: config, secret: secret, expectedFingerprintSHA256: ""))
    }

    func testRemoveRemovesBlockAndManagedDirectory() throws {
        let mock = MockRemoteExecutor()
        mock.remoteDirs.insert("~/.oh-my-zsh")
        mock.remoteFiles["~/.oh-my-zsh/.stacio-managed"] = "stacio-managed"
        mock.remoteFiles["~/.zshrc"] = "user\n# >>> STACIO OH-MY-ZSH >>>\nZSH_THEME=\"x\"\n# <<< STACIO OH-MY-ZSH <<<\n"
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        try deployer.remove(config: config, secret: secret, expectedFingerprintSHA256: "")

        XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: mock.remoteFiles["~/.zshrc"] ?? ""))
        XCTAssertTrue(mock.remoteFiles["~/.zshrc"]?.contains("user") == true, "用户内容必须保留")
        XCTAssertFalse(mock.remoteDirs.contains("~/.oh-my-zsh"), "Stacio 创建的目录应被删除")
    }

    func testDeployWithExistingDirectoryWithoutCustomSucceeds() throws {
        // 用户已有 ~/.oh-my-zsh 但无 custom 子目录：部署不得误报 customRestoreFailed
        let mock = MockRemoteExecutor()
        mock.remoteDirs.insert("~/.oh-my-zsh")
        mock.remoteFiles["~/.zshrc"] = "original\n"
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        XCTAssertNoThrow(try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        ))
        XCTAssertTrue(mock.uploadedDirectories.contains { $0.hasPrefix("~/.stacio-ohmyzsh-") })
    }

    func testDeployRestoresExistingCustomDirectory() throws {
        // 用户已有 ~/.oh-my-zsh 且含 custom：部署后 custom 内容必须恢复
        let mock = MockRemoteExecutor()
        mock.remoteDirs.insert("~/.oh-my-zsh")
        mock.remoteDirs.insert("~/.oh-my-zsh/custom")
        mock.remoteFiles["~/.oh-my-zsh/custom/my-plugin.zsh"] = "my-plugin-content"
        mock.remoteFiles["~/.zshrc"] = "original\n"
        let deployer = RemoteOhMyZshDeployer(executor: mock, bundleOhMyZshURL: bundleURL)

        try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        )
        XCTAssertEqual(
            mock.remoteFiles["~/.oh-my-zsh/custom/my-plugin.zsh"],
            "my-plugin-content",
            "用户 custom 内容必须在部署后恢复"
        )
    }

    func testDeployRollbackZshrcFailurePreservesBackup() throws {
        // 回滚 cp 恢复失败：必须抛 rollbackZshrcFailed 且保留备份（不得无条件删除）
        struct FailingRestoreExecutor: RemoteOhMyZshCoreExecuting {
            let inner: MockRemoteExecutor
            func runRemoteCommand(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, command: String) throws -> RemoteCommandResult {
                if command.hasPrefix("cp -f ") {
                    return RemoteCommandResult(exitCode: 1, stdout: "", stderr: "cp: failed")
                }
                return try inner.runRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, command: command)
            }
            func readRemoteFile(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String) throws -> String {
                try inner.readRemoteFile(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path)
            }
            func writeRemoteFile(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String, content: String) throws {
                try inner.writeRemoteFile(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path, content: content)
            }
            func uploadDirectory(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, localDirectoryURL: URL, remotePath: String) throws {
                try inner.uploadDirectory(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, localDirectoryURL: localDirectoryURL, remotePath: remotePath)
            }
            func deleteRemotePath(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String, recursive: Bool) throws {
                try inner.deleteRemotePath(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path, recursive: recursive)
            }
        }
        let mock = MockRemoteExecutor()
        mock.verifySucceeds = false
        // 用户已有 ~/.oh-my-zsh（含标记）与 .zshrc：验证 .zshrc 回滚失败时目录仍被恢复
        mock.remoteDirs.insert("~/.oh-my-zsh")
        mock.remoteFiles["~/.oh-my-zsh/.stacio-managed"] = "stacio-managed"
        mock.remoteFiles["~/.zshrc"] = "original-content\n"
        let deployer = RemoteOhMyZshDeployer(executor: FailingRestoreExecutor(inner: mock), bundleOhMyZshURL: bundleURL)

        XCTAssertThrowsError(try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        )) { error in
            guard case RemoteOhMyZshDeployerError.rollbackZshrcFailed = error else {
                return XCTFail("应为 rollbackZshrcFailed，实际 \(error)")
            }
        }
        // 备份必须保留（供手动恢复）
        XCTAssertTrue(mock.remoteFiles.keys.contains { $0.contains("stacio-backup") }, "回滚失败时备份必须保留")
        // 目录必须已回滚（不因 .zshrc 回滚失败而停留在 Stacio 新上传状态）
        XCTAssertTrue(mock.remoteDirs.contains("~/.oh-my-zsh"), "目录应恢复")
        XCTAssertFalse(mock.remoteDirs.contains { $0.hasPrefix("~/.oh-my-zsh.stacio-backup-") }, "备份目录应被移回")
    }

    func testDeployAbortsWhenDirectoryBackupFails() throws {
        let mock = MockRemoteExecutor()
        // mv 失败：目录存在但 mock 的 mv 分支在目录不存在时返回非 0——这里直接让命令匹配 mv 但标记目录不存在
        mock.remoteDirs.remove("~/.oh-my-zsh")
        mock.remoteDirs.insert("~/.oh-my-zsh.stacio-backup-preexisting") // 干扰，确保 mv 走失败分支
        // 目录检测为 MISSING 时不走备份分支，因此构造直接调用场景：目录存在但 mv 失败
        mock.remoteDirs.remove("~/.oh-my-zsh.stacio-backup-preexisting")
        mock.remoteDirs.insert("~/.oh-my-zsh")
        // 用子类拦截：令 mv 返回非 0
        struct FailingMoveExecutor: RemoteOhMyZshCoreExecuting {
            let inner: MockRemoteExecutor
            func runRemoteCommand(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, command: String) throws -> RemoteCommandResult {
                if command.hasPrefix("mv ~/.oh-my-zsh ") {
                    return RemoteCommandResult(exitCode: 1, stdout: "", stderr: "mv: failed")
                }
                return try inner.runRemoteCommand(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, command: command)
            }
            func readRemoteFile(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String) throws -> String {
                try inner.readRemoteFile(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path)
            }
            func writeRemoteFile(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String, content: String) throws {
                try inner.writeRemoteFile(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path, content: content)
            }
            func uploadDirectory(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, localDirectoryURL: URL, remotePath: String) throws {
                try inner.uploadDirectory(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, localDirectoryURL: localDirectoryURL, remotePath: remotePath)
            }
            func deleteRemotePath(config: SshConnectionConfig, secret: SshAuthSecret, expectedFingerprintSHA256: String, path: String, recursive: Bool) throws {
                try inner.deleteRemotePath(config: config, secret: secret, expectedFingerprintSHA256: expectedFingerprintSHA256, path: path, recursive: recursive)
            }
        }
        let deployer2 = RemoteOhMyZshDeployer(executor: FailingMoveExecutor(inner: mock), bundleOhMyZshURL: bundleURL)
        XCTAssertThrowsError(try deployer2.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: "",
            global: makeSettings()
        )) { error in
            XCTAssertEqual(error as? RemoteOhMyZshDeployerError, .directoryBackupFailed)
        }
        // 目录未被删除、未上传
        XCTAssertTrue(mock.remoteDirs.contains("~/.oh-my-zsh"))
        XCTAssertTrue(mock.uploadedDirectories.isEmpty)
    }
}
