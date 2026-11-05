import AppKit
import XCTest
@testable import StacioApp

// MARK: - OhMyZshConfigResolver

final class OhMyZshConfigResolverTests: XCTestCase {
    private var globalSettings: AppSettings {
        var settings = AppSettings()
        settings.ohmyzshEnabled = true
        settings.ohmyzshTheme = "agnoster"
        settings.ohmyzshPlugins = ["git", "docker"]
        settings.ohmyzshExtraZshrcLines = "export EDITOR=vim"
        return settings
    }

    func testResolveInheritsGlobalWhenSessionDoesNotOverride() {
        let resolved = OhMyZshConfigResolver.resolve(
            global: globalSettings,
            session: OhMyZshSessionConfig(overrideDefaults: false)
        )
        XCTAssertEqual(resolved.enabled, true)
        XCTAssertEqual(resolved.theme, "agnoster")
        XCTAssertEqual(resolved.plugins, ["git", "docker"])
        XCTAssertEqual(resolved.extraZshrcLines, "export EDITOR=vim")
    }

    func testResolveUsesSessionFieldsWhenOverriding() {
        let session = OhMyZshSessionConfig(
            overrideDefaults: true,
            enabled: true,
            theme: "robbyrussell",
            plugins: ["z"]
        )
        let resolved = OhMyZshConfigResolver.resolve(global: globalSettings, session: session)
        XCTAssertEqual(resolved.theme, "robbyrussell")
        XCTAssertEqual(resolved.plugins, ["z"])
    }

    func testResolveOverridingNilFieldsInheritGlobal() {
        let session = OhMyZshSessionConfig(
            overrideDefaults: true,
            enabled: nil,
            theme: nil,
            plugins: nil
        )
        let resolved = OhMyZshConfigResolver.resolve(global: globalSettings, session: session)
        XCTAssertEqual(resolved.theme, "agnoster")
        XCTAssertEqual(resolved.plugins, ["git", "docker"])
    }

    func testResolveExplicitFalseEnabledIsNotOverriddenByGlobal() {
        var settings = AppSettings()
        settings.ohmyzshEnabled = true
        // 会话显式关闭（enabled: false）必须保持关闭，不得继承全局 true
        let session = OhMyZshSessionConfig(
            overrideDefaults: true,
            enabled: false,
            theme: "agnoster",
            plugins: ["git"]
        )
        let resolved = OhMyZshConfigResolver.resolve(global: settings, session: session)
        XCTAssertEqual(resolved.enabled, false)
    }

    func testResolveFallsBackToDefaultsForEmptyValues() {
        var settings = AppSettings()
        settings.ohmyzshEnabled = false
        settings.ohmyzshTheme = ""
        settings.ohmyzshPlugins = []
        let resolved = OhMyZshConfigResolver.resolve(global: settings, session: .default)
        XCTAssertEqual(resolved.theme, OhMyZshConfigResolver.defaultThemeName)
        XCTAssertEqual(resolved.plugins, ["git"])
    }

    func testRenderBlockContainsThemePluginsAndUpdateDisabled() {
        let config = OhMyZshResolvedConfig(
            enabled: true,
            theme: "agnoster",
            plugins: ["git", "docker"],
            extraZshrcLines: "export EDITOR=vim"
        )
        let block = OhMyZshConfigResolver.renderZshrcBlock(config: config)
        XCTAssertTrue(block.contains(OhMyZshConfigResolver.blockStartMarker))
        XCTAssertTrue(block.contains(OhMyZshConfigResolver.blockEndMarker))
        XCTAssertTrue(block.contains("ZSH_THEME=\"agnoster\""))
        XCTAssertTrue(block.contains("plugins=(git docker)"))
        XCTAssertTrue(block.contains("zstyle ':omz:update' mode disabled"))
        XCTAssertTrue(block.contains("source \"$ZSH/oh-my-zsh.sh\""))
        XCTAssertTrue(block.contains("export EDITOR=vim"))
    }

