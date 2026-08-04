import AppKit
import WebKit
import XCTest
@testable import StacioApp

@MainActor
final class RemoteTextEditorViewControllerTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func waitForLocalDocumentLoads(
        _ controller: RemoteTextEditorViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntil { controller.hasPendingLocalDocumentLoadsForTesting == false },
            "Timed out waiting for local editor document loading",
            file: file,
            line: line
        )
    }

    private func waitForSaveState(
        _ expectedState: RemoteTextEditorSaveState,
        in controller: RemoteTextEditorViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntil { controller.activeSaveStateForTesting == expectedState },
            "Timed out waiting for save state \(expectedState)",
            file: file,
            line: line
        )
    }

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
        waitForLocalDocumentLoads(controller)

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
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: fileURL)

        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        waitForLocalDocumentLoads(controller)

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
        waitForLocalDocumentLoads(controller)

        controller.openDocumentForTesting(localURL: secondURL)
        waitForLocalDocumentLoads(controller)
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
        waitForLocalDocumentLoads(controller)

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

    func testClosingRemoteMediaTabUnregistersReadSource() throws {
        let invalidation = EditorMediaInvalidationCounter()
        let sourceURL = RemoteFileOnlineMediaRegistry.shared.register(
            fileName: "clip.mp4",
            mimeType: "video/mp4",
            byteCount: 4,
            onInvalidate: { invalidation.increment() },
            reader: { _, _ in Data([0, 0, 0, 4]) }
        )
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        editor.openDocument(RemoteTextEditorDocumentDescriptor(
            remotePath: "/srv/clip.mp4",
            fileName: "clip.mp4",
            content: "",
            contentKind: .video,
            previewSource: sourceURL.absoluteString,
            byteCount: 4
        ))

        XCTAssertNotNil(RemoteFileOnlineMediaRegistry.shared.source(for: sourceURL))
        editor.closeDocumentForTesting(fileName: "clip.mp4")

        XCTAssertNil(RemoteFileOnlineMediaRegistry.shared.source(for: sourceURL))
        XCTAssertEqual(invalidation.value, 1)
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
        waitForLocalDocumentLoads(controller)

        controller.replaceTextForTesting("PermitRootLogin prohibit-password\n")
        XCTAssertTrue(controller.hasUnsavedChangesForTesting)

        try controller.performSaveForTesting()
        waitForSaveState(.saved, in: controller)

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

    func testToolbarAddsStableDragHandleAndTwoSegmentPresentationControl() throws {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        editor.loadView()

        let dragHandle = try XCTUnwrap(
            editor.view.firstSubview(withIdentifier: "Stacio.Editor.Toolbar.dragHandle")
        )
        let control = try XCTUnwrap(
            editor.view.firstSubview(withIdentifier: "Stacio.Editor.Toolbar.presentation")
                as? NSSegmentedControl
        )

        XCTAssertEqual(control.segmentCount, 2)
        XCTAssertEqual(editor.presentationDisplayImageNameForTesting, "display")
        XCTAssertEqual(control.toolTip, L10n.EditorPresentation.detach)
        XCTAssertEqual(control.accessibilityLabel(), L10n.EditorPresentation.detach)
        XCTAssertGreaterThanOrEqual(dragHandle.frame.width, 40)
        XCTAssertLessThan(
            dragHandle.contentHuggingPriority(for: .horizontal),
            .defaultHigh
        )
        XCTAssertEqual(control.frame.height, 24, accuracy: 1)
    }

    func testToolbarPresentationControlSwitchesDetachRedockAndLockSemantics() {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        editor.loadView()

        editor.updatePresentationControls(.init(
            mode: .docked,
            hasEditor: true,
            isTransitioning: false,
            detachedFeatureEnabled: false
        ))
        XCTAssertEqual(editor.presentationMainImageNameForTesting, "lock")
        XCTAssertTrue((editor.view.firstSubview(
            withIdentifier: "Stacio.Editor.Toolbar.presentation"
        ) as? NSSegmentedControl)?.isEnabled == true)
        XCTAssertEqual(
            editor.presentationMainTooltipForTesting,
            L10n.EditorPresentation.detachRequiresLicense
        )

        editor.updatePresentationControls(.init(
            mode: .floating,
            hasEditor: true,
            isTransitioning: false,
            detachedFeatureEnabled: true
        ))
        XCTAssertEqual(editor.presentationMainTooltipForTesting, L10n.EditorPresentation.redock)
    }

    func testToolbarControlsFitAtMinimumEditorWidthWithoutOverlap() {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        editor.loadView()
        editor.view.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
        editor.view.layoutSubtreeIfNeeded()

        let controls = editor.toolbarControlFramesForTesting.sorted { $0.minX < $1.minX }
        for pair in zip(controls, controls.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.maxX, pair.1.minX)
        }
        XCTAssertTrue(controls.allSatisfy { editor.view.bounds.contains($0) })
    }

    func testToolbarRestoresLifecycleAndFileOperationControls() throws {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        editor.loadView()

        for identifier in [
            "Stacio.Editor.Toolbar.close",
            "Stacio.Editor.Toolbar.collapse",
            "Stacio.Editor.Toolbar.backup",
            "Stacio.Editor.Toolbar.askAI",
            "Stacio.Editor.Toolbar.restore"
        ] {
            XCTAssertNotNil(
                editor.view.firstSubview(withIdentifier: identifier) as? NSButton,
                identifier
            )
        }
    }

    func testToolbarLifecycleAndFileOperationControlsInvokeRealCallbacks() throws {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        var closeCount = 0
        var collapseCount = 0
        var backupCount = 0
        var aiCount = 0
        var restoreCount = 0
        editor.onCloseRequested = { closeCount += 1 }
        editor.onToggleCollapseRequested = { collapseCount += 1 }
        editor.onBackupRequested = { backupCount += 1 }
        editor.onAIQuestionRequested = { _ in aiCount += 1 }
        editor.onRestoreRequested = { restoreCount += 1 }
        editor.loadView()

        for identifier in [
            "Stacio.Editor.Toolbar.collapse",
            "Stacio.Editor.Toolbar.backup",
            "Stacio.Editor.Toolbar.askAI",
            "Stacio.Editor.Toolbar.restore",
            "Stacio.Editor.Toolbar.close"
        ] {
            let button = try XCTUnwrap(
                editor.view.firstSubview(withIdentifier: identifier) as? NSButton
            )
            button.performClick(nil as Any?)
        }

        XCTAssertEqual(collapseCount, 1)
        XCTAssertEqual(backupCount, 1)
        XCTAssertEqual(aiCount, 1)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(closeCount, 1)
    }

    func testToolbarCloseUsesStandaloneWindowLifecycleWhenCoordinatorIsAbsent() throws {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        let windowController = RemoteTextEditorWindowController(editorViewController: editor)
        var closeCount = 0
        windowController.onClose = { _ in closeCount += 1 }
        windowController.showWindow(nil)
        defer { windowController.close() }
        let closeButton = try XCTUnwrap(
            editor.view.firstSubview(withIdentifier: "Stacio.Editor.Toolbar.close") as? NSButton
        )

        closeButton.performClick(nil as Any?)

        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(windowController.window?.isVisible ?? true)
    }

    func testToolbarDragRequiresPrimaryButtonMovementBeyondEightPoints() {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        var requests = 0
        editor.onDragDetachRequested = { _ in requests += 1 }

        editor.simulateToolbarDragForTesting(buttonNumber: 0, points: [.zero, NSPoint(x: 8, y: 0)])
        editor.simulateToolbarDragForTesting(buttonNumber: 1, points: [.zero, NSPoint(x: 20, y: 0)])
        XCTAssertEqual(requests, 0)

        editor.simulateToolbarDragForTesting(buttonNumber: 0, points: [.zero, NSPoint(x: 9, y: 0)])
        XCTAssertEqual(requests, 1)
    }

    func testMonacoDisablesDraggingSelectedTextToPreventAccidentalBlockMoves() {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))

        XCTAssertTrue(editor.editorHTMLForTesting.contains("dragAndDrop: false"))
    }

    func testMonacoTabDragBridgeExcludesCloseScrollAndNormalClicks() {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        let html = editor.editorHTMLForTesting

        XCTAssertTrue(html.contains("tabDragCandidate"))
        XCTAssertTrue(html.contains("event.target.closest('.tab-close, .tab-scroll')"))
        XCTAssertTrue(html.contains("event.button !== 0"))
        XCTAssertTrue(html.contains("(event.buttons & 1) === 0"))
        XCTAssertTrue(html.contains("tabDragCancelled"))
        XCTAssertTrue(html.contains("addEventListener('pointerup', cancelTabDragCandidate, { capture: true })"))
        XCTAssertTrue(html.contains("addEventListener('pointercancel', cancelTabDragCandidate, { capture: true })"))
        XCTAssertTrue(html.contains("addEventListener('blur', cancelTabDragCandidate)"))
        XCTAssertTrue(html.contains("pageLoadGeneration"))
    }

    func testTabDragCandidateArrivingAfterPrimaryButtonReleaseIsRejected() {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        editor.loadView()
        var requests = 0
        editor.onDragDetachRequested = { _ in requests += 1 }

        editor.receiveTabDragCandidateForTesting(
            pageLoadGeneration: editor.pageLoadGenerationForTesting,
            pointInWindow: .zero,
            pointerID: 7,
            eventButtons: 1,
            pressedMouseButtons: 0
        )
        editor.simulateTrackedTabDragForTesting(
            to: NSPoint(x: 20, y: 0),
            eventType: .leftMouseDragged,
            buttonNumber: 0,
            pressedMouseButtons: 1
        )

        XCTAssertFalse(editor.isTabDragTrackingForTesting)
        XCTAssertEqual(requests, 0)
    }

    func testTabDragTrackingCancelsWhenPrimaryButtonIsNoLongerPressed() {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        editor.loadView()
        var requests = 0
        editor.onDragDetachRequested = { _ in requests += 1 }

        editor.receiveTabDragCandidateForTesting(
            pageLoadGeneration: editor.pageLoadGenerationForTesting,
            pointInWindow: .zero,
            pointerID: 8,
            eventButtons: 1,
            pressedMouseButtons: 1
        )
        XCTAssertTrue(editor.isTabDragTrackingForTesting)

        editor.simulateTrackedTabDragForTesting(
            to: NSPoint(x: 20, y: 0),
            eventType: .leftMouseDragged,
            buttonNumber: 0,
            pressedMouseButtons: 0
        )
        editor.simulateTrackedTabDragForTesting(
            to: NSPoint(x: 30, y: 0),
            eventType: .leftMouseDragged,
            buttonNumber: 0,
            pressedMouseButtons: 1
        )

        XCTAssertFalse(editor.isTabDragTrackingForTesting)
        XCTAssertEqual(requests, 0)
    }

    func testTabDragTrackingStillDetachesForHeldPrimaryButtonPastThreshold() {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        editor.loadView()
        var requests = 0
        editor.onDragDetachRequested = { _ in requests += 1 }

        editor.receiveTabDragCandidateForTesting(
            pageLoadGeneration: editor.pageLoadGenerationForTesting,
            pointInWindow: .zero,
            pointerID: 9,
            eventButtons: 1,
            pressedMouseButtons: 1
        )
        editor.simulateTrackedTabDragForTesting(
            to: NSPoint(x: 9, y: 0),
            eventType: .leftMouseDragged,
            buttonNumber: 0,
            pressedMouseButtons: 1
        )

        XCTAssertFalse(editor.isTabDragTrackingForTesting)
        XCTAssertEqual(requests, 1)
    }

    func testStalePageGenerationCannotStartTabDrag() {
        let editor = RemoteTextEditorViewController(document: RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.conf",
            fileName: "app.conf",
            content: "enabled=true\n"
        ))
        editor.loadView()
        var requests = 0
        editor.onDragDetachRequested = { _ in requests += 1 }

        editor.receiveTabDragCandidateForTesting(
            pageLoadGeneration: editor.pageLoadGenerationForTesting,
            pointInWindow: .zero
        )
        editor.receiveTabDragCandidateForTesting(pageLoadGeneration: -1, pointInWindow: .zero)
        editor.simulateTrackedTabDragForTesting(to: NSPoint(x: 20, y: 0))

        XCTAssertEqual(requests, 0)
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
        waitForLocalDocumentLoads(controller)

        XCTAssertEqual(controller.activeSaveStateForTesting, .saved)
        XCTAssertEqual(controller.activeSaveStateTextForTesting, "已保存")

        controller.replaceTextForTesting("enabled=true\n")

        XCTAssertEqual(controller.activeSaveStateForTesting, .dirty)
        XCTAssertEqual(controller.activeSaveStateTextForTesting, "未保存改动")

        shouldFail = true
        try controller.performSaveForTesting()
        waitForSaveState(.failed, in: controller)

        XCTAssertEqual(controller.activeSaveStateForTesting, .failed)
        XCTAssertEqual(controller.activeSaveStateTextForTesting, "保存失败：无法打开“app.conf”：upload failed")
        XCTAssertTrue(controller.activeSaveStatusIsErrorForTesting)

        shouldFail = false
        try controller.performSaveForTesting()
        waitForSaveState(.saved, in: controller)

        XCTAssertEqual(controller.activeSaveStateForTesting, .saved)
        XCTAssertEqual(controller.activeSaveStateTextForTesting, "已保存")
        XCTAssertTrue(observedSavingState)
        XCTAssertTrue(controller.editorHTMLForTesting.contains("saveStateText"))
        XCTAssertTrue(controller.editorHTMLForTesting.contains("window.setTimeout(() => {"))
        XCTAssertTrue(controller.editorHTMLForTesting.contains(
            "updateStatus();\n    }\n\n    function renderTabState"
        ))
    }

    func testWindowTitleUsesEditedDotAndClearsAfterSave() throws {
        let fileURL = try makeTemporaryEditorFile(name: "app.toml", contents: "debug = false\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        let windowController = RemoteTextEditorWindowController(editorViewController: controller)
        defer { windowController.close() }
        controller.loadView()
        waitForLocalDocumentLoads(controller)

        XCTAssertEqual(windowController.window?.title, "app.toml")
        XCTAssertEqual(windowController.window?.isDocumentEdited, false)

        controller.replaceTextForTesting("debug = true\n")

        XCTAssertEqual(windowController.window?.title, "● app.toml")
        XCTAssertEqual(windowController.window?.isDocumentEdited, true)

        try controller.performSaveForTesting()
        waitForSaveState(.saved, in: controller)

        XCTAssertEqual(windowController.window?.title, "app.toml")
        XCTAssertEqual(windowController.window?.isDocumentEdited, false)
    }

    func testEditorWindowOpensWithUsableDocumentWorkspaceSize() throws {
        let fileURL = try makeTemporaryEditorFile(name: "large-editor.conf", contents: "enabled=true\n")
        let editor = RemoteTextEditorViewController(localURL: fileURL)
        let windowController = RemoteTextEditorWindowController(editorViewController: editor)
        defer { windowController.close() }

        windowController.showWindow(nil)
        let window = try XCTUnwrap(windowController.window)
        window.layoutIfNeeded()

        XCTAssertEqual(window.contentLayoutRect.size, RemoteTextEditorWindowController.initialContentSize)
        XCTAssertEqual(window.frame.size, RemoteTextEditorWindowController.initialFrameSize)
        XCTAssertEqual(window.contentMinSize, RemoteTextEditorWindowController.minimumContentSize)
    }

    func testEmptyWindowShellInstallsAndRemovesEditorWithoutChangingWebViewIdentity() throws {
        let fileURL = try makeTemporaryEditorFile(name: "migration.conf", contents: "enabled=true\n")
        let editor = RemoteTextEditorViewController(localURL: fileURL)
        editor.loadView()
        let webView = try XCTUnwrap(editor.editorWebViewForTesting)
        let windowController = RemoteTextEditorWindowController()
        defer { windowController.closeShellForRedock() }

        try windowController.installEditor(editor)

        XCTAssertTrue(windowController.editorViewController === editor)
        XCTAssertTrue(windowController.window?.contentViewController === editor)
        XCTAssertTrue(editor.editorWebViewForTesting === webView)

        try windowController.removeEditorForMigration(editor)

        XCTAssertNil(windowController.installedEditorViewController)
        XCTAssertNil(windowController.window?.contentViewController)
        XCTAssertTrue(editor.editorWebViewForTesting === webView)
    }

    func testStandaloneWindowAdapterPreservesExistingPresentationCallback() throws {
        let fileURL = try makeTemporaryEditorFile(name: "callbacks.conf", contents: "enabled=true\n")
        let editor = RemoteTextEditorViewController(localURL: fileURL)
        var existingPresentationEvents: [(String, Bool)] = []
        editor.onWindowPresentationChanged = {
            existingPresentationEvents.append(($0, $1))
        }
        let windowController = RemoteTextEditorWindowController(editorViewController: editor)
        defer { windowController.close() }
        editor.loadView()
        waitForLocalDocumentLoads(editor)

        editor.replaceTextForTesting("enabled=false\n")

        XCTAssertEqual(existingPresentationEvents.last?.0, "callbacks.conf")
        XCTAssertEqual(existingPresentationEvents.last?.1, true)
        XCTAssertEqual(windowController.window?.title, "● callbacks.conf")
        XCTAssertEqual(windowController.window?.isDocumentEdited, true)
    }

    func testRedockShellCloseDoesNotAskEditorToCloseAndClearsDelegates() throws {
        let descriptor = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/redock.conf",
            fileName: "redock.conf",
            content: "enabled=true\n"
        )
        let editor = RemoteTextEditorViewController(document: descriptor)
        editor.replaceTextForTesting("enabled=false\n")
        let confirmer = RecordingRemoteTextEditorCloseConfirmer(decision: .cancel)
        let windowController = RemoteTextEditorWindowController(
            editorViewController: editor,
            closeConfirmer: confirmer
        )
        let delegate = RecordingRemoteTextEditorWindowDelegate()
        windowController.presentationDelegate = delegate
        windowController.showWindow(nil)

        windowController.closeShellForRedock()

        XCTAssertEqual(confirmer.promptedFileNames, [])
        XCTAssertFalse(windowController.window?.isVisible ?? true)
        XCTAssertNil(windowController.installedEditorViewController)
        XCTAssertNil(windowController.window?.contentViewController)
        XCTAssertNil(windowController.window?.delegate)
        XCTAssertNil(windowController.presentationDelegate)
        XCTAssertEqual(delegate.closeReasons, [true])
    }

    func testEditorBuildsAIAttachmentForActiveRemoteTextDocument() throws {
        let descriptor = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/nginx/nginx.conf",
            fileName: "nginx.conf",
            content: "server {\n  listen 80;\n  proxy_pass http://127.0.0.1:3000;\n}\n",
            byteCount: 64
        )
        let controller = RemoteTextEditorViewController(document: descriptor)
        var requests: [RemoteTextEditorAIRequest] = []
        controller.onAIQuestionRequested = { requests.append($0) }

        controller.loadView()
        controller.requestAIForActiveDocumentForTesting()

        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.question.contains("请阅读附件"))
        XCTAssertTrue(request.question.contains("nginx.conf"))
        XCTAssertFalse(request.question.contains("/etc/nginx/nginx.conf"))
        XCTAssertFalse(request.question.contains("proxy_pass"))
        XCTAssertEqual(request.attachment.filename, "nginx.conf")
        XCTAssertEqual(request.attachment.mimeType, "text/plain")
        XCTAssertEqual(request.attachment.byteCount, descriptor.content.lengthOfBytes(using: .utf8))
        XCTAssertTrue(request.attachment.textPreview?.contains("proxy_pass") == true)
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
        XCTAssertTrue(html.contains("target.closest('[data-close], .close, .tab-scroll')"))
        XCTAssertTrue(html.contains(".close {"))
        XCTAssertFalse(html.contains("target.closest('.tab-close')"))
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
        XCTAssertTrue(html.contains(
            "const excludedControl = target.closest('[data-close], .close, .tab-scroll')"
        ))
    }

    func testWebSwitchTabMessageDoesNotPushStaleActiveTabBeforeActivatingTarget() throws {
        let firstURL = try makeTemporaryEditorFile(name: "first.conf", contents: "enabled=false\n")
        let secondURL = try makeTemporaryEditorFile(name: "second.yaml", contents: "enabled: true\n")
        let controller = RemoteTextEditorViewController(localURL: firstURL)

        controller.loadView()
        controller.markEditorReadyForTesting()
        controller.openDocumentForTesting(localURL: secondURL)
        waitForLocalDocumentLoads(controller)
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

    func testReadyEditorCoalescesLayoutRequestsAndSkipsUnchangedSize() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        controller.view.layoutSubtreeIfNeeded()
        controller.markEditorReadyForTesting()
        controller.resetEditorFunctionCallsForTesting()

        for _ in 0..<100 {
            controller.viewDidLayout()
        }

        XCTAssertTrue(waitUntil {
            controller.editorFunctionCallsForTesting.filter { $0 == "layout" }.count == 1
        })

        for _ in 0..<100 {
            controller.viewDidLayout()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(
            controller.editorFunctionCallsForTesting.filter { $0 == "layout" }.count,
            1
        )

        controller.view.frame.size.width = 1_080
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(waitUntil {
            controller.editorFunctionCallsForTesting.filter { $0 == "layout" }.count == 2
        })
    }

    func testForcedLayoutSurvivesTemporaryZeroSizedContainer() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        controller.view.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        controller.markEditorReadyForTesting()
        controller.viewDidLayout()
        XCTAssertTrue(waitUntil {
            controller.editorFunctionCallsForTesting.filter { $0 == "layout" }.count == 1
        })
        controller.resetEditorFunctionCallsForTesting()

        controller.view.frame.size = .zero
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()

        controller.view.frame.size = NSSize(width: 980, height: 640)
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()

        XCTAssertTrue(waitUntil {
            controller.editorFunctionCallsForTesting.filter { $0 == "layout" }.count == 1
        })
    }

    func testMonacoLayoutUsesMeasuredSizeAndOneAnimationFramePerRenderCycle() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()

        let html = controller.editorHTMLForTesting
        XCTAssertTrue(html.contains("let pendingEditorLayoutFrame = null;"))
        XCTAssertTrue(html.contains("let pendingEditorLayoutFallbackTimer = null;"))
        XCTAssertTrue(html.contains("function performMeasuredEditorLayout()"))
        XCTAssertTrue(html.contains("function scheduleEditorLayout()"))
        XCTAssertTrue(html.contains("if (pendingEditorLayoutFrame !== null) { return; }"))
        XCTAssertTrue(html.contains("pendingEditorLayoutFrame = requestAnimationFrame(() =>"))
        XCTAssertTrue(html.contains("pendingEditorLayoutFallbackTimer = window.setTimeout(() =>"))
        XCTAssertTrue(html.contains("cancelAnimationFrame(pendingEditorLayoutFrame);"))
        XCTAssertTrue(html.contains("const width = editorElement.clientWidth;"))
        XCTAssertTrue(html.contains("const height = editorElement.clientHeight;"))
        XCTAssertTrue(html.contains("editor.layout({ width, height });"))
        XCTAssertTrue(html.contains("layout: scheduleEditorLayout"))
        XCTAssertTrue(html.contains("window.addEventListener('resize', scheduleEditorLayout)"))
        XCTAssertFalse(html.contains("automaticLayout: true"))
    }

    func testRepeatedWorkspaceLoadReusesExistingMonacoModelURI() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()

        let html = controller.editorHTMLForTesting
        XCTAssertTrue(html.contains("let model = monaco.editor.getModel(uri);"))
        XCTAssertTrue(html.contains("model = monaco.editor.createModel(nextContent, language, uri);"))
        XCTAssertTrue(html.contains("if (model.getValue() !== nextContent)"))
        XCTAssertTrue(html.contains("if (oldModel !== model)"))
        XCTAssertFalse(html.contains("const model = monaco.editor.createModel(document.content || '', language, uri);"))
    }

    func testEditorBridgeIgnoresReadyFromPreviousPageGeneration() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        controller.resetEditorFunctionCallsForTesting()

        webView.loadHTMLString(
            """
            <!doctype html>
            <html><body><script>
              const bridge = window.webkit.messageHandlers.stacioEditor;
              bridge.postMessage({ pageLoadGeneration: 0, name: 'ready', payload: {} });
              bridge.postMessage({ pageLoadGeneration: 1, name: 'ready', payload: {} });
            </script></body></html>
            """,
            baseURL: nil
        )

        XCTAssertTrue(waitUntil {
            controller.editorFunctionCallsForTesting.filter { $0 == "loadWorkspace" }.count >= 1
        })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(
            controller.editorFunctionCallsForTesting.filter { $0 == "loadWorkspace" }.count,
            1
        )
    }

    func testEditorRemainsLoadingUntilCurrentWorkspaceAcknowledges() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        controller.view.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        controller.resetEditorFunctionCallsForTesting()
        XCTAssertTrue(controller.editorHTMLForTesting.contains("post('workspaceReady'"))

        webView.loadHTMLString(
            """
            <!doctype html>
            <html><body><script>
              const bridge = window.webkit.messageHandlers.stacioEditor;
              window.StacioEditor = {
                loadWorkspace(payload) {
                  window.setTimeout(() => {
                    bridge.postMessage({
                      pageLoadGeneration: 1,
                      name: 'workspaceReady',
                      payload: {
                        activeDocumentID: payload.activeDocumentID,
                        documentCount: payload.documents.length
                      }
                    });
                  }, 400);
                }
              };
              bridge.postMessage({ pageLoadGeneration: 1, name: 'ready', payload: {} });
            </script></body></html>
            """,
            baseURL: nil
        )

        XCTAssertTrue(waitUntil {
            controller.editorFunctionCallsForTesting.contains("loadWorkspace")
        })
        XCTAssertNotNil(webView.layer?.backgroundColor)
        XCTAssertFalse(controller.editorFunctionCallsForTesting.contains("layout"))

        XCTAssertTrue(waitUntil(timeout: 1) {
            webView.layer?.backgroundColor == nil
        })
        XCTAssertTrue(waitUntil {
            controller.editorFunctionCallsForTesting.contains("layout")
        })
    }

    func testActualMonacoRuntimeCompletesWorkspaceHandshakeBeforeBecomingVisible() throws {
        let descriptor = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/remote.js",
            fileName: "remote.js",
            content: "const value = 1\n"
        )
        let controller = RemoteTextEditorViewController(document: descriptor)
        let windowController = RemoteTextEditorWindowController(editorViewController: controller)
        windowController.showWindow(nil)
        defer { windowController.close() }
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()

        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let monacoBaseURL = repositoryURL
            .appendingPathComponent("node_modules/monaco-editor/min", isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: monacoBaseURL.appendingPathComponent("vs/loader.js").path
        ) else {
            throw XCTSkip("Monaco runtime is not installed in this source checkout")
        }
        let testPageDirectory = repositoryURL
            .appendingPathComponent(".build/stacio-monaco-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: testPageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: testPageDirectory) }
        let html = controller.editorHTMLForTesting.replacingOccurrences(
            of: "<head>",
            with: "<head><base href=\"\(monacoBaseURL.absoluteString)\">"
        )
        let htmlURL = testPageDirectory.appendingPathComponent("editor.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        webView.loadFileURL(htmlURL, allowingReadAccessTo: repositoryURL)

        XCTAssertTrue(
            waitUntil(timeout: 5) {
                webView.layer?.backgroundColor == nil
            },
            "The real Monaco runtime never completed its workspace handshake"
        )
        XCTAssertTrue(controller.editorFunctionCallsForTesting.contains("loadWorkspace"))
        XCTAssertTrue(waitUntil {
            controller.editorFunctionCallsForTesting.contains("layout")
        })
        let retryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.retryLoading") as? NSButton
        )
        XCTAssertTrue(retryButton.isHidden)
    }

    func testWorkspaceJavaScriptFailureImmediatelyTriggersBoundedRecovery() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()

        webView.loadHTMLString(
            """
            <!doctype html>
            <html><body><script>
              window.StacioEditor = {
                loadWorkspace() { throw new Error('workspace sync failed'); }
              };
              window.webkit.messageHandlers.stacioEditor.postMessage({
                pageLoadGeneration: 1,
                name: 'ready',
                payload: {}
              });
            </script></body></html>
            """,
            baseURL: nil
        )

        XCTAssertTrue(waitUntil(timeout: 0.5) {
            controller.monacoPageLoadCountForTesting == 2
        })
    }

    func testLayoutChangesNeverReloadMonacoAndProcessTerminationReloadsExactlyOnce() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        controller.markEditorReadyForTesting()

        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 1)

        for index in 0..<100 {
            controller.view.frame.size = NSSize(width: 900 + index, height: 600 + (index % 7))
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()
        }

        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 1)

        controller.webViewWebContentProcessDidTerminate(webView)

        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 2)
    }

    func testRepeatedWebContentProcessTerminationUsesBoundedAutomaticRecovery() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        controller.markEditorReadyForTesting()

        controller.webViewWebContentProcessDidTerminate(webView)
        XCTAssertTrue(waitUntil(timeout: 0.5) {
            controller.monacoPageLoadCountForTesting == 2
        })

        controller.webViewWebContentProcessDidTerminate(webView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 2)
        let retryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.retryLoading") as? NSButton
        )
        XCTAssertFalse(retryButton.isHidden)
    }

    func testSuccessfulWorkspaceAfterRecoveryRestoresProcessTerminationBudget() throws {
        let descriptor = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/remote.js",
            fileName: "remote.js",
            content: "const value = 1\n"
        )
        let controller = RemoteTextEditorViewController(document: descriptor)
        controller.loadView()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        controller.markEditorReadyForTesting()

        controller.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 2)
        webView.stopLoading()
        webView.loadHTMLString(
            """
            <!doctype html>
            <html><body><script>
              const bridge = window.webkit.messageHandlers.stacioEditor;
              window.StacioEditor = {
                loadWorkspace(payload) {
                  bridge.postMessage({
                    pageLoadGeneration: 2,
                    name: 'workspaceReady',
                    payload: {
                      activeDocumentID: payload.activeDocumentID,
                      documentCount: payload.documents.length
                    }
                  });
                }
              };
              bridge.postMessage({ pageLoadGeneration: 2, name: 'ready', payload: {} });
            </script></body></html>
            """,
            baseURL: nil
        )
        XCTAssertTrue(waitUntil(timeout: 1) {
            webView.layer?.backgroundColor == nil
        })

        controller.webViewWebContentProcessDidTerminate(webView)

        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 3)
    }

    func testUnreadyEditorReloadsOnceWhenLiveResizeEnds() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()

        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 1)

        controller.view.viewWillStartLiveResize()
        controller.view.viewDidEndLiveResize()

        XCTAssertTrue(waitUntil {
            controller.monacoPageLoadCountForTesting == 2
        })

        controller.view.viewDidEndLiveResize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 2)
    }

    func testReadyEditorEndingLiveResizeRequestsLayoutWithoutReloading() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        controller.view.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        controller.markEditorReadyForTesting()
        controller.resetEditorFunctionCallsForTesting()

        controller.view.viewWillStartLiveResize()
        controller.view.viewDidEndLiveResize()

        XCTAssertTrue(waitUntil {
            controller.editorFunctionCallsForTesting.filter { $0 == "layout" }.count == 1
        })
        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 1)
    }

    func testEditorBecomingReadyDuringLiveResizeAvoidsRecoveryReload() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        controller.view.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()

        controller.view.viewWillStartLiveResize()
        controller.markEditorReadyForTesting()
        controller.resetEditorFunctionCallsForTesting()
        controller.view.viewDidEndLiveResize()

        XCTAssertTrue(waitUntil {
            controller.editorFunctionCallsForTesting.filter { $0 == "layout" }.count == 1
        })
        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 1)
    }

    func testFinishedNavigationWithoutReadyTriggersOneBoundedRecoveryReload() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)

        (controller as WKNavigationDelegate).webView?(webView, didFinish: nil)

        XCTAssertTrue(waitUntil(timeout: 4) {
            controller.monacoPageLoadCountForTesting == 2
        })

        (controller as WKNavigationDelegate).webView?(webView, didFinish: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))

        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 2)
    }

    func testNavigationWithoutAnyDelegateCallbackStillTriggersBoundedRecovery() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.navigationDelegate = nil
        webView.stopLoading()

        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 1)
        XCTAssertTrue(waitUntil(timeout: 4) {
            controller.monacoPageLoadCountForTesting == 2
        })
    }

    func testCurrentNavigationFailureImmediatelyTriggersBoundedRecovery() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()

        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotOpenFile,
            userInfo: nil
        )
        (controller as WKNavigationDelegate).webView?(
            webView,
            didFailProvisionalNavigation: nil,
            withError: error
        )

        XCTAssertTrue(waitUntil(timeout: 0.5) {
            controller.monacoPageLoadCountForTesting == 2
        })
    }

    func testExhaustedAutomaticRecoveryShowsManualRetryWithoutReloadLoop() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        controller.view.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.navigationDelegate = nil
        webView.stopLoading()

        XCTAssertTrue(waitUntil(timeout: 4) {
            controller.monacoPageLoadCountForTesting == 2
        })
        RunLoop.main.run(until: Date().addingTimeInterval(3.4))
        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 2)

        let retryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.retryLoading") as? NSButton
        )
        XCTAssertFalse(retryButton.isHidden)

        retryButton.performClick(nil as Any?)

        XCTAssertTrue(waitUntil(timeout: 0.5) {
            controller.monacoPageLoadCountForTesting == 3
        })
        XCTAssertTrue(retryButton.isHidden)
    }

    func testReadinessWatchdogDefersRecoveryUntilLiveResizeEnds() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        controller.loadView()
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)

        controller.view.viewWillStartLiveResize()
        (controller as WKNavigationDelegate).webView?(webView, didFinish: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(3.2))

        XCTAssertEqual(controller.monacoPageLoadCountForTesting, 1)

        controller.view.viewDidEndLiveResize()
        XCTAssertTrue(waitUntil {
            controller.monacoPageLoadCountForTesting == 2
        })
    }

    func testWindowLiveResizeEndNotificationRecoversWhenViewCallbackIsMissed() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        let windowController = RemoteTextEditorWindowController(editorViewController: controller)
        defer { windowController.close() }
        let window = try XCTUnwrap(windowController.window)
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()

        controller.view.viewWillStartLiveResize()
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)

        XCTAssertTrue(waitUntil {
            controller.monacoPageLoadCountForTesting == 2
        })
    }

    func testEditorAttachedWhileWindowIsLiveResizingRecoversAtResizeEnd() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        let window = SimulatedLiveResizeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.simulatesLiveResize = true
        let windowController = NSWindowController(window: window)
        defer {
            window.contentViewController = nil
            windowController.close()
        }
        window.contentViewController = controller
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)

        window.simulatesLiveResize = false
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)

        XCTAssertTrue(waitUntil(timeout: 0.5) {
            controller.monacoPageLoadCountForTesting == 2
        })
    }

    func testEditorDetachedDuringLiveResizeRecoversWhenReattachedAfterResize() throws {
        let fileURL = try makeTemporaryEditorFile(name: "remote.js", contents: "const value = 1\n")
        let controller = RemoteTextEditorViewController(localURL: fileURL)
        let window = SimulatedLiveResizeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.simulatesLiveResize = true
        let windowController = NSWindowController(window: window)
        defer {
            window.contentViewController = nil
            windowController.close()
        }
        window.contentViewController = controller
        let webView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.navigationDelegate = nil
        webView.stopLoading()

        window.contentViewController = nil
        window.simulatesLiveResize = false
        window.contentViewController = controller

        XCTAssertTrue(waitUntil(timeout: 2.5) {
            controller.monacoPageLoadCountForTesting == 2
        })
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
        waitForLocalDocumentLoads(controller)
        controller.replaceTextForTesting("debug = true\n")

        XCTAssertFalse(windowController.windowShouldClose(try XCTUnwrap(windowController.window)))
        waitForSaveState(.saved, in: controller)

        XCTAssertEqual(confirmer.promptedFileNames, ["app.toml"])
        XCTAssertEqual(savedURLs, [fileURL])
        XCTAssertEqual(try String(contentsOf: fileURL), "debug = true\n")
        XCTAssertFalse(controller.hasUnsavedChangesForTesting)
    }

    func testCloseRequestDistinguishesReadyPendingAndCancelled() {
        let clean = RemoteTextEditorViewController(
            document: RemoteTextEditorDocumentDescriptor(
                remotePath: "/etc/clean.conf",
                fileName: "clean.conf",
                content: "enabled=true\n"
            )
        )
        XCTAssertEqual(
            clean.requestClose(
                parentWindow: nil,
                closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .discard)
            ),
            .ready
        )

        let cancelled = RemoteTextEditorViewController(
            document: RemoteTextEditorDocumentDescriptor(
                remotePath: "/etc/cancel.conf",
                fileName: "cancel.conf",
                content: "enabled=true\n"
            )
        )
        cancelled.replaceTextForTesting("enabled=false\n")
        XCTAssertEqual(
            cancelled.requestClose(
                parentWindow: nil,
                closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .cancel)
            ),
            .cancelled
        )

        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let pending = RemoteTextEditorViewController(
            document: RemoteTextEditorDocumentDescriptor(
                remotePath: "/etc/pending.conf",
                fileName: "pending.conf",
                content: "enabled=true\n"
            ),
            onSaveTextAsync: { _, completion in saveCompletion = completion }
        )
        pending.replaceTextForTesting("enabled=false\n")
        XCTAssertEqual(
            pending.requestClose(
                parentWindow: nil,
                closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .save)
            ),
            .pending
        )
        saveCompletion?(.failure(CocoaError(.fileWriteUnknown)))
    }

    func testPendingClosePublishesExactlyOneFinalResolution() {
        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let editor = RemoteTextEditorViewController(
            document: RemoteTextEditorDocumentDescriptor(
                remotePath: "/etc/remote.conf",
                fileName: "remote.conf",
                content: "enabled=true\n"
            ),
            onSaveTextAsync: { _, completion in saveCompletion = completion }
        )
        var resolutions: [RemoteTextEditorCloseResolution] = []
        editor.onPendingCloseResolved = { resolutions.append($0) }
        editor.replaceTextForTesting("enabled=false\n")

        XCTAssertEqual(
            editor.requestClose(
                parentWindow: nil,
                closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .save)
            ),
            .pending
        )
        saveCompletion?(.success(()))
        saveCompletion?(.success(()))

        XCTAssertEqual(resolutions, [.ready])
    }

    func testMissingMonacoCloseHandshakeCancelsPendingCloseExactlyOnce() throws {
        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let editor = RemoteTextEditorViewController(
            document: RemoteTextEditorDocumentDescriptor(
                remotePath: "/etc/missing-handshake.conf",
                fileName: "missing-handshake.conf",
                content: "enabled=true\n"
            ),
            onSaveTextAsync: { _, completion in saveCompletion = completion }
        )
        editor.loadView()
        let webView = try XCTUnwrap(
            editor.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        webView.loadHTMLString(
            "<script>window.StacioEditor = {}; window.handshakePageReady = true;</script>",
            baseURL: nil
        )
        XCTAssertTrue(waitUntil {
            var ready = false
            webView.evaluateJavaScript("window.handshakePageReady === true") { value, _ in
                ready = value as? Bool == true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            return ready
        })
        editor.markEditorReadyForTesting()
        editor.replaceTextForTesting("enabled=false\n")
        var resolutions: [RemoteTextEditorCloseResolution] = []
        editor.onPendingCloseResolved = { resolutions.append($0) }

        XCTAssertEqual(
            editor.requestClose(
                parentWindow: nil,
                closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .save)
            ),
            .pending
        )
        saveCompletion?(.success(()))

        XCTAssertTrue(waitUntil { resolutions == [.cancelled] })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(resolutions, [.cancelled])
    }

    func testWebContentTerminationCancelsUnansweredMonacoCloseHandshakeExactlyOnce() throws {
        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let editor = RemoteTextEditorViewController(
            document: RemoteTextEditorDocumentDescriptor(
                remotePath: "/etc/unanswered-handshake.conf",
                fileName: "unanswered-handshake.conf",
                content: "enabled=true\n"
            ),
            onSaveTextAsync: { _, completion in saveCompletion = completion }
        )
        editor.loadView()
        let webView = try XCTUnwrap(
            editor.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        defer { webView.stopLoading() }
        webView.stopLoading()
        webView.loadHTMLString(
            """
            <script>
              window.StacioEditor = { confirmSavedContentBeforeClose() {} };
              window.handshakePageReady = true;
            </script>
            """,
            baseURL: nil
        )
        XCTAssertTrue(waitUntil {
            var ready = false
            webView.evaluateJavaScript("window.handshakePageReady === true") { value, _ in
                ready = value as? Bool == true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            return ready
        })
        editor.markEditorReadyForTesting()
        editor.replaceTextForTesting("enabled=false\n")
        var resolutions: [RemoteTextEditorCloseResolution] = []
        editor.onPendingCloseResolved = { resolutions.append($0) }

        XCTAssertEqual(
            editor.requestClose(
                parentWindow: nil,
                closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .save)
            ),
            .pending
        )
        saveCompletion?(.success(()))
        XCTAssertTrue(waitUntil {
            editor.editorFunctionCallsForTesting.contains("confirmSavedContentBeforeClose")
        })

        editor.webViewWebContentProcessDidTerminate(webView)

        XCTAssertEqual(resolutions, [.cancelled])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(resolutions, [.cancelled])
    }

    func testWindowCloseWaitsForAsyncSaveSuccessBeforeClosing() throws {
        let descriptor = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.toml",
            fileName: "app.toml",
            content: "debug = false\n"
        )
        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let editor = RemoteTextEditorViewController(
            document: descriptor,
            onSaveTextAsync: { _, completion in saveCompletion = completion }
        )
        let windowController = RemoteTextEditorWindowController(
            editorViewController: editor,
            closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .save)
        )
        var closeCount = 0
        windowController.onClose = { _ in closeCount += 1 }
        windowController.showWindow(nil)
        defer { windowController.close() }
        editor.replaceTextForTesting("debug = true\n")

        XCTAssertFalse(windowController.windowShouldClose(try XCTUnwrap(windowController.window)))
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(editor.activeSaveStateForTesting, .saving)

        saveCompletion?(.success(()))

        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(editor.hasUnsavedChangesForTesting)
    }

    func testWindowCloseRechecksMonacoRevisionBeforeDelayedChangedMessageArrives() throws {
        let descriptor = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.toml",
            fileName: "app.toml",
            content: "debug = false\n"
        )
        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let editor = RemoteTextEditorViewController(
            document: descriptor,
            onSaveTextAsync: { _, completion in saveCompletion = completion }
        )
        let windowController = RemoteTextEditorWindowController(
            editorViewController: editor,
            closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .save)
        )
        var closeCount = 0
        windowController.onClose = { _ in closeCount += 1 }
        windowController.showWindow(nil)
        defer { windowController.close() }
        editor.replaceTextForTesting("debug = true\n")

        let webView = try XCTUnwrap(
            editor.view.firstSubview(withIdentifier: "Stacio.Editor.webView") as? WKWebView
        )
        let documentIDJSON = try XCTUnwrap(
            String(data: JSONEncoder().encode(editor.documentIDsForTesting[0]), encoding: .utf8)
        )
        let pageLoaded = expectation(description: "handshake test page loaded")
        editor.markEditorReadyForTesting()
        webView.loadHTMLString(
            """
            <script>
              window.handshakeTestPageReady = true;
              window.monacoContent = 'debug = newest\\n';
              window.monacoRevision = 2;
              window.StacioEditor = {
                confirmSavedContentBeforeClose(payload) {
                  window.webkit.messageHandlers.stacioEditor.postMessage({
                    pageLoadGeneration: 1,
                    name: 'closeHandshake',
                    payload: {
                      id: payload.documentID,
                      requestID: payload.requestID,
                      content: window.monacoContent,
                      revision: window.monacoRevision
                    }
                  });
                }
              };
            </script>
            """,
            baseURL: nil
        )
        func waitForPage() {
            webView.evaluateJavaScript("window.handshakeTestPageReady === true") { value, _ in
                if value as? Bool == true {
                    pageLoaded.fulfill()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: waitForPage)
                }
            }
        }
        waitForPage()
        wait(for: [pageLoaded], timeout: 2)

        XCTAssertFalse(windowController.windowShouldClose(try XCTUnwrap(windowController.window)))
        XCTAssertEqual(editor.activeSaveStateForTesting, .saving)

        let delayedChangedScheduled = expectation(description: "delayed changed message scheduled")
        webView.evaluateJavaScript(
            """
            window.setTimeout(() => {
              window.webkit.messageHandlers.stacioEditor.postMessage({
                pageLoadGeneration: 1,
                name: 'changed',
                payload: {
                  id: \(documentIDJSON),
                  content: window.monacoContent,
                  revision: window.monacoRevision
                }
              });
            }, 100);
            """
        ) { _, error in
            XCTAssertNil(error)
            saveCompletion?(.success(()))
            delayedChangedScheduled.fulfill()
        }
        wait(for: [delayedChangedScheduled], timeout: 2)
        XCTAssertTrue(
            waitUntil {
                closeCount != 0
                    || (editor.currentTextForTesting == "debug = newest\n"
                        && editor.hasUnsavedChangesForTesting)
            },
            "Timed out waiting for Monaco's close handshake or delayed change message"
        )

        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(editor.currentTextForTesting, "debug = newest\n")
        XCTAssertTrue(editor.hasUnsavedChangesForTesting)
    }

    func testWindowCloseKeepsDirtyEditorOpenWhenAsyncSaveFails() throws {
        let descriptor = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/app.toml",
            fileName: "app.toml",
            content: "debug = false\n"
        )
        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let editor = RemoteTextEditorViewController(
            document: descriptor,
            onSaveTextAsync: { _, completion in saveCompletion = completion }
        )
        let windowController = RemoteTextEditorWindowController(
            editorViewController: editor,
            closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .save)
        )
        var closeCount = 0
        windowController.onClose = { _ in closeCount += 1 }
        windowController.showWindow(nil)
        defer { windowController.close() }
        editor.replaceTextForTesting("debug = true\n")

        XCTAssertFalse(windowController.windowShouldClose(try XCTUnwrap(windowController.window)))
        saveCompletion?(.failure(CocoaError(.fileWriteUnknown)))

        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(editor.activeSaveStateForTesting, .failed)
        XCTAssertTrue(editor.hasUnsavedChangesForTesting)
    }

    func testTabCloseWaitsForAsyncSaveSuccessBeforeRemovingDocument() {
        let first = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/first.conf",
            fileName: "first.conf",
            content: "enabled=false\n"
        )
        let second = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/second.conf",
            fileName: "second.conf",
            content: "port=22\n"
        )
        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let editor = RemoteTextEditorViewController(
            document: first,
            onSaveTextAsync: { _, completion in saveCompletion = completion }
        )
        editor.openDocument(second)
        editor.switchToDocumentForTesting(fileName: "first.conf")
        editor.replaceTextForTesting("enabled=true\n")

        editor.closeDocumentForTesting(
            fileName: "first.conf",
            closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .save)
        )

        XCTAssertEqual(editor.tabTitlesForTesting, ["first.conf", "second.conf"])
        XCTAssertEqual(editor.activeSaveStateForTesting, .saving)

        saveCompletion?(.success(()))

        XCTAssertEqual(editor.tabTitlesForTesting, ["second.conf"])
    }

    func testTabCloseKeepsDirtyDocumentWhenAsyncSaveFails() {
        let first = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/first.conf",
            fileName: "first.conf",
            content: "enabled=false\n"
        )
        let second = RemoteTextEditorDocumentDescriptor(
            remotePath: "/etc/second.conf",
            fileName: "second.conf",
            content: "port=22\n"
        )
        var saveCompletion: ((Result<Void, Error>) -> Void)?
        let editor = RemoteTextEditorViewController(
            document: first,
            onSaveTextAsync: { _, completion in saveCompletion = completion }
        )
        editor.openDocument(second)
        editor.switchToDocumentForTesting(fileName: "first.conf")
        editor.replaceTextForTesting("enabled=true\n")

        editor.closeDocumentForTesting(
            fileName: "first.conf",
            closeConfirmer: RecordingRemoteTextEditorCloseConfirmer(decision: .save)
        )
        saveCompletion?(.failure(CocoaError(.fileWriteUnknown)))

        XCTAssertEqual(editor.tabTitlesForTesting, ["first.conf", "second.conf"])
        XCTAssertEqual(editor.activeSaveStateForTesting, .failed)
        XCTAssertTrue(editor.hasUnsavedChangesForTesting)
    }
}

private final class SimulatedLiveResizeWindow: NSWindow {
    var simulatesLiveResize = false

    override var inLiveResize: Bool {
        simulatesLiveResize
    }
}

private final class EditorMediaInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
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

final class RecordingRemoteTextEditorCloseConfirmer: RemoteTextEditorCloseConfirming {
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

@MainActor
private final class RecordingRemoteTextEditorWindowDelegate:
    RemoteTextEditorWindowControllerDelegate
{
    private(set) var closeReasons: [Bool] = []

    func remoteTextEditorWindowShouldClose(
        _ controller: RemoteTextEditorWindowController
    ) -> Bool {
        true
    }

    func remoteTextEditorWindowDidClose(
        _ controller: RemoteTextEditorWindowController,
        forRedock: Bool
    ) {
        closeReasons.append(forRedock)
    }

    func remoteTextEditorWindowDidChangeFrame(
        _ controller: RemoteTextEditorWindowController,
        frame: NSRect,
        userInitiated: Bool
    ) {}

    func remoteTextEditorWindowWillEnterFullScreen(
        _ controller: RemoteTextEditorWindowController
    ) {}

    func remoteTextEditorWindowDidExitFullScreen(
        _ controller: RemoteTextEditorWindowController
    ) {}
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
