import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

/// 真机（真实 SSH 主机）集成验收测试。
///
/// 仅在设置环境变量 `STACIO_REAL_SSH_TESTS=1` 时执行（默认 XCTSkip，不影响常规 117/117 套件）。
/// 需要的环境变量：
///   STACIO_REAL_SSH_TESTS=1
///   STACIO_TEST_MAIN_HOST=10.211.55.6          （装有 zsh 的测试主机）
///   STACIO_TEST_MAIN_FP=<hex sha256>           （主主机 host key 指纹，不含 "SHA256:" 前缀）
///   STACIO_TEST_NOZSH_HOST=10.211.55.5         （未装 zsh 的主机，用于 B3）
///   STACIO_TEST_NOZSH_FP=<hex sha256>
///   STACIO_TEST_BUNDLE_DIR=<path>              （已校验下载的 OhMyZsh 资源目录，用于上传）
///
/// 运行示例：
///   STACIO_REAL_SSH_TESTS=1 STACIO_TEST_MAIN_HOST=10.211.55.6 \
///     STACIO_TEST_MAIN_FP=07b313e6... STACIO_TEST_NOZSH_HOST=10.211.55.5 \
///     STACIO_TEST_NOZSH_FP=354abfa4... \
///     STACIO_TEST_BUNDLE_DIR="/tmp/stacio-omz-production/OhMyZsh" \
///     swift test --disable-sandbox --filter OhMyZshRealHostIntegrationTests
final class OhMyZshRealHostIntegrationTests: XCTestCase {
    private var mainConfig: SshConnectionConfig!
    private var noZshConfig: SshConnectionConfig!
    private var secret: SshAuthSecret!
    private var bundleURL: URL!
    private var mainFingerprintHex = ""
    private var noZshFingerprintHex = ""