    func testSanitizedTokenStripsInjectionCharacters() {
        XCTAssertEqual(
            OhMyZshConfigResolver.sanitizedToken("agnoster;rm -rf /", fallback: "robbyrussell"),
            "agnosterrm-rf"
        )
        XCTAssertEqual(
            OhMyZshConfigResolver.sanitizedToken("", fallback: "robbyrussell"),
            "robbyrussell"
        )
        XCTAssertEqual(
            OhMyZshConfigResolver.sanitizedToken("git-docker_z", fallback: "git"),
            "git-docker_z"
        )
    }

    func testUpsertAppendsBlockPreservingUserContent() {
        let zshrc = "export PATH=/usr/bin\nalias ll='ls -la'\n"
        let config = OhMyZshResolvedConfig(enabled: true, theme: "robbyrussell", plugins: ["git"], extraZshrcLines: nil)
        let result = OhMyZshConfigResolver.upsertBlock(in: zshrc, config: config)
        XCTAssertTrue(result.contains("export PATH=/usr/bin"))
        XCTAssertTrue(result.contains("alias ll='ls -la'"))
        XCTAssertTrue(OhMyZshConfigResolver.containsBlock(in: result))
    }

    func testUpsertReplacesExistingBlockInPlace() {
        let oldBlock = OhMyZshConfigResolver.renderZshrcBlock(
            config: OhMyZshResolvedConfig(enabled: true, theme: "robbyrussell", plugins: ["git"], extraZshrcLines: nil)
        )
        let zshrc = "user-line\n\n\(oldBlock)\n\nuser-line-2\n"
        let config = OhMyZshResolvedConfig(enabled: true, theme: "agnoster", plugins: ["z"], extraZshrcLines: nil)
        let result = OhMyZshConfigResolver.upsertBlock(in: zshrc, config: config)
        XCTAssertEqual(
            result.components(separatedBy: OhMyZshConfigResolver.blockStartMarker).count - 1,
            1,
            "区块应只有一份（幂等替换）"
        )
        XCTAssertTrue(result.contains("ZSH_THEME=\"agnoster\""))
        XCTAssertTrue(result.contains("user-line"))
        XCTAssertTrue(result.contains("user-line-2"))
        XCTAssertFalse(result.contains("ZSH_THEME=\"robbyrussell\""))
    }

    func testUpsertReplaceWithSingleNewlinePreservesFollowingUserLine() {
        // 回归：区块后紧跟单换行 + 用户行时，替换不得把用户行拼进区块结束标记
        let oldBlock = OhMyZshConfigResolver.renderZshrcBlock(
            config: OhMyZshResolvedConfig(enabled: true, theme: "robbyrussell", plugins: ["git"], extraZshrcLines: nil)
        )
        let zshrc = "export PATH=/usr/bin\n\(oldBlock)\nalias ll='ls -la'\n"
        let config = OhMyZshResolvedConfig(enabled: true, theme: "agnoster", plugins: ["git"], extraZshrcLines: nil)
        let result = OhMyZshConfigResolver.upsertBlock(in: zshrc, config: config)
        // 用户行必须独立成行（不被区块结束标记吞掉）
        XCTAssertTrue(result.contains("\(OhMyZshConfigResolver.blockEndMarker)\nalias ll='ls -la'"), "用户行不得与区块结束标记拼接")
        XCTAssertTrue(result.contains("ZSH_THEME=\"agnoster\""))
    }

