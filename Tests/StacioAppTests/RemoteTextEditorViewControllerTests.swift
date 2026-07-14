import AppKit
import WebKit
import XCTest
@testable import StacioApp

@MainActor
final class RemoteTextEditorViewControllerTests: XCTestCase {
    func testEditorLoadsMonacoWorkspaceWithLanguageTabsAndStatusMetadata() throws {
        let suiteName = "StacioEditorThemeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalTheme = .light
        }
        let fileURL = try makeTemporaryEditorFile(
            name: "config.swift",
            contents: "let enabled = true\nprint(enabled)\n"
        )
        let controller = RemoteTextEditorViewController(
            localURL: fileURL,
            settingsStore: settingsStore
        )

        controller.loadView()

        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        XCTAssertTrue(controller.isMonacoBackedForTesting)
        XCTAssertEqual(controller.currentTextForTesting, "let enabled = true\nprint(enabled)\n")
        XCTAssertEqual(controller.languageIdentifierForTesting, "swift")
        XCTAssertEqual(controller.currentThemeIdentifierForTesting, "vs")
        XCTAssertEqual(controller.encodingTextForTesting, "UTF-8")
        XCTAssertEqual(controller.tabTitlesForTesting, ["config.swift"])
        XCTAssertEqual(webView.navigationDelegate === controller, true)
    }

    func testEditorReappliesMonacoThemeWhenAppThemePreferenceChanges() throws {
        let suiteName = "StacioEditorLiveThemeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalTheme = .light
        }
        let fileURL = try makeTemporaryEditorFile(
            name: "service.conf",
            contents: "enabled=true\n"
        )
        let controller = RemoteTextEditorViewController(
            localURL: fileURL,
            settingsStore: settingsStore
        )
        controller.loadView()

        XCTAssertEqual(controller.currentThemeIdentifierForTesting, "vs")

        settingsStore.update { settings in
            settings.terminalTheme = .dark
        }

        XCTAssertEqual(controller.currentThemeIdentifierForTesting, "stacio-stacio-dark")
    }

    func testEditorReceivesTerminalFontPreferencesForMonaco() throws {
        let suiteName = "StacioEditorFontSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalFontFamily = .jetBrainsMono
            settings.terminalFontSize = 16
            settings.terminalTheme = .dark
            settings.terminalBuiltInThemeID = "nordic-ops"
        }
        let fileURL = try makeTemporaryEditorFile(
            name: "Dockerfile",
            contents: "FROM centos:7\nRUN yum install -y docker\n"
        )
        let controller = RemoteTextEditorViewController(
            localURL: fileURL,
            settingsStore: settingsStore
        )
        controller.loadView()
        controller.markEditorReadyForTesting()
        controller.resetEditorFunctionCallsForTesting()

        settingsStore.update { settings in
            settings.terminalFontFamily = .firaCode
            settings.terminalFontSize = 17
        }

        let script = try XCTUnwrap(controller.editorFunctionScriptsForTesting.last)
        XCTAssertTrue(script.contains(#""theme":"stacio-nordic-ops""#))
        XCTAssertTrue(script.contains(#""fontSize":17"#))
        XCTAssertTrue(script.contains("Fira Code"))
        XCTAssertTrue(script.contains("monospace"))
        XCTAssertEqual(controller.languageIdentifierForTesting, "dockerfile")
    }

    func testEditorReceivesBuiltInTerminalThemePaletteForMonaco() throws {
        let suiteName = "StacioEditorBuiltInThemeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalTheme = .dark
            settings.terminalBuiltInThemeID = "nordic-ops"
        }
        let fileURL = try makeTemporaryEditorFile(
            name: "deployment.yaml",
            contents: "apiVersion: apps/v1\nkind: Deployment\n"
        )
        let controller = RemoteTextEditorViewController(
            localURL: fileURL,
            settingsStore: settingsStore
        )

        controller.loadView()
        controller.markEditorReadyForTesting()
        controller.resetEditorFunctionCallsForTesting()
        settingsStore.update { settings in
            settings.terminalBuiltInThemeID = "graphite"
        }

        let script = try XCTUnwrap(controller.editorFunctionScriptsForTesting.last)
        XCTAssertEqual(controller.currentThemeIdentifierForTesting, "stacio-graphite")
        XCTAssertTrue(script.contains(#""theme":"stacio-graphite""#))
        XCTAssertTrue(script.contains(#""base":"vs-dark""#))
        XCTAssertTrue(script.contains(##""editor.background":"#111316""##))
        XCTAssertTrue(script.contains(##""editor.foreground":"#E6E8EB""##))
        XCTAssertTrue(script.contains(##""editorLineNumber.foreground":"#5C6370""##))
        XCTAssertTrue(controller.editorHTMLForTesting.contains("monaco.editor.defineTheme(theme,"))
    }

    func testLinuxConfigurationFilesMapToIniAndYamlLanguages() {
        for fileName in ["app.conf", "agent.cfg", "server.ini", "nginx.service", "portal.desktop"] {
            XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: fileName), "ini", fileName)
        }
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "compose.yml"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "compose.override.yml"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "docker-compose.prod.yaml"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "docker-compose.yaml"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "compose.staging.yaml"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "deployment.yaml"), "yaml")
        for fileName in [
            "sshd_config",
            "ssh_config",
            "sudoers",
            "fstab",
            "crontab",
            "hosts",
            "hostname",
            "resolv.conf",
            "sysctl.conf",
            "limits.conf",
            "logrotate.conf",
            "chrony.conf",
            "ntp.conf",
            "yum.conf",
            "dnf.conf",
            "supervisord.conf",
            "grafana.ini"
        ] {
            XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: fileName), "ini", fileName)
        }
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "Dockerfile"), "dockerfile")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "Dockerfile.prod"), "dockerfile")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "Containerfile"), "dockerfile")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "Containerfile.dev"), "dockerfile")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: ".env.production"), "ini")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "terraform.tfvars"), "hcl")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "main.tf"), "hcl")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "nginx.conf"), "ini")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "Chart.yaml"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "values.yaml"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "prometheus.yml"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "cloud-init.yaml"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "prod.kubeconfig"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "kustomization.yaml"), "yaml")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "daemon.json"), "json")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "containers.conf"), "ini")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "registries.conf"), "ini")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "sources.list"), "ini")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "ubuntu.sources"), "ini")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "nginx.socket"), "ini")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "cleanup.timer"), "ini")
        XCTAssertEqual(StacioFileDisplay.languageIdentifier(forFileName: "data.mount"), "ini")
    }

    func testCommonProgrammingFileExtensionsMapToMonacoLanguages() {
        let cases: [(String, String)] = [
            ("app.py", "python"),
            ("server.js", "javascript"),
            ("component.jsx", "javascript"),
            ("types.ts", "typescript"),
            ("view.tsx", "typescript"),
            ("main.go", "go"),
            ("lib.rs", "rust"),
            ("deploy.sh", "shell"),
            ("profile.bash", "shell"),
            ("config.yaml", "yaml"),
            ("package.json", "json"),
            ("README.md", "markdown"),
            ("query.sql", "sql"),
            ("app.conf", "ini"),
            ("settings.ini", "ini"),
            ("service.dockerfile", "dockerfile"),
            ("style.scss", "scss"),
            ("theme.less", "less"),
            ("script.ps1", "powershell"),
            ("analysis.r", "r"),
            ("tool.pl", "perl"),
            ("widget.dart", "dart"),
            ("job.scala", "scala"),
            ("notes.unknownext", "plaintext")
        ]

        for (fileName, expectedLanguage) in cases {
            XCTAssertEqual(
                StacioFileDisplay.languageIdentifier(forFileName: fileName),
                expectedLanguage,
                fileName
            )
        }
    }

    func testMonacoStatusLanguageSelectorCanSwitchModelLanguage() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.py", contents: "print('ok')\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)

        controller.loadView()

        let html = controller.editorHTMLForTesting
        XCTAssertTrue(html.contains(#"<select id="language""#))
        XCTAssertTrue(html.contains("populateLanguageOptions()"))
        XCTAssertTrue(html.contains("setActiveLanguage(languageIdentifier)"))
        XCTAssertTrue(html.contains("monaco.editor.setModelLanguage(model, languageIdentifier)"))
        XCTAssertTrue(html.contains("addEventListener('change'"))
    }

    func testEditorRejectsNonUTF8ContentInsteadOfTreatingExtensionAsDecider() throws {
        let directory = try makeTemporaryEditorDirectory()
        let fileURL = directory.appendingPathComponent("unknown.bin")
        try Data([0xff, 0xfe, 0x00]).write(to: fileURL)

        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()

        XCTAssertFalse(controller.canEditTextForTesting)
        XCTAssertTrue(controller.editorErrorTextForTesting?.contains("UTF-8") ?? false)
        XCTAssertEqual(controller.currentTextForTesting, "")
        XCTAssertFalse(controller.hasUnsavedChangesForTesting)
    }

    func testEditorKeepsMultipleOpenFilesAsSwitchableDirtyTabs() throws {
        let firstURL = try makeTemporaryEditorFile(name: "first.conf", contents: "enabled=false\n")
        let secondURL = try makeTemporaryEditorFile(name: "second.yaml", contents: "enabled: true\n")
        let controller = RemoteTextEditorViewController(localURL: firstURL)
        controller.loadView()

        controller.openDocumentForTesting(localURL: secondURL)
        controller.replaceTextForTesting("enabled: false\n")

        XCTAssertEqual(controller.tabTitlesForTesting, ["first.conf", "second.yaml"])
        XCTAssertEqual(controller.dirtyTabTitlesForTesting, ["second.yaml"])
        XCTAssertEqual(controller.activeFileNameForTesting, "second.yaml")
        XCTAssertEqual(controller.languageIdentifierForTesting, "yaml")

        controller.switchToDocumentForTesting(fileName: "first.conf")

        XCTAssertEqual(controller.activeFileNameForTesting, "first.conf")
        XCTAssertEqual(controller.currentTextForTesting, "enabled=false\n")
        XCTAssertEqual(controller.languageIdentifierForTesting, "ini")
    }

    func testEditorKeepsTextImagesAudioAndVideoInOneTabWorkspace() throws {
        let textURL = try makeTemporaryEditorFile(name: "config.conf", contents: "enabled=true\n")
        let imageURL = try makeTemporaryEditorFile(
            name: "screenshot.png",
            data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/luzX9wAAAABJRU5ErkJggg==")!
        )
        let audioURL = try makeTemporaryEditorFile(name: "clip.mp3", data: Data([0x49, 0x44, 0x33, 0x04]))
        let videoURL = try makeTemporaryEditorFile(name: "demo.mp4", data: Data([0x00, 0x00, 0x00, 0x18]))
        let controller = RemoteTextEditorViewController(localURL: textURL)
        controller.loadView()

        controller.openDocumentForTesting(localURL: imageURL)
        controller.openDocumentForTesting(localURL: audioURL)
        controller.openDocumentForTesting(localURL: videoURL)

        XCTAssertEqual(controller.tabTitlesForTesting, ["config.conf", "screenshot.png", "clip.mp3", "demo.mp4"])
        XCTAssertEqual(controller.activeFileNameForTesting, "demo.mp4")
        XCTAssertEqual(controller.activeDocumentDisplayModeForTesting, "video")
        XCTAssertTrue(controller.activeMediaPreviewSourceForTesting?.hasPrefix("data:video/mp4;base64,") ?? false)

        controller.switchToDocumentForTesting(fileName: "screenshot.png")

        XCTAssertEqual(controller.activeDocumentDisplayModeForTesting, "image")
        XCTAssertTrue(controller.activeMediaPreviewSourceForTesting?.hasPrefix("data:image/png;base64,") ?? false)

        controller.switchToDocumentForTesting(fileName: "clip.mp3")

        XCTAssertEqual(controller.activeDocumentDisplayModeForTesting, "audio")
        XCTAssertTrue(controller.activeMediaPreviewSourceForTesting?.hasPrefix("data:audio/mpeg;base64,") ?? false)

        controller.switchToDocumentForTesting(fileName: "config.conf")

        XCTAssertEqual(controller.activeDocumentDisplayModeForTesting, "text")
        XCTAssertEqual(controller.currentTextForTesting, "enabled=true\n")
    }

    func testEditorTabsExposeOverflowArrowControls() throws {
        let fileURL = try makeTemporaryEditorFile(name: "notes.txt", contents: "hello\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)

        controller.loadView()

        let html = controller.editorHTMLForTesting
        XCTAssertTrue(html.contains(#"id="tab-scroll-left""#))
        XCTAssertTrue(html.contains(#"id="tab-scroll-right""#))
        XCTAssertTrue(html.contains("scrollTabsBy(-1)"))
        XCTAssertTrue(html.contains("scrollTabsBy(1)"))
        XCTAssertTrue(html.contains("ensureActiveTabVisible()"))
    }

    func testEditorExposesActiveAndOpenDocumentURLsForInspectorBackup() throws {
        let firstURL = try makeTemporaryEditorFile(name: "first.conf", contents: "enabled=false\n")
        let secondURL = try makeTemporaryEditorFile(name: "second.yaml", contents: "enabled: true\n")
        let controller = RemoteTextEditorViewController(localURL: firstURL)

        controller.openDocumentForTesting(localURL: secondURL)

        XCTAssertEqual(controller.documentLocalURLsForTesting, [firstURL, secondURL])
        XCTAssertEqual(controller.activeDocumentLocalURLForTesting, secondURL)

        controller.switchToDocumentForTesting(fileName: "first.conf")

        XCTAssertEqual(controller.activeDocumentLocalURLForTesting, firstURL)
    }

    func testCommandSaveWritesLocalCopyAndInvokesRemoteSaveHandler() throws {
        let fileURL = try makeTemporaryEditorFile(name: "sshd_config", contents: "PermitRootLogin no\n")
        var savedURLs: [URL] = []
        let controller = RemoteTextEditorViewController(
            localURL: fileURL,
            onSave: { url in savedURLs.append(url) }
        )
        controller.loadView()

        controller.replaceTextForTesting("PermitRootLogin prohibit-password\n")
        XCTAssertTrue(controller.hasUnsavedChangesForTesting)

        try controller.performSaveForTesting()

        XCTAssertEqual(try String(contentsOf: fileURL), "PermitRootLogin prohibit-password\n")
        XCTAssertEqual(savedURLs, [fileURL])
        XCTAssertFalse(controller.hasUnsavedChangesForTesting)
    }

    func testEditorRegistersKeyboardShortcutsForSaveFindAndReplace() throws {
        let fileURL = try makeTemporaryEditorFile(name: "notes.txt", contents: "hello\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        controller.markEditorReadyForTesting()
        controller.resetEditorFunctionCallsForTesting()

        XCTAssertTrue(controller.view.performKeyEquivalent(with: commandKeyEvent("s", keyCode: 1)))
        XCTAssertEqual(controller.editorFunctionCallsForTesting, ["saveActiveDocument"])

        controller.resetEditorFunctionCallsForTesting()
        XCTAssertTrue(controller.view.performKeyEquivalent(with: commandKeyEvent("f", keyCode: 3)))
        XCTAssertEqual(controller.editorFunctionCallsForTesting, ["runEditorAction"])
        XCTAssertTrue(controller.editorFunctionScriptsForTesting.last?.contains(#""actions.find""#) ?? false)

        controller.resetEditorFunctionCallsForTesting()
        XCTAssertTrue(controller.view.performKeyEquivalent(with: commandKeyEvent("h", keyCode: 4)))
        XCTAssertEqual(controller.editorFunctionCallsForTesting, ["runEditorAction"])
        XCTAssertTrue(
            controller.editorFunctionScriptsForTesting.last?
                .contains(#""editor.action.startFindReplaceAction""#) ?? false
        )
    }

    func testEditorDisplayOptionsPersistAndToolbarTogglesUpdateMonaco() throws {
        let suiteName = "StacioEditorDisplayOptions-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var options = RemoteTextEditorDisplayOptions.load(defaults: defaults)
        XCTAssertEqual(options, .defaultValue)

        options.lineNumbersEnabled = false
        options.wordWrapEnabled = true
        options.minimapEnabled = false
        options.save(defaults: defaults)
        XCTAssertEqual(RemoteTextEditorDisplayOptions.load(defaults: defaults), options)

        let fileURL = try makeTemporaryEditorFile(name: "notes.txt", contents: "hello\n")
        let controller = RemoteTextEditorViewController(
            localURL: fileURL,
            editorOptionsDefaults: defaults
        )
        controller.loadView()
        controller.markEditorReadyForTesting()
        controller.resetEditorFunctionCallsForTesting()

        let lineNumbersButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.Toolbar.lineNumbers") as? NSButton
        )
        let wordWrapButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.Toolbar.wordWrap") as? NSButton
        )
        let minimapButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.Toolbar.minimap") as? NSButton
        )

        XCTAssertEqual(lineNumbersButton.state, .off)
        XCTAssertEqual(wordWrapButton.state, .on)
        XCTAssertEqual(minimapButton.state, .off)

        wordWrapButton.performClick(nil)

        XCTAssertEqual(RemoteTextEditorDisplayOptions.load(defaults: defaults).wordWrapEnabled, false)
        XCTAssertEqual(controller.editorFunctionCallsForTesting, ["applyDisplayOptions"])
        XCTAssertTrue(controller.editorFunctionScriptsForTesting.last?.contains(#""wordWrapEnabled":false"#) ?? false)
        XCTAssertTrue(controller.editorHTMLForTesting.contains("editor.updateOptions({"))
        XCTAssertTrue(controller.editorHTMLForTesting.contains("lineNumbers: options.lineNumbersEnabled ? 'on' : 'off'"))
        XCTAssertTrue(controller.editorHTMLForTesting.contains("minimap: { enabled: options.minimapEnabled }"))
    }

    func testToolbarFindAndReplaceButtonsTriggerMonacoActions() throws {
        let fileURL = try makeTemporaryEditorFile(name: "notes.txt", contents: "hello\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        controller.markEditorReadyForTesting()
        controller.resetEditorFunctionCallsForTesting()

        let findButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.Toolbar.find") as? NSButton
        )
        let replaceButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.Toolbar.replace") as? NSButton
        )

        findButton.performClick(nil)
        replaceButton.performClick(nil)

        XCTAssertEqual(controller.editorFunctionCallsForTesting, ["runEditorAction", "runEditorAction"])
        XCTAssertTrue(controller.editorFunctionScriptsForTesting[0].contains(#""actions.find""#))
        XCTAssertTrue(controller.editorFunctionScriptsForTesting[1].contains(#""editor.action.startFindReplaceAction""#))
    }

    func testEditorExposesSavedDirtySavingAndFailedSaveStates() throws {
        let fileURL = try makeTemporaryEditorFile(name: "app.conf", contents: "enabled=false\n")
        var shouldFail = false
        var observedSavingState = false
        let controller = RemoteTextEditorViewController(
            localURL: fileURL,
            onSave: { _ in
                observedSavingState = true
                if shouldFail {
                    throw RemoteTextEditorError.openFailed("app.conf", "upload failed")
                }
            }
        )

        controller.loadView()

        XCTAssertEqual(controller.activeSaveStateForTesting, .saved)
        XCTAssertEqual(controller.activeSaveStateTextForTesting, "已保存")

        controller.replaceTextForTesting("enabled=true\n")

        XCTAssertEqual(controller.activeSaveStateForTesting, .dirty)
        XCTAssertEqual(controller.activeSaveStateTextForTesting, "未保存改动")

        shouldFail = true
        XCTAssertThrowsError(try controller.performSaveForTesting())

        XCTAssertEqual(controller.activeSaveStateForTesting, .failed)
        XCTAssertEqual(controller.activeSaveStateTextForTesting, "保存失败：无法打开“app.conf”：upload failed")
        XCTAssertTrue(controller.activeSaveStatusIsErrorForTesting)

        shouldFail = false
        try controller.performSaveForTesting()

        XCTAssertEqual(controller.activeSaveStateForTesting, .saved)
        XCTAssertEqual(controller.activeSaveStateTextForTesting, "已保存")
        XCTAssertTrue(observedSavingState)
        XCTAssertTrue(controller.editorHTMLForTesting.contains("saveStateText"))
        XCTAssertTrue(controller.editorHTMLForTesting.contains("window.setTimeout(() => {"))
    }

    func testWindowTitleUsesEditedDotAndClearsAfterSave() throws {
        let fileURL = try makeTemporaryEditorFile(name: "app.toml", contents: "debug = false\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        let windowController = RemoteTextEditorWindowController(editorViewController: controller)
        defer { windowController.close() }
        controller.loadView()

        XCTAssertEqual(windowController.window?.title, "app.toml")
        XCTAssertEqual(windowController.window?.isDocumentEdited, false)

        controller.replaceTextForTesting("debug = true\n")

        XCTAssertEqual(windowController.window?.title, "● app.toml")
        XCTAssertEqual(windowController.window?.isDocumentEdited, true)

        try controller.performSaveForTesting()

        XCTAssertEqual(windowController.window?.title, "app.toml")
        XCTAssertEqual(windowController.window?.isDocumentEdited, false)
    }

    func testEditorBuildsAIQuestionForActiveRemoteTextDocument() throws {
        let descriptor = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/nginx/nginx.conf",
            fileName: "nginx.conf",
            content: "server {\n  listen 80;\n  proxy_pass http://127.0.0.1:3000;\n}\n",
            byteCount: 64
        )
        let controller = RemoteTextEditorViewController(document: descriptor)
        var prompts: [String] = []
        controller.onAIQuestionRequested = { prompts.append($0) }

        controller.loadView()
        controller.requestAIForActiveDocumentForTesting()

        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains("解释并排查这个远程文件"))
        XCTAssertTrue(prompt.contains("nginx.conf"))
        XCTAssertTrue(prompt.contains("/etc/nginx/nginx.conf"))
        XCTAssertTrue(prompt.contains("ini"))
        XCTAssertTrue(prompt.contains("proxy_pass"))
    }

    func testEditorUsesOnlyMonacoTabsForTopChromeAndKeepsCloseOnLeft() throws {
        let fileURL = try makeTemporaryEditorFile(name: "notes.txt", contents: "hello\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        var closeRequestCount = 0
        controller.onCloseRequested = {
            closeRequestCount += 1
        }

        controller.loadView()
        controller.requestCloseForTesting()

        XCTAssertEqual(closeRequestCount, 1)
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Editor.close"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Editor.fileName"))
        let html = controller.editorHTMLForTesting
        XCTAssertTrue(html.contains(#".tab { display: inline-flex; align-items: center; gap: 7px; min-width: 104px; max-width: 220px; padding: 0 12px 0 5px;"#))
        XCTAssertTrue(html.contains(#"body.light .tab { color: #4b5563; }"#))
        XCTAssertTrue(html.contains(#"body.light .tab.active { background: #ffffff; color: #111827; }"#))
        XCTAssertTrue(html.contains(#".close { position: relative; width: 16px; height: 16px; border: 0; border-radius: 999px; background: currentColor;"#))
        XCTAssertTrue(html.contains(#".close::before, .close::after"#))
        XCTAssertTrue(html.contains(
            #"<span class="close" data-close="${escapeHTML(document.id)}" aria-label="关闭选项卡"></span><span class="dirty"></span><span class="tab-title">"#
        ))
    }

    func testMonacoTabsSwitchThroughRobustContainerClickHandling() throws {
        let fileURL = try makeTemporaryEditorFile(name: "first.conf", contents: "enabled=false\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)

        controller.loadView()

        let html = controller.editorHTMLForTesting
        XCTAssertTrue(html.contains("addEventListener('click', handleTabsClick)"))
        XCTAssertTrue(html.contains("event.target instanceof Element"))
        XCTAssertTrue(html.contains("closest('.tab')"))
        XCTAssertTrue(html.contains("function switchToTab(targetID)"))
        XCTAssertTrue(html.contains("if (switchToTab(targetID))"))
    }

    func testMonacoTabsSwitchOnMouseDownSoWebViewFocusDoesNotSwallowTabSelection() throws {
        let fileURL = try makeTemporaryEditorFile(name: "first.conf", contents: "enabled=false\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)

        controller.loadView()

        let html = controller.editorHTMLForTesting
        XCTAssertTrue(html.contains("addEventListener('mousedown', handleTabsMouseDown)"))
        XCTAssertTrue(html.contains("function handleTabsMouseDown(event)"))
        XCTAssertTrue(html.contains("return activateTabFromEvent(event)"))
        XCTAssertTrue(html.contains("const closeButton = target.closest('[data-close]')"))
    }

    func testWebSwitchTabMessageDoesNotPushStaleActiveTabBeforeActivatingTarget() throws {
        let firstURL = try makeTemporaryEditorFile(name: "first.conf", contents: "enabled=false\n")
        let secondURL = try makeTemporaryEditorFile(name: "second.yaml", contents: "enabled: true\n")
        let controller = RemoteTextEditorViewController(localURL: firstURL)

        controller.loadView()
        controller.markEditorReadyForTesting()
        controller.openDocumentForTesting(localURL: secondURL)
        controller.resetEditorFunctionCallsForTesting()

        controller.receiveSwitchTabMessageForTesting(
            targetFileName: "first.conf",
            currentFileName: "second.yaml",
            currentContent: "enabled: false\n"
        )

        XCTAssertEqual(controller.activeFileNameForTesting, "first.conf")
        XCTAssertEqual(controller.dirtyTabTitlesForTesting, ["second.yaml"])
        XCTAssertEqual(controller.editorFunctionCallsForTesting, ["activateDocument"])
    }

    func testMonacoTabsUsePointerDownCaptureForRepeatableFluidSwitching() throws {
        let fileURL = try makeTemporaryEditorFile(name: "first.conf", contents: "enabled=false\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)

        controller.loadView()

        let html = controller.editorHTMLForTesting
        XCTAssertTrue(html.contains("let lastHandledTabPointerDownID = null;"))
        XCTAssertTrue(html.contains("function handleTabsPointerDown(event)"))
        XCTAssertTrue(html.contains("if (event.button !== 0) { return; }"))
        XCTAssertTrue(html.contains("lastHandledTabPointerDownID = event.pointerId;"))
        XCTAssertTrue(html.contains("addEventListener('pointerdown', handleTabsPointerDown, { capture: true })"))
        XCTAssertTrue(html.contains("if (lastHandledTabPointerDownID === event.pointerId)"))
    }

    func testEditorDisablesMarkdownHTMLSurfacesForRemoteContentSafety() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)

        controller.loadView()

        let html = controller.editorHTMLForTesting
        XCTAssertTrue(html.contains("hover: { enabled: false }"))
        XCTAssertTrue(html.contains("links: false"))
        XCTAssertTrue(html.contains("quickSuggestions: false"))
        XCTAssertTrue(html.contains("suggestOnTriggerCharacters: false"))
        XCTAssertTrue(html.contains("parameterHints: { enabled: false }"))
        XCTAssertTrue(html.contains("codeLens: false"))
    }

    func testMonacoEditorChromeUsesSimplifiedChineseLanguagePack() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)

        controller.loadView()

        let html = controller.editorHTMLForTesting
        XCTAssertTrue(html.contains("window.MonacoEnvironment"))
        XCTAssertTrue(html.contains("Locale: 'zh-cn'"))
        XCTAssertTrue(html.contains(#""vs/nls": { availableLanguages: { "*": "zh-cn" } }"#))
        XCTAssertTrue(html.contains("vs/nls.messages.zh-cn.js"))
    }

    func testDirtyEditorPromptsToSaveBeforeClosing() throws {
        let fileURL = try makeTemporaryEditorFile(name: "app.toml", contents: "debug = false\n")
        let confirmer = RecordingRemoteTextEditorCloseConfirmer(decision: .save)
        var savedURLs: [URL] = []
        let controller = RemoteTextEditorViewController(
            localURL: fileURL,
            onSave: { url in savedURLs.append(url) }
        )
        let windowController = RemoteTextEditorWindowController(
            editorViewController: controller,
            closeConfirmer: confirmer
        )
        defer { windowController.close() }
        controller.loadView()
        controller.replaceTextForTesting("debug = true\n")

        XCTAssertTrue(windowController.windowShouldClose(try XCTUnwrap(windowController.window)))

        XCTAssertEqual(confirmer.promptedFileNames, ["app.toml"])
        XCTAssertEqual(savedURLs, [fileURL])
        XCTAssertEqual(try String(contentsOf: fileURL), "debug = true\n")
        XCTAssertFalse(controller.hasUnsavedChangesForTesting)
    }
}

private func makeTemporaryEditorFile(name: String, contents: String) throws -> URL {
    let directory = try makeTemporaryEditorDirectory()
    let fileURL = directory.appendingPathComponent(name)
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
}

private func makeTemporaryEditorFile(name: String, data: Data) throws -> URL {
    let directory = try makeTemporaryEditorDirectory()
    let fileURL = directory.appendingPathComponent(name)
    try data.write(to: fileURL)
    return fileURL
}

private func makeTemporaryEditorDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StacioEditorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func commandKeyEvent(_ characters: String, keyCode: UInt16) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}

private final class RecordingRemoteTextEditorCloseConfirmer: RemoteTextEditorCloseConfirming {
    let decision: RemoteTextEditorCloseDecision
    private(set) var promptedFileNames: [String] = []

    init(decision: RemoteTextEditorCloseDecision) {
        self.decision = decision
    }

    func confirmClose(fileName: String, parentWindow: NSWindow?) -> RemoteTextEditorCloseDecision {
        promptedFileNames.append(fileName)
        return decision
    }
}

private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