    private static func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }

    override func setUpWithError() throws {
        guard Self.env("STACIO_REAL_SSH_TESTS") == "1" else {
            throw XCTSkip("未设置 STACIO_REAL_SSH_TESTS=1，跳过真机验收测试。")
        }
        guard let mainHost = Self.env("STACIO_TEST_MAIN_HOST"),
              let mainFP = Self.env("STACIO_TEST_MAIN_FP"),
              let noZshHost = Self.env("STACIO_TEST_NOZSH_HOST"),
              let noZshFP = Self.env("STACIO_TEST_NOZSH_FP"),
              let bundleDir = Self.env("STACIO_TEST_BUNDLE_DIR") else {
            throw XCTSkip("真机验收环境变量不完整，跳过。")
        }
        mainFingerprintHex = mainFP
        noZshFingerprintHex = noZshFP
        let home = NSHomeDirectory()
        let keyPath = "\(home)/.ssh/id_ed25519"
        guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8) else {
            throw XCTSkip("缺少 SSH 私钥 \(keyPath)。")
        }
        secret = .privateKey(privateKeyPem: pem, passphrase: nil)
        mainConfig = SshConnectionConfig(
            host: mainHost,
            port: 22,
            username: "root",
            authMethod: .privateKey(keyPath: keyPath, passphraseRef: nil),
            connectTimeoutMs: 15_000
        )
        noZshConfig = SshConnectionConfig(
            host: noZshHost,
            port: 22,
            username: "root",
            authMethod: .privateKey(keyPath: keyPath, passphraseRef: nil),
            connectTimeoutMs: 15_000
        )
        bundleURL = URL(fileURLWithPath: bundleDir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundleDir, isDirectory: &isDir), isDir.boolValue else {
            throw XCTSkip("STACIO_TEST_BUNDLE_DIR 不是目录。")
        }
    }

    // MARK: - 工具

    /// 通过系统 ssh 执行远端命令用于"观察/重置"远端状态（部署本身走 Stacio libssh2 生产路径）。
    private func remoteShell(_ command: String, host: String? = nil) throws -> String {
        let target = host ?? mainConfig.host
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "root@\(target)",
            command
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func resetMainHost() throws {
        _ = try remoteShell("rm -rf ~/.oh-my-zsh ~/.zshrc ~/.stacio-omz-verify-* ~/.zshrc.stacio-backup-* ~/.oh-my-zsh.stacio-backup-*")
    }

    private func deploy(_ config: SshConnectionConfig, settings: AppSettings) throws {
        let deployer = RemoteOhMyZshDeployer(bundleOhMyZshURL: bundleURL)
        try deployer.deploy(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: mainFP(config),
            global: settings
        )
    }

    private func mainFP(_ config: SshConnectionConfig) -> String {
        let raw = config.host == noZshConfig.host ? noZshFingerprintHex : mainFingerprintHex
        return raw.hasPrefix("SHA256:") ? raw : "SHA256:\(raw)"
    }

    private func makeEnabledSettings(theme: String = "robbyrussell") -> AppSettings {
        var settings = AppSettings()
        settings.ohmyzshEnabled = true
        settings.ohmyzshTheme = theme
        settings.ohmyzshPlugins = ["git"]
        return settings
    }

    // MARK: - B 组：远程 SSH 部署

    /// B1 全新主机部署：~/.oh-my-zsh 存在含标记；.zshrc 含 Stacio 区块。
    func testB1FreshHostDeploy() throws {
        try resetMainHost()
        try deploy(mainConfig, settings: makeEnabledSettings())

        let marker = try remoteShell("test -f ~/.oh-my-zsh/.stacio-managed && echo MANAGED || echo MISSING")
        XCTAssertTrue(marker.contains("MANAGED"), "远端 ~/.oh-my-zsh 应含 .stacio-managed 标记")

        let zshrc = try remoteShell("cat ~/.zshrc")
        XCTAssertTrue(OhMyZshConfigResolver.containsBlock(in: zshrc), "远端 .zshrc 应含 Stacio 区块")
        XCTAssertTrue(zshrc.contains("ZSH_THEME=\"robbyrussell\""))
    }

    /// B2 生效验证：zsh -i 加载后 ZSH_THEME 正确；git 插件别名可用。
    func testB2Effectiveness() throws {
        try resetMainHost()
        try deploy(mainConfig, settings: makeEnabledSettings())

        let out = try remoteShell("zsh -i -c 'echo ZSH_THEME=$ZSH_THEME; alias gst >/dev/null 2>&1 && echo GIT_ALIAS_OK || echo NO_ALIAS'")
        XCTAssertTrue(out.contains("ZSH_THEME=robbyrussell"), "ZSH_THEME 应生效，输出: \(out)")
        XCTAssertTrue(out.contains("GIT_ALIAS_OK"), "git 插件别名 gst 应可用，输出: \(out)")
    }

    /// B3 无 zsh 主机：明确报"未安装 zsh"，不上传任何文件。
    func testB3NoZshHost() throws {
        _ = try remoteShell("rm -rf ~/.oh-my-zsh ~/.zshrc", host: noZshConfig.host)
        let deployer = RemoteOhMyZshDeployer(bundleOhMyZshURL: bundleURL)
        do {
            try deployer.deploy(
                config: noZshConfig,
                secret: secret,
                expectedFingerprintSHA256: mainFP(noZshConfig),
                global: makeEnabledSettings()
            )
            XCTFail("无 zsh 主机部署应失败")
        } catch let error as RemoteOhMyZshDeployerError {
            XCTAssertEqual(error, .zshNotAvailable, "应报 zshNotAvailable，实际 \(error)")
        }
        let dir = try remoteShell("test -d ~/.oh-my-zsh && echo EXISTS || echo MISSING", host: noZshConfig.host)
        XCTAssertTrue(dir.contains("MISSING"), "无 zsh 主机不得上传任何文件")
    }

    /// B4 已有目录 + custom：部署后 custom 内容保留。
    func testB4ExistingDirectoryPreservesCustom() throws {
        try resetMainHost()
        _ = try remoteShell("mkdir -p ~/.oh-my-zsh/custom && echo 'my-plugin-content' > ~/.oh-my-zsh/custom/my-plugin.zsh")
        try deploy(mainConfig, settings: makeEnabledSettings())

        let content = try remoteShell("cat ~/.oh-my-zsh/custom/my-plugin.zsh")
        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "my-plugin-content")
    }

    /// B5 已有目录但无 custom：不误报 customRestoreFailed。
    func testB5ExistingDirectoryWithoutCustom() throws {
        try resetMainHost()
        _ = try remoteShell("mkdir -p ~/.oh-my-zsh && echo 'x' > ~/.oh-my-zsh/README")
        XCTAssertNoThrow(try deploy(mainConfig, settings: makeEnabledSettings()))
        let marker = try remoteShell("test -f ~/.oh-my-zsh/.stacio-managed && echo MANAGED || echo MISSING")
        XCTAssertTrue(marker.contains("MANAGED"))
    }

    /// B7 二次部署：区块更新且只有一份；custom 保留；无备份残留。
    func testB7RedeployUpdatesBlockOnce() throws {
        try resetMainHost()
        try deploy(mainConfig, settings: makeEnabledSettings(theme: "robbyrussell"))

        // 换主题再部署
        try deploy(mainConfig, settings: makeEnabledSettings(theme: "agnoster"))

        let zshrc = try remoteShell("cat ~/.zshrc")
        let blockCount = zshrc.components(separatedBy: "# >>> STACIO OH-MY-ZSH >>>").count - 1
        XCTAssertEqual(blockCount, 1, "区块应只有一份")
        XCTAssertTrue(zshrc.contains("ZSH_THEME=\"agnoster\""), "主题应更新为 agnoster")

        let backups = try remoteShell("ls -d ~/.zshrc.stacio-backup-* ~/.oh-my-zsh.stacio-backup-* 2>/dev/null | wc -l")
        XCTAssertEqual(backups.trimmingCharacters(in: .whitespacesAndNewlines), "0", "不应残留备份目录/文件")
    }

    /// B8 远程卸载：区块移除、用户内容保留；仅删 Stacio 创建目录。
    func testB8RemoteUninstall() throws {
        try resetMainHost()
        _ = try remoteShell("echo 'user-line' > ~/.zshrc")
        try deploy(mainConfig, settings: makeEnabledSettings())
        // 部署后追加用户行
        _ = try remoteShell("echo 'user-tail' >> ~/.zshrc")

        let deployer = RemoteOhMyZshDeployer(bundleOhMyZshURL: bundleURL)
        try deployer.remove(config: mainConfig, secret: secret, expectedFingerprintSHA256: mainFP(mainConfig))

        let zshrc = try remoteShell("cat ~/.zshrc")
        XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: zshrc), "区块应移除")
        XCTAssertTrue(zshrc.contains("user-line") && zshrc.contains("user-tail"), "用户内容必须保留")
        let dir = try remoteShell("test -d ~/.oh-my-zsh && echo EXISTS || echo MISSING")
        XCTAssertTrue(dir.contains("MISSING"), "Stacio 创建的 ~/.oh-my-zsh 应被删除")
    }

    /// B9 非 UTF-8 .zshrc：报编码解析失败，原文件字节不变。
    func testB9NonUTF8ZshrcAborts() throws {
        try resetMainHost()
        // 写入含 0xE9（latin-1 é）的 .zshrc：printf 的 \351 是八进制转义，产出单字节 0xE9
        _ = try remoteShell("printf 'user \\351 line\\n' > ~/.zshrc; od -An -tx1 ~/.zshrc")
        let before = try remoteShell("md5sum ~/.zshrc | awk '{print $1}'")

        let deployer = RemoteOhMyZshDeployer(bundleOhMyZshURL: bundleURL)
        do {
            try deployer.deploy(
                config: mainConfig,
                secret: secret,
                expectedFingerprintSHA256: mainFP(mainConfig),
                global: makeEnabledSettings()
            )
            XCTFail("非 UTF-8 .zshrc 应中止部署")
        } catch let error as RemoteOhMyZshDeployerError {
            guard case .remoteFileDecodeFailed = error else {
                return XCTFail("应报 remoteFileDecodeFailed，实际 \(error)")
            }
        }
        let after = try remoteShell("md5sum ~/.zshrc | awk '{print $1}'")
        XCTAssertEqual(before.trimmingCharacters(in: .whitespacesAndNewlines),
                       after.trimmingCharacters(in: .whitespacesAndNewlines),
                       "原文件字节不得改变")
        let dir = try remoteShell("test -d ~/.oh-my-zsh && echo EXISTS || echo MISSING")
        XCTAssertTrue(dir.contains("MISSING"), "中止部署时不得残留 ~/.oh-my-zsh")
    }

    /// B10 校验失败回滚：.zshrc 含阻塞命令 → 校验超时 → 恢复原内容、目录回滚、备份无残留。
    func testB10BlockedZshrcRollsBack() throws {
        try resetMainHost()
        _ = try remoteShell("echo 'echo before' > ~/.zshrc && echo 'sleep 1000' >> ~/.zshrc")

        let deployer = RemoteOhMyZshDeployer(bundleOhMyZshURL: bundleURL)
        let start = Date()
        do {
            try deployer.deploy(
                config: mainConfig,
                secret: secret,
                expectedFingerprintSHA256: mainFP(mainConfig),
                global: makeEnabledSettings()
            )
            XCTFail("阻塞 .zshrc 应导致校验失败")
        } catch {
            // 校验失败/超时均可接受（远端 30s 兜底 kill）
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(elapsed < 60, "校验应在可接受时间内结束，实际 \(elapsed)s")

        let zshrc = try remoteShell("cat ~/.zshrc")
        XCTAssertTrue(zshrc.contains("echo before"), ".zshrc 应恢复原内容")
        XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: zshrc), "不应残留区块")
        let backups = try remoteShell("ls -d ~/.zshrc.stacio-backup-* ~/.oh-my-zsh.stacio-backup-* 2>/dev/null | wc -l")
        XCTAssertEqual(backups.trimmingCharacters(in: .whitespacesAndNewlines), "0", "回滚后不应残留备份")
    }

    // MARK: - A 组：本地终端部署（隔离 HOME，不触碰真实 ~/.oh-my-zsh）

    /// 在隔离 HOME 下执行本地部署/卸载/验证（对 zsh 子进程临时覆盖 HOME）。
    private func withIsolatedHome<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-local-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempHome.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
            try? FileManager.default.removeItem(at: tempHome)
        }
        return try body(tempHome)
    }

    private func localDeploy(
        home: URL,
        settings: AppSettings,
        bundle: URL? = nil
    ) throws {
        let deployer = LocalOhMyZshDeployer(
            homeDirectoryURL: home,
            bundleOhMyZshURL: bundle ?? bundleURL
        )
        try deployer.deploy(global: settings, catalog: OhMyZshCatalog(directoryURL: bundle ?? bundleURL))
    }

    private func localZshOut(_ command: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-i", "-c", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// A1+A2 全新部署并生效：目录+标记+区块；zsh -i 下 ZSH_THEME 生效、git 别名可用。
    func testA1A2LocalFreshDeployAndEffect() throws {
        try withIsolatedHome { home in
            var settings = AppSettings()
            settings.ohmyzshEnabled = true
            settings.ohmyzshTheme = "robbyrussell"
            settings.ohmyzshPlugins = ["git"]
            try localDeploy(home: home, settings: settings)

            XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".oh-my-zsh/.stacio-managed").path))
            let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
            XCTAssertTrue(OhMyZshConfigResolver.containsBlock(in: zshrc))

            let out = localZshOut("echo ZSH_THEME=$ZSH_THEME; alias gst >/dev/null 2>&1 && echo GIT_ALIAS_OK || echo NO_ALIAS")
            XCTAssertTrue(out.contains("ZSH_THEME=robbyrussell"), "隔离 HOME 下 zsh -i 应加载 oh-my-zsh，输出: \(out)")
            XCTAssertTrue(out.contains("GIT_ALIAS_OK"), "git 插件别名应生效，输出: \(out)")
        }
    }

    /// A3 主题切换：重部署后区块更新为 agnoster 且只有一份。
    func testA3ThemeSwitch() throws {
        try withIsolatedHome { home in
            var settings = AppSettings()
            settings.ohmyzshEnabled = true
            settings.ohmyzshTheme = "robbyrussell"
            settings.ohmyzshPlugins = ["git"]
            try localDeploy(home: home, settings: settings)

            settings.ohmyzshTheme = "agnoster"
            try localDeploy(home: home, settings: settings)

            let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
            let count = zshrc.components(separatedBy: "# >>> STACIO OH-MY-ZSH >>>").count - 1
            XCTAssertEqual(count, 1, "区块应只有一份")
            XCTAssertTrue(zshrc.contains("ZSH_THEME=\"agnoster\""))
        }
    }

    /// A4 幂等：相同配置再部署不重复区块、用户行不受影响。
    func testA4IdempotentRedeploy() throws {
        try withIsolatedHome { home in
            _ = try "alias userline='echo hi'\n".write(
                to: home.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )
            var settings = AppSettings()
            settings.ohmyzshEnabled = true
            settings.ohmyzshTheme = "robbyrussell"
            settings.ohmyzshPlugins = ["git"]
            try localDeploy(home: home, settings: settings)
            try localDeploy(home: home, settings: settings)

            let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
            let count = zshrc.components(separatedBy: "# >>> STACIO OH-MY-ZSH >>>").count - 1
            XCTAssertEqual(count, 1, "幂等部署后区块应只有一份")
            XCTAssertTrue(zshrc.contains("alias userline='echo hi'"), "用户原有行必须保留")
        }
    }

    /// A5 用户内容保留：部署前手动加的别名保留；区块前后用户行完整。
    func testA5UserContentPreserved() throws {
        try withIsolatedHome { home in
            _ = try "alias mytest='echo hi'\n".write(
                to: home.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )
            var settings = AppSettings()
            settings.ohmyzshEnabled = true
            settings.ohmyzshTheme = "robbyrussell"
            settings.ohmyzshPlugins = ["git"]
            try localDeploy(home: home, settings: settings)

            let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
            XCTAssertTrue(zshrc.contains("alias mytest='echo hi'"), "mytest 别名必须保留")
        }
    }

    /// A6 卸载：区块移除、用户内容保留；Stacio 创建的目录删除。
    func testA6LocalUninstall() throws {
        try withIsolatedHome { home in
            _ = try "user-line\n".write(
                to: home.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )
            var settings = AppSettings()
            settings.ohmyzshEnabled = true
            settings.ohmyzshTheme = "robbyrussell"
            settings.ohmyzshPlugins = ["git"]
            try localDeploy(home: home, settings: settings)

            let deployer = LocalOhMyZshDeployer(homeDirectoryURL: home, bundleOhMyZshURL: bundleURL)
            try deployer.remove()

            let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
            XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: zshrc))
            XCTAssertTrue(zshrc.contains("user-line"), "用户内容必须保留")
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".oh-my-zsh").path))
        }
    }

    /// A7 用户自装目录保护：无标记目录卸载时只移除区块，不删除用户目录。
    func testA7UserInstalledDirectoryProtected() throws {
        try withIsolatedHome { home in
            let userOmz = home.appendingPathComponent(".oh-my-zsh", isDirectory: true)
            try FileManager.default.createDirectory(at: userOmz, withIntermediateDirectories: true)
            try "user-data".write(to: userOmz.appendingPathComponent("user-file.txt"), atomically: true, encoding: .utf8)
            _ = try "# >>> STACIO OH-MY-ZSH >>>\nZSH_THEME=\"x\"\n# <<< STACIO OH-MY-ZSH <<<\n".write(
                to: home.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )

            let deployer = LocalOhMyZshDeployer(homeDirectoryURL: home, bundleOhMyZshURL: bundleURL)
            try deployer.remove()

            XCTAssertTrue(FileManager.default.fileExists(atPath: userOmz.path), "用户自装目录不得删除")
            XCTAssertTrue(FileManager.default.fileExists(atPath: userOmz.appendingPathComponent("user-file.txt").path))
            let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
            XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: zshrc), "区块应移除")
        }
    }

    /// A8 校验失败回滚：.zshrc 含阻塞命令 → 校验超时 → 原内容恢复、目录回滚。
    func testA8VerificationFailureRollsBack() throws {
        try withIsolatedHome { home in
            _ = try "echo before\nsleep 30\n".write(
                to: home.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )
            var settings = AppSettings()
            settings.ohmyzshEnabled = true
            settings.ohmyzshTheme = "robbyrussell"
            settings.ohmyzshPlugins = ["git"]

            let start = Date()
            XCTAssertThrowsError(try localDeploy(home: home, settings: settings))
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertTrue(elapsed < 60, "校验应在可接受时间内结束，实际 \(elapsed)s")

            let zshrc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
            XCTAssertTrue(zshrc.contains("echo before"), ".zshrc 应恢复原内容")
            XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: zshrc), "不应残留区块")
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".oh-my-zsh").path), "目录应回滚")
        }
    }
}