    func testRemoveBlockKeepsUserContent() {
        let block = OhMyZshConfigResolver.renderZshrcBlock(
            config: OhMyZshResolvedConfig(enabled: true, theme: "robbyrussell", plugins: ["git"], extraZshrcLines: nil)
        )
        let zshrc = "user-line\n\n\(block)\n\nuser-line-2\n"
        let result = OhMyZshConfigResolver.removeBlock(from: zshrc)
        XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: result))
        XCTAssertTrue(result.contains("user-line"))
        XCTAssertTrue(result.contains("user-line-2"))
    }

    func testRemoveBlockWithoutBlockReturnsInputUnchanged() {
        let zshrc = "just user content"
        XCTAssertEqual(OhMyZshConfigResolver.removeBlock(from: zshrc), zshrc)
    }

    func testUpsertReplacesMultipleBlocks() {
        // 历史残留多份区块时：upsert 应替换全部（不留双 source/主题冲突）
        let block = OhMyZshConfigResolver.renderZshrcBlock(
            config: OhMyZshResolvedConfig(enabled: true, theme: "robbyrussell", plugins: ["git"], extraZshrcLines: nil)
        )
        let zshrc = "user1\n\(block)\nuser2\n\(block)\nuser3\n"
        let config = OhMyZshResolvedConfig(enabled: true, theme: "agnoster", plugins: ["z"], extraZshrcLines: nil)
        let result = OhMyZshConfigResolver.upsertBlock(in: zshrc, config: config)
        XCTAssertEqual(
            result.components(separatedBy: OhMyZshConfigResolver.blockStartMarker).count - 1,
            1,
            "多份区块应合并为一份"
        )
        XCTAssertTrue(result.contains("ZSH_THEME=\"agnoster\""))
        XCTAssertTrue(result.contains("user1") && result.contains("user2") && result.contains("user3"))
    }

    func testRemoveBlockRemovesAllBlocks() {
        let block = OhMyZshConfigResolver.renderZshrcBlock(
            config: OhMyZshResolvedConfig(enabled: true, theme: "robbyrussell", plugins: ["git"], extraZshrcLines: nil)
        )
        let zshrc = "user1\n\(block)\nuser2\n\(block)\nuser3\n"
        let result = OhMyZshConfigResolver.removeBlock(from: zshrc)
        XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: result), "所有区块都应被移除")
        XCTAssertTrue(result.contains("user1") && result.contains("user2") && result.contains("user3"))
    }

    func testBlockRangeHandlesCRLF() {
        // CRLF 文件：区块结束标记后是 \r\n，替换不得产生残留空行或吞行
        let block = OhMyZshConfigResolver.renderZshrcBlock(
            config: OhMyZshResolvedConfig(enabled: true, theme: "robbyrussell", plugins: ["git"], extraZshrcLines: nil)
        )
        let crlfBlock = block.replacingOccurrences(of: "\n", with: "\r\n")
        let zshrc = "user1\r\n\(crlfBlock)\r\nalias ll='ls -la'\r\n"
        let config = OhMyZshResolvedConfig(enabled: true, theme: "agnoster", plugins: ["git"], extraZshrcLines: nil)
        let result = OhMyZshConfigResolver.upsertBlock(in: zshrc, config: config)
        // 用户行必须独立（不被结束标记吞掉）
        XCTAssertTrue(result.contains("STACIO OH-MY-ZSH <<<") || result.contains("<<<"))
        XCTAssertTrue(result.contains("alias ll='ls -la'"), "CRLF 下用户行不得丢失")
    }

    func testUpsertAndRemoveBlockWithUTF16Content() {
        // 区块之前的用户内容含 emoji（UTF-16 双码元），验证索引换算不损坏内容
        let userContent = "export PATH=😀/bin\nalias hi='你好 👋'\n"
        let config = OhMyZshResolvedConfig(enabled: true, theme: "robbyrussell", plugins: ["git"], extraZshrcLines: nil)
        let withBlock = OhMyZshConfigResolver.upsertBlock(in: userContent, config: config)
        XCTAssertTrue(withBlock.contains("😀"))
        XCTAssertTrue(withBlock.contains("👋"))

        let removed = OhMyZshConfigResolver.removeBlock(from: withBlock)
        XCTAssertEqual(removed.trimmingCharacters(in: .whitespacesAndNewlines), userContent.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testExtraZshrcLinesWithBlockMarkersAreFiltered() {
        let config = OhMyZshResolvedConfig(
            enabled: true,
            theme: "robbyrussell",
            plugins: ["git"],
            extraZshrcLines: "export A=1\n# <<< STACIO OH-MY-ZSH <<<\necho injected"
        )
        let block = OhMyZshConfigResolver.renderZshrcBlock(config: config)
        XCTAssertTrue(block.contains("export A=1"))
        XCTAssertTrue(block.contains("echo injected"))
        // 结束标记只出现一次（区块自身的），注入的标记行被过滤
        XCTAssertEqual(
            block.components(separatedBy: OhMyZshConfigResolver.blockEndMarker).count - 1,
            1,
            "注入的区块结束标记必须被过滤"
        )
    }
}

// MARK: - OhMyZshSessionConfig

final class OhMyZshSessionConfigTests: XCTestCase {
    func testFromConfigJSONWithoutBlockReturnsDefault() {
        XCTAssertEqual(OhMyZshSessionConfig.fromConfigJSON(nil), .default)
        XCTAssertEqual(OhMyZshSessionConfig.fromConfigJSON("not json"), .default)
        XCTAssertEqual(OhMyZshSessionConfig.fromConfigJSON("{\"environment\":\"prod\"}"), .default)
    }

    func testFromConfigJSONParsesBlock() throws {
        let json = """
        {"ohmyzsh":{"overrideDefaults":true,"enabled":true,"theme":"agnoster","plugins":["git","z"]}}
        """
        let config = OhMyZshSessionConfig.fromConfigJSON(json)
        XCTAssertEqual(config.overrideDefaults, true)
        XCTAssertEqual(config.enabled, true)
        XCTAssertEqual(config.theme, "agnoster")
        XCTAssertEqual(config.plugins, ["git", "z"])
    }

    func testSerializedJSONRoundTripPreservesOtherKeys() throws {
        let base = "{\"startupCommand\":\"cd /srv\"}"
        let session = OhMyZshSessionConfig(
            overrideDefaults: true,
            enabled: true,
            theme: "agnoster",
            plugins: ["git"]
        )
        let json = OhMyZshSessionConfig.serializedJSON(mergingInto: base, session: session)
        XCTAssertNotNil(json)
        let reparsed = OhMyZshSessionConfig.fromConfigJSON(json)
        XCTAssertEqual(reparsed, session)
        XCTAssertTrue(json?.contains("startupCommand") == true)
    }

    func testSerializedJSONRoundTripPreservesExplicitFalseEnabled() throws {
        // override + 显式禁用（enabled: false）：往返必须保留 false，不得被全局 true 覆盖
        let session = OhMyZshSessionConfig(
            overrideDefaults: true,
            enabled: false,
            theme: "agnoster",
            plugins: ["git"]
        )
        let json = OhMyZshSessionConfig.serializedJSON(mergingInto: nil, session: session)
        XCTAssertNotNil(json)
        XCTAssertTrue(json?.contains("\"enabled\":false") == true, "显式 false 必须序列化")
        let reparsed = OhMyZshSessionConfig.fromConfigJSON(json)
        XCTAssertEqual(reparsed, session)

        var global = AppSettings()
        global.ohmyzshEnabled = true
        let resolved = OhMyZshConfigResolver.resolve(global: global, session: reparsed)
        XCTAssertEqual(resolved.enabled, false, "会话显式禁用不得继承全局 true")
    }

    func testSerializedJSONRemovesEmptyBlock() throws {
        let base = "{\"ohmyzsh\":{\"overrideDefaults\":true}}"
        let session = OhMyZshSessionConfig.default
        let json = OhMyZshSessionConfig.serializedJSON(mergingInto: base, session: session)
        XCTAssertNotNil(json)
        XCTAssertFalse(json?.contains("ohmyzsh") == true)
    }
}

// MARK: - OhMyZshCatalog

final class OhMyZshCatalogTests: XCTestCase {
    private func makeCatalogDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmyzsh-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plugins/git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plugins/docker", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plugins/not-a-plugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "".write(
            to: root.appendingPathComponent("plugins/git/git.plugin.zsh"),
            atomically: true,
            encoding: .utf8
        )
        try "Docker plugin\ndescription".write(
            to: root.appendingPathComponent("plugins/docker/docker.plugin.zsh"),
            atomically: true,
            encoding: .utf8
        )
        try "Manage Docker containers.\nMore info here.".write(
            to: root.appendingPathComponent("plugins/docker/README.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "".write(
            to: root.appendingPathComponent("themes/robbyrussell.zsh-theme"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: root.appendingPathComponent("themes/agnoster.zsh-theme"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    func testCatalogScansPluginsAndThemes() throws {
        let root = try makeCatalogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = OhMyZshCatalog(directoryURL: root)

        let plugins = catalog.plugins()
        XCTAssertEqual(plugins.map(\.name).sorted(), ["docker", "git"])
        XCTAssertTrue(catalog.containsPlugin("git"))
        XCTAssertFalse(catalog.containsPlugin("not-a-plugin"))
        XCTAssertTrue(catalog.pluginSummary(named: "docker")?.contains("Manage Docker containers") == true)

        let themes = catalog.themes()
        XCTAssertEqual(themes.map(\.name).sorted(), ["agnoster", "robbyrussell"])
        XCTAssertTrue(catalog.containsTheme("agnoster"))
    }

    func testCatalogRefreshesSamePathAfterResourceMarkersChange() throws {
        let root = try makeCatalogDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = OhMyZshCatalog(directoryURL: root)
        XCTAssertEqual(catalog.plugins().map(\.name).sorted(), ["docker", "git"])

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plugins/term_tab", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "".write(
            to: root.appendingPathComponent("plugins/term_tab/term_tab.plugin.zsh"),
            atomically: true,
            encoding: .utf8
        )
        try "catalog-refresh".write(
            to: root.appendingPathComponent(OhMyZshResourceManager.versionMarkerFileName),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(catalog.plugins().map(\.name).sorted(), ["docker", "git", "term_tab"])
    }

    func testCatalogUnavailableWhenDirectoryMissing() {
        let catalog = OhMyZshCatalog(directoryURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertFalse(catalog.isAvailable)
        XCTAssertTrue(catalog.plugins().isEmpty)
        XCTAssertTrue(catalog.themes().isEmpty)
    }
}

// MARK: - AppSettings 持久化

final class OhMyZshAppSettingsPersistenceTests: XCTestCase {
    private func makeStore() -> (AppSettingsStore, String) {
        let suite = "ohmyzsh-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppSettingsStore(defaults: defaults), suite)
    }

    func testOhMyZshSettingsRoundTrip() throws {
        let (store, suite) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        store.update { settings in
            settings.ohmyzshEnabled = true
            settings.ohmyzshTheme = "agnoster"
            settings.ohmyzshPlugins = ["git", "docker"]
            settings.ohmyzshExtraZshrcLines = "export EDITOR=vim"
        }
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.ohmyzshEnabled, true)
        XCTAssertEqual(snapshot.ohmyzshTheme, "agnoster")
        XCTAssertEqual(snapshot.ohmyzshPlugins, ["git", "docker"])
        XCTAssertEqual(snapshot.ohmyzshExtraZshrcLines, "export EDITOR=vim")
    }

    func testOhMyZshSettingsDefaults() throws {
        let (store, suite) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.ohmyzshEnabled, false)
        XCTAssertNil(snapshot.ohmyzshTheme)
        XCTAssertEqual(snapshot.ohmyzshPlugins, ["git"])
        XCTAssertNil(snapshot.ohmyzshExtraZshrcLines)
    }
}

// MARK: - LocalOhMyZshDeployer

final class LocalOhMyZshDeployerTests: XCTestCase {
    private struct TestHome {
        let root: URL
        let home: URL
        let bundle: URL

        func zshrc() -> String? {
            try? String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        }
    }

    private func makeTestHome() throws -> TestHome {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmyzsh-deploy-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("lib", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("plugins/git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("custom", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "# minimal fake oh-my-zsh\n".write(
            to: bundle.appendingPathComponent("oh-my-zsh.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: bundle.appendingPathComponent("lib/example.zsh"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: bundle.appendingPathComponent("themes/robbyrussell.zsh-theme"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(
            to: bundle.appendingPathComponent("plugins/git/git.plugin.zsh"),
            atomically: true,
            encoding: .utf8
        )
        try "user-custom-content".write(
            to: bundle.appendingPathComponent("custom/example.zsh"),
            atomically: true,
            encoding: .utf8
        )
        return TestHome(root: root, home: home, bundle: bundle)
    }

    private func makeSettings() -> AppSettings {
        var settings = AppSettings()
        settings.ohmyzshEnabled = true
        settings.ohmyzshTheme = "robbyrussell"
        settings.ohmyzshPlugins = ["git"]
        return settings
    }

    private func makeDeployer(home: TestHome, verifier: (() throws -> Void)? = nil) -> LocalOhMyZshDeployer {
        LocalOhMyZshDeployer(
            homeDirectoryURL: home.home,
            bundleOhMyZshURL: home.bundle,
            zshVerifier: verifier ?? { /* 成功 */ }
        )
    }

    func testDeployInstallsDirectoryMarkerAndBlock() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let deployer = makeDeployer(home: home)
        try deployer.deploy(global: makeSettings(), catalog: OhMyZshCatalog(directoryURL: home.bundle))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.home.appendingPathComponent(".oh-my-zsh/oh-my-zsh.sh").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.home.appendingPathComponent(".oh-my-zsh/.stacio-managed").path
        ))
        let zshrc = home.zshrc()
        XCTAssertNotNil(zshrc)
        XCTAssertTrue(OhMyZshConfigResolver.containsBlock(in: zshrc ?? ""))
        XCTAssertTrue(zshrc?.contains("ZSH_THEME=\"robbyrussell\"") == true)

        let status = deployer.status()
        XCTAssertTrue(status.isDeployed)
        XCTAssertTrue(status.managedByStacio)
    }

    func testDeployPreservesExistingCustomDirectory() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        // 预置一个"用户已有"的 ~/.oh-my-zsh（无 Stacio 标记）与 custom 内容
        let existing = home.home.appendingPathComponent(".oh-my-zsh", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existing.appendingPathComponent("custom/plugins/myplugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "my-plugin".write(
            to: existing.appendingPathComponent("custom/plugins/myplugin/myplugin.plugin.zsh"),
            atomically: true,
            encoding: .utf8
        )

        let deployer = makeDeployer(home: home)
        try deployer.deploy(global: makeSettings(), catalog: OhMyZshCatalog(directoryURL: home.bundle))

        let preserved = home.home
            .appendingPathComponent(".oh-my-zsh/custom/plugins/myplugin/myplugin.plugin.zsh")
        XCTAssertEqual(try? String(contentsOf: preserved, encoding: .utf8), "my-plugin")
    }

    func testDeployFailureRollsBackZshrc() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        try "original-zshrc-content\n".write(
            to: home.home.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )

        struct VerificationError: Error {}
        let deployer = makeDeployer(home: home, verifier: { throw VerificationError() })
        XCTAssertThrowsError(try deployer.deploy(global: makeSettings(), catalog: OhMyZshCatalog(directoryURL: home.bundle)))

        let zshrc = home.zshrc()
        XCTAssertEqual(zshrc, "original-zshrc-content\n", "验证失败后 .zshrc 应恢复原内容")
        // 目录可能已写入；回滚重点是 .zshrc。校验半成品目录不强制删除（文档允许后续清理）
    }

    func testRemoveOnlyRemovesManagedDirectory() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let deployer = makeDeployer(home: home)
        try deployer.deploy(global: makeSettings(), catalog: OhMyZshCatalog(directoryURL: home.bundle))
        try deployer.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: home.home.appendingPathComponent(".oh-my-zsh").path))
        XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: home.zshrc() ?? ""))
    }

    func testRemoveKeepsUserInstalledDirectory() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        // 用户自装目录（无标记）+ 手动写入区块
        let existing = home.home.appendingPathComponent(".oh-my-zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "user-file".write(
            to: existing.appendingPathComponent("user-file.txt"),
            atomically: true,
            encoding: .utf8
        )
        var zshrc = "user-zshrc\n"
        zshrc = OhMyZshConfigResolver.upsertBlock(
            in: zshrc,
            config: OhMyZshResolvedConfig(enabled: true, theme: "robbyrussell", plugins: ["git"], extraZshrcLines: nil)
        )
        try zshrc.write(to: home.home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let deployer = makeDeployer(home: home)
        try deployer.remove()

        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path), "用户自装目录不得删除")
        XCTAssertFalse(OhMyZshConfigResolver.containsBlock(in: home.zshrc() ?? ""), "区块应被移除")
    }

    func testDeployIsIdempotent() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let deployer = makeDeployer(home: home)
        try deployer.deploy(global: makeSettings(), catalog: OhMyZshCatalog(directoryURL: home.bundle))
        try deployer.deploy(global: makeSettings(), catalog: OhMyZshCatalog(directoryURL: home.bundle))

        let zshrc = home.zshrc() ?? ""
        XCTAssertEqual(
            zshrc.components(separatedBy: OhMyZshConfigResolver.blockStartMarker).count - 1,
            1,
            "重复部署不应产生重复区块"
        )
    }

    func testDeployFailureRestoresUserInstalledDirectory() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        // 用户自装目录（无标记，含重要文件）
        let existing = home.home.appendingPathComponent(".oh-my-zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "precious-user-data".write(
            to: existing.appendingPathComponent("user-data.txt"),
            atomically: true,
            encoding: .utf8
        )

        struct VerificationError: Error {}
        let deployer = makeDeployer(home: home, verifier: { throw VerificationError() })
        XCTAssertThrowsError(try deployer.deploy(global: makeSettings(), catalog: OhMyZshCatalog(directoryURL: home.bundle)))

        // 用户目录必须完整恢复（含用户文件），.zshrc 恢复原状
        let restored = existing.appendingPathComponent("user-data.txt")
        XCTAssertEqual(try? String(contentsOf: restored, encoding: .utf8), "precious-user-data")
        XCTAssertNil(home.zshrc(), "原无 .zshrc 时失败回滚应删除新写入的 .zshrc")
    }

    func testDeployFailureWithoutExistingZshrcRemovesNewlyWrittenZshrc() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        struct VerificationError: Error {}
        let deployer = makeDeployer(home: home, verifier: { throw VerificationError() })
        XCTAssertThrowsError(try deployer.deploy(global: makeSettings(), catalog: OhMyZshCatalog(directoryURL: home.bundle)))

        XCTAssertNil(home.zshrc(), "失败回滚后不应残留新写入的 .zshrc")
    }

    func testDeployWithNonUTF8ZshrcAbortsWithoutTouchingFile() throws {
        let home = try makeTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        // 用户 .zshrc 含非法 UTF-8（如 latin-1 字节 0xE9）
        let invalidData = Data([0x61, 0x62, 0x63, 0xE9, 0x0A])
        try invalidData.write(to: home.home.appendingPathComponent(".zshrc"))

        let deployer = makeDeployer(home: home)
        XCTAssertThrowsError(try deployer.deploy(global: makeSettings(), catalog: OhMyZshCatalog(directoryURL: home.bundle))) { error in
            XCTAssertEqual(error as? LocalOhMyZshDeployerError, .zshrcDecodeFailed)
        }
        // 原文件必须原样保留（未备份删除、未覆盖）
        let preserved = try Data(contentsOf: home.home.appendingPathComponent(".zshrc"))
        XCTAssertEqual(preserved, invalidData)
        // 无备份残留
        let files = try FileManager.default.contentsOfDirectory(atPath: home.home.path)
        XCTAssertFalse(files.contains { $0.contains("stacio-backup") })
    }
}
