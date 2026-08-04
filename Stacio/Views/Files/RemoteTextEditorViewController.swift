import AppKit
import WebKit

public enum RemoteTextEditorTheme {
    public static func monacoIdentifier(settings: AppSettings, appearance: NSAppearance) -> String {
        switch settings.terminalTheme {
        case .light:
            return "vs"
        case .dark:
            let theme = TerminalColorTheme.resolvedBuiltInTheme(id: settings.terminalBuiltInThemeID)
            return monacoIdentifier(for: theme)
        case .custom:
            guard let theme = settings.customTerminalTheme,
                  let backgroundColor = TerminalThemeColor.nsColor(from: theme.backgroundHex)
            else {
                return "vs-dark"
            }
            return isDark(backgroundColor) ? monacoIdentifier(for: theme) : "vs"
        case .system:
            return isDark(appearance) ? "vs-dark" : "vs"
        }
    }

    public static func monacoFontFamily(settings: AppSettings) -> String {
        switch settings.terminalFontFamily {
        case .sfMono:
            return "SFMono-Regular, SF Mono, Menlo, Monaco, Consolas, monospace"
        case .menlo:
            return "Menlo, SFMono-Regular, Monaco, Consolas, monospace"
        case .monaco:
            return "Monaco, Menlo, SFMono-Regular, Consolas, monospace"
        case .jetBrainsMono:
            return "JetBrains Mono, JetBrainsMono-Regular, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
        case .firaCode:
            return "Fira Code, FiraCode-Regular, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
        case .hack:
            return "Hack, Hack-Regular, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
        case .sourceCodePro:
            return "Source Code Pro, SourceCodePro-Regular, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
        case .cascadiaCode:
            return "Cascadia Code, CascadiaCode-Regular, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
        case .consolas:
            return "Consolas, SFMono-Regular, Menlo, Monaco, monospace"
        }
    }

    public static func monacoThemePayload(settings: AppSettings, themeIdentifier: String) -> MonacoThemePayload? {
        let colorTheme: TerminalColorTheme?
        switch settings.terminalTheme {
        case .dark:
            colorTheme = TerminalColorTheme.resolvedBuiltInTheme(id: settings.terminalBuiltInThemeID)
        case .custom:
            colorTheme = settings.customTerminalTheme
        case .light, .system:
            colorTheme = nil
        }
        guard let colorTheme,
              themeIdentifier.hasPrefix("stacio-")
        else {
            return nil
        }
        return MonacoThemePayload(theme: colorTheme, identifier: themeIdentifier)
    }

    private static func monacoIdentifier(for theme: TerminalColorTheme) -> String {
        let source = theme.id ?? theme.name
        let slug = source
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let compacted = String(slug)
            .split(separator: "-")
            .joined(separator: "-")
        return "stacio-\(compacted.isEmpty ? "custom" : compacted)"
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    fileprivate static func isDark(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return true
        }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5
    }
}

public struct MonacoThemePayload: Encodable, Equatable {
    public let base: String
    public let inherit: Bool
    public let colors: [String: String]
    public let rules: [MonacoThemeRulePayload]

    public init(theme: TerminalColorTheme, identifier: String) {
        let ansi = theme.ansiColorHexes
        self.base = RemoteTextEditorTheme.isDark(theme.backgroundColor) ? "vs-dark" : "vs"
        self.inherit = true
        self.colors = [
            "editor.background": theme.backgroundHex,
            "editor.foreground": theme.foregroundHex,
            "editorCursor.foreground": theme.cursorHex ?? theme.foregroundHex,
            "editor.selectionBackground": theme.selectionBackgroundHex ?? ansi[safe: 8] ?? "#264F78",
            "editorLineNumber.foreground": ansi[safe: 8] ?? "#5C6370",
            "editorLineNumber.activeForeground": theme.foregroundHex,
            "editorIndentGuide.background": ansi[safe: 8] ?? "#3B4252",
            "editorWhitespace.foreground": ansi[safe: 8] ?? "#4C566A"
        ]
        self.rules = [
            MonacoThemeRulePayload(token: "comment", foreground: Self.stripHash(ansi[safe: 8] ?? "#6A737D"), fontStyle: "italic"),
            MonacoThemeRulePayload(token: "keyword", foreground: Self.stripHash(ansi[safe: 4] ?? "#61AFEF"), fontStyle: nil),
            MonacoThemeRulePayload(token: "string", foreground: Self.stripHash(ansi[safe: 2] ?? "#98C379"), fontStyle: nil),
            MonacoThemeRulePayload(token: "number", foreground: Self.stripHash(ansi[safe: 3] ?? "#E5C07B"), fontStyle: nil),
            MonacoThemeRulePayload(token: "type", foreground: Self.stripHash(ansi[safe: 6] ?? "#56B6C2"), fontStyle: nil),
            MonacoThemeRulePayload(token: "delimiter", foreground: Self.stripHash(theme.foregroundHex), fontStyle: nil),
            MonacoThemeRulePayload(token: "invalid", foreground: Self.stripHash(ansi[safe: 1] ?? "#E06C75"), fontStyle: nil)
        ]
    }

    private static func stripHash(_ hex: String) -> String {
        String(hex.drop { $0 == "#" })
    }
}

public struct MonacoThemeRulePayload: Encodable, Equatable {
    public let token: String
    public let foreground: String
    public let fontStyle: String?
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public enum RemoteTextEditorCloseDecision: Equatable {
    case save
    case discard
    case cancel
}

public enum RemoteTextEditorCloseDisposition: Equatable {
    case ready
    case pending
    case cancelled
}

public enum RemoteTextEditorCloseResolution: Equatable {
    case ready
    case cancelled
}

public enum RemoteTextEditorSaveState: Equatable {
    case saved
    case dirty
    case saving
    case failed

    var displayText: String {
        switch self {
        case .saved:
            return "已保存"
        case .dirty:
            return "未保存改动"
        case .saving:
            return "正在保存…"
        case .failed:
            return "保存失败"
        }
    }
}

public typealias RemoteTextEditorAsyncSaveHandler = (
    _ text: String,
    _ completion: @escaping @MainActor (Result<Void, Error>) -> Void
) -> Void

public enum RemoteTextEditorError: Error, LocalizedError, Equatable {
    case nonUTF8Text(String)
    case openFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .nonUTF8Text(let fileName):
            return "“\(fileName)”不是 UTF-8 纯文本，无法在 Stacio 编辑器中编辑。"
        case .openFailed(let fileName, let message):
            return "无法打开“\(fileName)”：\(message)"
        }
    }
}

public struct RemoteTextEditorDocumentDescriptor: Equatable {
    public let documentID: String
    public let monacoURI: String
    public let remotePath: String
    public let fileName: String
    public let content: String
    public let encodingDisplayName: String
    public let contentKind: RemoteFileContentKind
    public let previewSource: String?
    public let byteCount: UInt64

    public init(
        documentID: String? = nil,
        monacoURI: String? = nil,
        remotePath: String,
        fileName: String,
        content: String,
        encodingDisplayName: String = "UTF-8",
        contentKind: RemoteFileContentKind = .text,
        previewSource: String? = nil,
        byteCount: UInt64 = 0
    ) {
        let fallbackIdentity = FileTransferDocumentIdentity.remote(
            runtimeID: "legacy",
            path: remotePath,
            fileName: fileName
        )
        self.documentID = documentID ?? fallbackIdentity.documentID
        self.monacoURI = monacoURI ?? fallbackIdentity.monacoURI
        self.remotePath = remotePath
        self.fileName = fileName
        self.content = content
        self.encodingDisplayName = encodingDisplayName
        self.contentKind = contentKind
        self.previewSource = previewSource
        self.byteCount = byteCount
    }
}

public struct RemoteTextEditorAIRequest: Equatable, Sendable {
    public let question: String
    public let attachment: AIAssistantAttachment

    public init(question: String, attachment: AIAssistantAttachment) {
        self.question = question
        self.attachment = attachment
    }
}

@MainActor
public protocol RemoteTextEditorCloseConfirming: AnyObject {
    func confirmClose(fileName: String, parentWindow: NSWindow?) -> RemoteTextEditorCloseDecision
}

public final class AppKitRemoteTextEditorCloseConfirmer: RemoteTextEditorCloseConfirming {
    public init() {}

    public func confirmClose(fileName: String, parentWindow: NSWindow?) -> RemoteTextEditorCloseDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "是否保存对“\(fileName)”的修改？"
        alert.informativeText = "如果不保存，修改内容会丢失，远端设备也不会更新。"
        alert.addButton(withTitle: L10n.Common.save)
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: L10n.Common.cancel)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }
}

public final class RemoteTextEditorViewController: NSViewController, WKNavigationDelegate {
    private static let aiDocumentAttachmentTextLimit = 12_000
    private static let maximumMonacoReadinessRecoveryReloads = 1
    private static let monacoReadinessGraceInterval: TimeInterval = 3
    private static let savedCloseHandshakeTimeout: TimeInterval = 2

    public let localURL: URL
    public var onDirtyStateChanged: ((Bool) -> Void)?
    public var onActiveDocumentChanged: ((String, Bool) -> Void)?
    public var onCloseRequested: (() -> Void)?
    public var onWindowCloseReady: (() -> Void)?
    public var onPendingCloseResolved: ((RemoteTextEditorCloseResolution) -> Void)?
    public var onAIQuestionRequested: ((RemoteTextEditorAIRequest) -> Void)?
    public var onBackupRequested: (() -> Void)?
    public var onRestoreRequested: (() -> Void)?
    public var onToggleCollapseRequested: (() -> Void)?
    public var onTogglePresentationRequested: (() -> Void)?
    public var onPresentationMenuRequested: ((NSView) -> Void)?
    public var onDragDetachRequested: ((NSEvent) -> Void)?
    var onWindowPresentationChanged: ((String, Bool) -> Void)?
    fileprivate var onStandaloneWindowCloseRequested: (() -> Void)?
    fileprivate var onStandaloneWindowCloseResolved: ((RemoteTextEditorCloseResolution) -> Void)?
    fileprivate var onStandaloneWindowPresentationChanged: ((String, Bool) -> Void)?

    private let settingsStore: AppSettingsStore
    private let localTextIO: FileTransferLocalTextIO
    private var webView: WKWebView?
    private var monacoNavigation: WKNavigation?
    private let editorLoadingOverlay = NSView()
    private let editorLoadingIndicator = NSProgressIndicator()
    private let editorLoadingStatusLabel = NSTextField(labelWithString: "")
    private let editorLoadingRetryButton = NSButton(
        title: "重新加载",
        target: nil,
        action: nil
    )
    private var scriptMessageHandler: RemoteTextEditorScriptMessageHandler?
    private var settingsObserver: NSObjectProtocol?
    private var liveResizeEndObserver: NSObjectProtocol?
    private var documents: [RemoteTextEditorDocument]
    private var activeDocumentID: String
    private var currentThemeIdentifier = "vs-dark"
    private var isMonacoRuntimeReady = false
    private var isEditorReady = false
    private var lastRequestedEditorLayoutSize = NSSize.zero
    private var isEditorLayoutRequestPending = false
    private var forcePendingEditorLayoutRequest = false
    private var cursorLine = 1
    private var cursorColumn = 1
    private let editorOptionsDefaults: UserDefaults
    private var editorDisplayOptions: RemoteTextEditorDisplayOptions
    private weak var lineNumbersButton: NSButton?
    private weak var wordWrapButton: NSButton?
    private weak var minimapButton: NSButton?
    private weak var collapseButton: NSButton?
    private weak var presentationControl: NSSegmentedControl?
    private weak var toolbarDragHandle: RemoteEditorToolbarDragHandleView?
    private var presentationMainImageNameStorage = "macwindow.badge.plus"
    private var presentationControlsSnapshot = RemoteEditorPresentationSnapshot(
        mode: .docked,
        hasEditor: true,
        isTransitioning: false,
        detachedFeatureEnabled: true
    )
    private var tabDragMonitor: Any?
    private var tabDragStartPoint: NSPoint?
    private var tabDragPageLoadGeneration: Int?
    private var tabDragPointerID: Int?
    private var editorPointerEventMonitor: Any?
    private weak var editorPointerEventWindow: NSWindow?
    private var editorPointerEventWindowPreviouslyAcceptedMouseMovedEvents = false
    private var hasActiveEditorPrimaryPointerInteraction = false
    private var isEditorPointerRecoveryInFlight = false
    private var editorPointerRecoveryGeneration = 0
    private var editorFunctionCallsForTestingStorage: [String] = []
    private var editorFunctionScriptsForTestingStorage: [String] = []
    private var monacoPageLoadCountForTestingStorage = 0
    private var monacoReadinessRecoveryReloadCount = 0
    private var monacoInitializationWasInterruptedByLiveResize = false
    private var isEditorLiveResizeActive = false
    private var hasEditorBeenAttachedToWindow = false
    private var isEditorDetachedFromWindow = false
    private var isMonacoReadinessRecoveryScheduled = false
    private var monacoPageLoadGeneration = 0
    private var monacoReadinessWatchdogSequence = 0
    private var monacoReadinessWatchdog: DispatchWorkItem?
    private var pendingTabCloseDocumentIDs = Set<String>()
    private var pendingWindowCloseDocumentIDs = Set<String>()
    private var pendingSavedCloseHandshakes: [String: PendingSavedCloseHandshake] = [:]
    private var savedCloseHandshakeTimeouts: [String: DispatchWorkItem] = [:]
    private var pendingLocalDocumentLoadIDs = Set<String>()
    private var hasPendingWindowClose = false
    private var isEvaluatingWindowClose = false
    private var pendingCloseResolutionExpected = false

    public init(
        localURL: URL,
        settingsStore: AppSettingsStore = .shared,
        editorOptionsDefaults: UserDefaults = .standard,
        onSave: ((URL) throws -> Void)? = nil
    ) {
        self.localURL = localURL
        self.settingsStore = settingsStore
        self.localTextIO = .live
        self.editorOptionsDefaults = editorOptionsDefaults
        self.editorDisplayOptions = RemoteTextEditorDisplayOptions.load(defaults: editorOptionsDefaults)
        let document = Self.makeDocument(localURL: localURL, onSave: onSave)
        self.documents = [document]
        self.activeDocumentID = document.id
        super.init(nibName: nil, bundle: nil)
        title = localURL.lastPathComponent
        beginLoadingLocalDocument(localURL: localURL, onSave: onSave)
    }

    public init(
        document: RemoteTextEditorDocumentDescriptor,
        settingsStore: AppSettingsStore = .shared,
        editorOptionsDefaults: UserDefaults = .standard,
        onSaveText: ((String) throws -> Void)? = nil
    ) {
        self.localURL = URL(fileURLWithPath: document.remotePath)
        self.settingsStore = settingsStore
        self.localTextIO = .live
        self.editorOptionsDefaults = editorOptionsDefaults
        self.editorDisplayOptions = RemoteTextEditorDisplayOptions.load(defaults: editorOptionsDefaults)
        let editorDocument = Self.makeDocument(
            document: document,
            onSaveText: onSaveText,
            onSaveTextAsync: nil
        )
        self.documents = [editorDocument]
        self.activeDocumentID = editorDocument.id
        super.init(nibName: nil, bundle: nil)
        title = document.fileName
    }

    public init(
        document: RemoteTextEditorDocumentDescriptor,
        settingsStore: AppSettingsStore = .shared,
        editorOptionsDefaults: UserDefaults = .standard,
        onSaveTextAsync: @escaping RemoteTextEditorAsyncSaveHandler
    ) {
        self.localURL = URL(fileURLWithPath: document.remotePath)
        self.settingsStore = settingsStore
        self.localTextIO = .live
        self.editorOptionsDefaults = editorOptionsDefaults
        self.editorDisplayOptions = RemoteTextEditorDisplayOptions.load(defaults: editorOptionsDefaults)
        let editorDocument = Self.makeDocument(
            document: document,
            onSaveText: nil,
            onSaveTextAsync: onSaveTextAsync
        )
        self.documents = [editorDocument]
        self.activeDocumentID = editorDocument.id
        super.init(nibName: nil, bundle: nil)
        title = document.fileName
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let root = RemoteTextEditorRootView()
        root.onEffectiveAppearanceDidChange = { [weak self, weak root] in
            guard let self else { return }
            if let root {
                StacioDesignSystem.refreshDynamicLayerColors(in: root)
            }
            self.updateToolbarButtonStates()
            self.applyCurrentTheme()
        }
        root.onKeyEquivalent = { [weak self] event in
            self?.handleKeyEquivalent(event) ?? false
        }
        root.onLiveResizeStarted = { [weak self] in
            self?.editorLiveResizeDidStart()
        }
        root.onLiveResizeEnded = { [weak self] in
            self?.editorLiveResizeDidEnd()
        }
        root.onWindowChanged = { [weak self] window in
            self?.editorDidMoveToWindow(window)
        }
        root.wantsLayer = true
        root.setAccessibilityIdentifier("Stacio.Editor.root")

        let toolbar = makeToolbar()
        let editorWebView = makeWebView()
        let loadingOverlay = makeEditorLoadingOverlay()
        root.addSubview(toolbar)
        root.addSubview(editorWebView)
        root.addSubview(loadingOverlay)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 34),
            editorWebView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorWebView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorWebView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            editorWebView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: editorWebView.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: editorWebView.trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: editorWebView.topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: editorWebView.bottomAnchor)
        ])

        webView = editorWebView
        view = root
        observeSettingsChanges()
        observeWindowLiveResizeEnd()
        applyCurrentTheme()
        loadMonacoEditorHTML(resetReadinessRecoveryBudget: true)
        markDirtyIfNeeded()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        scheduleEditorLayoutIfNeeded()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
        scheduleEditorLayoutIfNeeded(force: true)
    }

    func synchronizeLayoutAfterContainerChange() {
        scheduleEditorLayoutIfNeeded(force: true)
    }

    private func editorLiveResizeDidStart() {
        isEditorLiveResizeActive = true
        if isEditorReady == false {
            monacoInitializationWasInterruptedByLiveResize = true
        }
    }

    private func editorLiveResizeDidEnd() {
        isEditorLiveResizeActive = false
        if isEditorReady {
            monacoInitializationWasInterruptedByLiveResize = false
            scheduleEditorLayoutIfNeeded(force: true)
            return
        }
        guard monacoInitializationWasInterruptedByLiveResize else { return }
        scheduleMonacoReadinessRecovery()
    }

    private func editorDidMoveToWindow(_ window: NSWindow?) {
        guard let window else {
            stopEditorPointerMonitoring()
            if hasEditorBeenAttachedToWindow {
                isEditorDetachedFromWindow = true
            }
            if isEditorLiveResizeActive, isEditorReady == false {
                monacoInitializationWasInterruptedByLiveResize = true
            }
            isEditorLiveResizeActive = false
            return
        }

        startEditorPointerMonitoring(in: window)
        hasEditorBeenAttachedToWindow = true
        isEditorDetachedFromWindow = false
        if window.inLiveResize {
            editorLiveResizeDidStart()
        } else if monacoInitializationWasInterruptedByLiveResize {
            editorLiveResizeDidEnd()
        } else if isEditorReady {
            scheduleEditorLayoutIfNeeded(force: true)
        }
    }

    private func scheduleMonacoReadinessRecovery() {
        guard isMonacoReadinessRecoveryScheduled == false else { return }
        let pageLoadGeneration = monacoPageLoadGeneration
        isMonacoReadinessRecoveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isMonacoReadinessRecoveryScheduled = false
            guard self.monacoPageLoadGeneration == pageLoadGeneration else { return }
            self.recoverMonacoReadinessIfNeeded()
        }
    }

    private func recoverMonacoReadinessIfNeeded() {
        if isEditorReady {
            monacoInitializationWasInterruptedByLiveResize = false
            scheduleEditorLayoutIfNeeded(force: true)
            return
        }
        if isEditorDetachedFromWindow {
            monacoInitializationWasInterruptedByLiveResize = true
            return
        }
        if isEditorLiveResizeActive || view.window?.inLiveResize == true {
            monacoInitializationWasInterruptedByLiveResize = true
            return
        }
        guard monacoReadinessRecoveryReloadCount < Self.maximumMonacoReadinessRecoveryReloads else {
            showMonacoLoadFailure()
            return
        }

        monacoReadinessRecoveryReloadCount += 1
        monacoInitializationWasInterruptedByLiveResize = false
        loadMonacoEditorHTML()
    }

    private func scheduleMonacoReadinessWatchdog() {
        cancelMonacoReadinessWatchdog()
        let watchdogSequence = monacoReadinessWatchdogSequence
        let pageLoadGeneration = monacoPageLoadGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.monacoReadinessWatchdogSequence == watchdogSequence,
                  self.monacoPageLoadGeneration == pageLoadGeneration
            else { return }
            self.monacoReadinessWatchdog = nil
            guard self.isEditorReady == false else { return }

            if self.isEditorDetachedFromWindow {
                self.monacoInitializationWasInterruptedByLiveResize = true
                return
            }
            if self.isEditorLiveResizeActive || self.view.window?.inLiveResize == true {
                self.monacoInitializationWasInterruptedByLiveResize = true
                return
            }
            self.scheduleMonacoReadinessRecovery()
        }
        monacoReadinessWatchdog = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.monacoReadinessGraceInterval,
            execute: workItem
        )
    }

    private func cancelMonacoReadinessWatchdog() {
        monacoReadinessWatchdogSequence += 1
        monacoReadinessWatchdog?.cancel()
        monacoReadinessWatchdog = nil
    }

    /// 编辑器就绪前给 WKWebView 的 layer 设置不透明背景色，
    /// 遮盖 WebContent 进程启动期间的默认黑色；
    /// 就绪后清除 layer 背景色让 Monaco 接管渲染。
    private func updateWebViewVisibilityForEditorReadiness() {
        if isEditorReady {
            webView?.layer?.backgroundColor = nil
        } else {
            webView?.layer?.backgroundColor = (currentThemeIdentifier == "vs-dark"
                ? NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.078, alpha: 1)
                : NSColor.textBackgroundColor
            ).cgColor
        }
    }

    private func showMonacoLoading() {
        editorLoadingOverlay.isHidden = false
        editorLoadingStatusLabel.stringValue = "正在加载编辑器..."
        editorLoadingRetryButton.isHidden = true
        editorLoadingIndicator.isHidden = false
        editorLoadingIndicator.startAnimation(nil)
    }

    private func showMonacoLoadFailure() {
        cancelMonacoReadinessWatchdog()
        isMonacoRuntimeReady = false
        isEditorReady = false
        updateWebViewVisibilityForEditorReadiness()
        editorLoadingOverlay.isHidden = false
        editorLoadingStatusLabel.stringValue = "编辑器加载失败"
        editorLoadingIndicator.stopAnimation(nil)
        editorLoadingIndicator.isHidden = true
        editorLoadingRetryButton.isHidden = false
    }

    private func hideMonacoLoading() {
        editorLoadingIndicator.stopAnimation(nil)
        editorLoadingOverlay.isHidden = true
    }

    @objc private func retryMonacoLoading(_ sender: NSButton) {
        loadMonacoEditorHTML(resetReadinessRecoveryBudget: true)
    }

    private func scheduleEditorLayoutIfNeeded(force: Bool = false) {
        forcePendingEditorLayoutRequest = forcePendingEditorLayoutRequest || force
        guard isEditorReady,
              let webView
        else { return }
        guard webView.bounds.width > 0,
              webView.bounds.height > 0
        else {
            forcePendingEditorLayoutRequest = true
            return
        }

        let currentSize = webView.bounds.size
        guard forcePendingEditorLayoutRequest || currentSize != lastRequestedEditorLayoutSize else {
            return
        }
        guard isEditorLayoutRequestPending == false else { return }

        isEditorLayoutRequestPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isEditorLayoutRequestPending = false
            guard self.isEditorReady,
                  let webView = self.webView
            else { return }
            guard webView.bounds.width > 0,
                  webView.bounds.height > 0
            else {
                self.forcePendingEditorLayoutRequest = true
                return
            }

            let latestSize = webView.bounds.size
            let shouldForce = self.forcePendingEditorLayoutRequest
            self.forcePendingEditorLayoutRequest = false
            guard shouldForce || latestSize != self.lastRequestedEditorLayoutSize else { return }
            self.lastRequestedEditorLayoutSize = latestSize
            self.callEditorFunction("layout", payload: EmptyEditorPayload())
        }
    }

    public var hasUnsavedChanges: Bool {
        documents.contains(where: \.isDirty)
    }

    public var hasUnsavedChangesForTesting: Bool {
        hasUnsavedChanges
    }

    public var isMonacoBackedForTesting: Bool {
        webView != nil
    }

    public var currentTextForTesting: String {
        activeDocument?.text ?? ""
    }

    public var languageIdentifierForTesting: String {
        activeDocument?.languageIdentifier ?? "plaintext"
    }

    public var currentThemeIdentifierForTesting: String {
        currentThemeIdentifier
    }

    public var encodingTextForTesting: String {
        activeDocument?.canEdit == true ? activeDocument?.encodingDisplayName ?? "-" : "-"
    }

    public var canEditTextForTesting: Bool {
        activeDocument?.canEdit ?? false
    }

    public var editorErrorTextForTesting: String? {
        activeDocument?.errorText
    }

    public var tabTitlesForTesting: [String] {
        documents.map(\.fileName)
    }

    public var documentIDsForTesting: [String] {
        documents.map(\.id)
    }

    public var documentMonacoURIsForTesting: [String] {
        documents.map(\.monacoURI)
    }

    public var dirtyTabTitlesForTesting: [String] {
        documents.filter(\.isDirty).map(\.fileName)
    }

    public var activeDocumentLocalURL: URL? {
        activeDocument?.localURL
    }

    public var documentLocalURLs: [URL] {
        documents.map(\.localURL)
    }

    public var activeDocumentRemotePath: String? {
        activeDocument?.path
    }

    public var documentBackupCandidates: [RemoteTextEditorBackupCandidate] {
        let orderedDocuments: [RemoteTextEditorDocument]
        if let activeDocument {
            orderedDocuments = [activeDocument] + documents.filter { $0.id != activeDocument.id }
        } else {
            orderedDocuments = documents
        }
        return orderedDocuments.map { document in
            RemoteTextEditorBackupCandidate(
                fileName: document.fileName,
                remotePath: document.path,
                localURL: document.localURL,
                size: document.byteCount
            )
        }
    }

    public var activeDocumentLocalURLForTesting: URL? {
        activeDocumentLocalURL
    }

    public var documentLocalURLsForTesting: [URL] {
        documentLocalURLs
    }

    public var activeFileNameForTesting: String {
        activeDocument?.fileName ?? localURL.lastPathComponent
    }

    public var activeDocumentDisplayModeForTesting: String {
        activeDocument?.displayMode.rawValue ?? RemoteTextEditorDocumentDisplayMode.text.rawValue
    }

    public var activeMediaPreviewSourceForTesting: String? {
        activeDocument?.previewSource
    }

    public var lineNumbersForTesting: [String] {
        (1...lineCount(for: currentTextForTesting)).map(String.init)
    }

    public var editorHTMLForTesting: String {
        Self.editorHTML(pageLoadGeneration: monacoPageLoadGeneration)
    }

    public var presentationMainImageNameForTesting: String? {
        presentationMainImageNameStorage
    }

    public var presentationDisplayImageNameForTesting: String {
        "display"
    }

    public var presentationMainTooltipForTesting: String? {
        presentationControl?.toolTip
    }

    public var toolbarControlFramesForTesting: [NSRect] {
        toolbarViewForTesting()?.subviews
            .flatMap { $0.subviews }
            .filter { $0 is NSButton || $0 is NSSegmentedControl || $0 is RemoteEditorToolbarDragHandleView }
            .map { $0.frame } ?? []
    }

    private func toolbarViewForTesting() -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "Stacio.Editor.Toolbar" { return view }
            for child in view.subviews {
                if let found = find(child) { return found }
            }
            return nil
        }
        return find(view)
    }

    public var pageLoadGenerationForTesting: Int { monacoPageLoadGeneration }

    public func updatePresentationControls(_ snapshot: RemoteEditorPresentationSnapshot) {
        presentationControlsSnapshot = snapshot
        collapseButton?.isEnabled = snapshot.canCollapse && snapshot.isTransitioning == false
        guard let control = presentationControl else { return }
        let isDetached = snapshot.isDetached
        let locked = snapshot.detachedFeatureEnabled == false && isDetached == false
        let imageName = locked ? "lock" : (isDetached ? "rectangle.portrait.and.arrow.right" : "macwindow.badge.plus")
        presentationMainImageNameStorage = imageName
        control.setImage(NSImage(systemSymbolName: imageName, accessibilityDescription: nil), forSegment: 0)
        let tooltip = isDetached ? L10n.EditorPresentation.redock
            : (locked ? L10n.EditorPresentation.detachRequiresLicense : L10n.EditorPresentation.detach)
        control.toolTip = tooltip
        control.setAccessibilityLabel(tooltip)
        control.isEnabled = snapshot.hasEditor && snapshot.isTransitioning == false
    }

    public func requestTogglePresentationForTesting() { onTogglePresentationRequested?() }

    public func simulateToolbarDragForTesting(buttonNumber: Int, points: [NSPoint]) {
        guard buttonNumber == 0, let start = points.first, let end = points.last,
              hypot(end.x - start.x, end.y - start.y) > 8 else { return }
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: end,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        onDragDetachRequested?(event)
    }

    public var isTabDragTrackingForTesting: Bool {
        tabDragStartPoint != nil
    }

    var hasActiveEditorPrimaryPointerInteractionForTesting: Bool {
        hasActiveEditorPrimaryPointerInteraction
    }

    @discardableResult
    func simulateEditorPointerEventForTesting(
        eventType: NSEvent.EventType,
        isInsideWebView: Bool,
        pressedMouseButtons: Int,
        pointerClientPoint: NSPoint? = nil
    ) -> Bool {
        handleEditorPointerEvent(
            eventType: eventType,
            isInsideWebView: isInsideWebView,
            pressedMouseButtons: pressedMouseButtons,
            pointerClientPoint: pointerClientPoint
        )
    }

    public func receiveTabDragCandidateForTesting(
        pageLoadGeneration: Int,
        pointInWindow: NSPoint,
        pointerID: Int = 1,
        eventButtons: Int = 1,
        pressedMouseButtons: Int = 1
    ) {
        beginTabDragCandidate(
            pageLoadGeneration: pageLoadGeneration,
            pointInWindow: pointInWindow,
            pointerID: pointerID,
            eventButtons: eventButtons,
            pressedMouseButtons: pressedMouseButtons
        )
    }

    private func beginTabDragCandidate(
        pageLoadGeneration: Int,
        pointInWindow: NSPoint,
        pointerID: Int,
        eventButtons: Int,
        pressedMouseButtons: Int
    ) {
        cancelTabDragTracking()
        // WKScriptMessage delivery is asynchronous. A quick click can release
        // before this candidate reaches AppKit, so require both snapshots to
        // still report the primary button as pressed before installing a monitor.
        guard pageLoadGeneration == monacoPageLoadGeneration,
              eventButtons & 1 != 0,
              pressedMouseButtons & 1 != 0
        else {
            return
        }
        tabDragStartPoint = pointInWindow
        tabDragPageLoadGeneration = pageLoadGeneration
        tabDragPointerID = pointerID
        tabDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.view.window else {
                self.cancelTabDragTracking()
                return event
            }
            self.handleTrackedTabDragEvent(event)
            return event
        }
    }

    public func simulateTrackedTabDragForTesting(
        to point: NSPoint,
        eventType: NSEvent.EventType = .leftMouseDragged,
        buttonNumber: Int = 0,
        pressedMouseButtons: Int = 1
    ) {
        guard let event = NSEvent.mouseEvent(
            with: eventType,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        handleTrackedTabDragEvent(
            eventType: eventType,
            buttonNumber: buttonNumber,
            pressedMouseButtons: pressedMouseButtons,
            pointInWindow: point,
            event: event
        )
    }

    private func handleTrackedTabDragEvent(_ event: NSEvent) {
        handleTrackedTabDragEvent(
            eventType: event.type,
            buttonNumber: event.buttonNumber,
            pressedMouseButtons: NSEvent.pressedMouseButtons,
            pointInWindow: event.locationInWindow,
            event: event
        )
    }

    private func handleTrackedTabDragEvent(
        eventType: NSEvent.EventType,
        buttonNumber: Int,
        pressedMouseButtons: Int,
        pointInWindow: NSPoint,
        event: NSEvent
    ) {
        if eventType == .leftMouseUp || pressedMouseButtons & 1 == 0 {
            cancelTabDragTracking()
            return
        }
        guard eventType == .leftMouseDragged,
              buttonNumber == 0,
              let start = tabDragStartPoint,
              tabDragPageLoadGeneration == monacoPageLoadGeneration,
              hypot(pointInWindow.x - start.x, pointInWindow.y - start.y) > 8
        else { return }
        cancelTabDragTracking()
        onDragDetachRequested?(event)
    }

    private func cancelTabDragTracking() {
        if let tabDragMonitor {
            NSEvent.removeMonitor(tabDragMonitor)
            self.tabDragMonitor = nil
        }
        tabDragStartPoint = nil
        tabDragPageLoadGeneration = nil
        tabDragPointerID = nil
    }

    private func installEditorPointerEventMonitorIfNeeded() {
        guard editorPointerEventMonitor == nil else { return }
        editorPointerEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved]
        ) { [weak self] event in
            guard let self else { return event }
            let pointerContext = self.editorPointerContext(for: event)
            let shouldConsume = self.handleEditorPointerEvent(
                eventType: event.type,
                isInsideWebView: pointerContext.isInsideWebView,
                pressedMouseButtons: NSEvent.pressedMouseButtons,
                pointerClientPoint: pointerContext.clientPoint
            )
            return shouldConsume ? nil : event
        }
    }

    private func startEditorPointerMonitoring(in window: NSWindow) {
        if editorPointerEventWindow !== window {
            stopEditorPointerMonitoring()
            editorPointerEventWindow = window
            editorPointerEventWindowPreviouslyAcceptedMouseMovedEvents = window.acceptsMouseMovedEvents
        }
        window.acceptsMouseMovedEvents = true
        installEditorPointerEventMonitorIfNeeded()
    }

    private func stopEditorPointerMonitoring() {
        removeEditorPointerEventMonitor()
        if let editorPointerEventWindow {
            editorPointerEventWindow.acceptsMouseMovedEvents =
                editorPointerEventWindowPreviouslyAcceptedMouseMovedEvents
        }
        editorPointerEventWindow = nil
        editorPointerEventWindowPreviouslyAcceptedMouseMovedEvents = false
        resetEditorPointerInteractionState()
    }

    private func removeEditorPointerEventMonitor() {
        guard let editorPointerEventMonitor else { return }
        NSEvent.removeMonitor(editorPointerEventMonitor)
        self.editorPointerEventMonitor = nil
    }

    private func editorPointerContext(
        for event: NSEvent
    ) -> (isInsideWebView: Bool, clientPoint: NSPoint?) {
        guard let webView,
              event.window === webView.window
        else { return (false, nil) }
        let pointInWebView = webView.convert(event.locationInWindow, from: nil)
        let clientPoint = NSPoint(
            x: pointInWebView.x - webView.bounds.minX,
            y: webView.bounds.maxY - pointInWebView.y
        )
        return (webView.bounds.contains(pointInWebView), clientPoint)
    }

    @discardableResult
    private func handleEditorPointerEvent(
        eventType: NSEvent.EventType,
        isInsideWebView: Bool,
        pressedMouseButtons: Int,
        pointerClientPoint: NSPoint? = nil
    ) -> Bool {
        switch eventType {
        case .leftMouseDown:
            guard isInsideWebView else { return false }
            editorPointerRecoveryGeneration += 1
            isEditorPointerRecoveryInFlight = false
            hasActiveEditorPrimaryPointerInteraction = true
        case .leftMouseUp:
            guard hasActiveEditorPrimaryPointerInteraction else { return false }
            hasActiveEditorPrimaryPointerInteraction = false
            scheduleStaleEditorPointerCheckAfterNativeMouseUp(at: pointerClientPoint)
        case .mouseMoved, .leftMouseDragged:
            if isInsideWebView,
               isEditorPointerRecoveryInFlight,
               pressedMouseButtons & 1 == 0
            {
                return true
            }
            guard isInsideWebView,
                  hasActiveEditorPrimaryPointerInteraction,
                  pressedMouseButtons & 1 == 0
            else { return false }
            hasActiveEditorPrimaryPointerInteraction = false
            releaseStaleEditorPointerInteraction(at: pointerClientPoint)
            return true
        default:
            break
        }
        return false
    }

    private func scheduleStaleEditorPointerCheckAfterNativeMouseUp(at pointerClientPoint: NSPoint?) {
        editorPointerRecoveryGeneration += 1
        let generation = editorPointerRecoveryGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.editorPointerRecoveryGeneration == generation,
                  self.hasActiveEditorPrimaryPointerInteraction == false
            else { return }
            self.releaseStaleEditorPointerInteraction(at: pointerClientPoint)
        }
    }

    private func releaseStaleEditorPointerInteraction(at pointerClientPoint: NSPoint?) {
        guard isEditorPointerRecoveryInFlight == false else { return }
        editorPointerRecoveryGeneration += 1
        let generation = editorPointerRecoveryGeneration
        let requestedAtEpochMilliseconds = Date().timeIntervalSince1970 * 1_000
        isEditorPointerRecoveryInFlight = true
        callEditorFunction(
            "releaseStalePointerInteraction",
            payload: EditorPointerReleasePayload(
                notAfterEpochMilliseconds: requestedAtEpochMilliseconds,
                clientX: pointerClientPoint.map { Double($0.x) },
                clientY: pointerClientPoint.map { Double($0.y) }
            ),
            requiresFunction: true
        ) { [weak self] _ in
            guard let self,
                  self.editorPointerRecoveryGeneration == generation
            else { return }
            self.isEditorPointerRecoveryInFlight = false
        }
    }

    private func resetEditorPointerInteractionState() {
        editorPointerRecoveryGeneration += 1
        hasActiveEditorPrimaryPointerInteraction = false
        isEditorPointerRecoveryInFlight = false
    }

    public var monacoPageLoadCountForTesting: Int {
        monacoPageLoadCountForTestingStorage
    }

    public var editorWebViewForTesting: WKWebView? {
        webView
    }

    public var editorFunctionCallsForTesting: [String] {
        editorFunctionCallsForTestingStorage
    }

    public var editorFunctionScriptsForTesting: [String] {
        editorFunctionScriptsForTestingStorage
    }

    public var activeSaveStateForTesting: RemoteTextEditorSaveState {
        activeDocument?.saveState ?? .saved
    }

    public var activeSaveStateTextForTesting: String {
        activeDocument?.saveStatusText ?? activeSaveStateForTesting.displayText
    }

    public var activeSaveStatusIsErrorForTesting: Bool {
        activeDocument?.saveStatusIsError ?? false
    }

    public var hasPendingLocalDocumentLoadsForTesting: Bool {
        pendingLocalDocumentLoadIDs.isEmpty == false
    }

    public func performSave() throws {
        guard let activeDocument else {
            return
        }
        try saveDocument(id: activeDocument.id)
    }

    public func performSaveForTesting() throws {
        try performSave()
    }

    public func requestCloseForTesting() {
        onCloseRequested?()
    }

    public func requestAIForActiveDocumentForTesting() {
        requestAIForActiveDocument()
    }

    public func replaceTextForTesting(_ text: String) {
        updateDocumentText(id: activeDocumentID, text: text)
        syncActiveDocumentToWebView()
    }

    public func markEditorReadyForTesting() {
        isMonacoRuntimeReady = true
        isEditorReady = true
        monacoInitializationWasInterruptedByLiveResize = false
        cancelMonacoReadinessWatchdog()
        updateWebViewVisibilityForEditorReadiness()
        hideMonacoLoading()
    }

    public func resetEditorFunctionCallsForTesting() {
        editorFunctionCallsForTestingStorage.removeAll()
        editorFunctionScriptsForTestingStorage.removeAll()
    }

    public func receiveSwitchTabMessageForTesting(
        targetFileName: String,
        currentFileName: String,
        currentContent: String
    ) {
        guard let targetDocument = documents.first(where: { $0.fileName == targetFileName }),
              let currentDocument = documents.first(where: { $0.fileName == currentFileName })
        else {
            return
        }
        handleSwitchTabRequest(
            targetID: targetDocument.id,
            currentID: currentDocument.id,
            content: currentContent
        )
    }

    public func openDocumentForTesting(localURL: URL) {
        openDocument(localURL: localURL, onSave: nil)
    }

    public func switchToDocumentForTesting(fileName: String) {
        guard let document = documents.first(where: { $0.fileName == fileName }) else {
            return
        }
        activateDocument(id: document.id)
    }

    public func closeDocumentForTesting(
        fileName: String,
        closeConfirmer: RemoteTextEditorCloseConfirming? = nil
    ) {
        guard let document = documents.first(where: { $0.fileName == fileName }) else {
            return
        }
        closeDocument(id: document.id, closeConfirmer: closeConfirmer)
    }

    public func openDocument(localURL: URL, onSave: ((URL) throws -> Void)? = nil) {
        if let existing = documents.first(where: { $0.localURL.path == localURL.path }) {
            activateDocument(id: existing.id)
            return
        }
        let document = Self.makeDocument(localURL: localURL, onSave: onSave)
        documents.append(document)
        activateDocument(id: document.id)
        beginLoadingLocalDocument(localURL: localURL, onSave: onSave)
    }

    public func openDocument(
        _ descriptor: RemoteTextEditorDocumentDescriptor,
        onSaveText: ((String) throws -> Void)? = nil
    ) {
        if let existing = documents.first(where: { $0.id == descriptor.documentID }) {
            Self.unregisterRemotePreviewSource(descriptor.previewSource)
            activateDocument(id: existing.id)
            return
        }
        let document = Self.makeDocument(
            document: descriptor,
            onSaveText: onSaveText,
            onSaveTextAsync: nil
        )
        documents.append(document)
        activateDocument(id: document.id)
    }

    public func openDocument(
        _ descriptor: RemoteTextEditorDocumentDescriptor,
        onSaveTextAsync: @escaping RemoteTextEditorAsyncSaveHandler
    ) {
        if let existing = documents.first(where: { $0.id == descriptor.documentID }) {
            Self.unregisterRemotePreviewSource(descriptor.previewSource)
            activateDocument(id: existing.id)
            return
        }
        let document = Self.makeDocument(
            document: descriptor,
            onSaveText: nil,
            onSaveTextAsync: onSaveTextAsync
        )
        documents.append(document)
        activateDocument(id: document.id)
    }

    public func openFailedDocument(
        remotePath: String,
        fileName: String,
        message: String,
        byteCount: UInt64 = 0
    ) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayMessage = trimmedMessage.isEmpty ? L10n.Files.operationFailedMessage : trimmedMessage
        if let existing = documents.first(where: { $0.path == remotePath }) {
            let failedDocument = Self.makeFailedDocument(
                remotePath: remotePath,
                fileName: fileName,
                message: displayMessage,
                byteCount: byteCount
            )
            if let index = documents.firstIndex(where: { $0.id == existing.id }) {
                documents[index] = failedDocument
                activateDocument(id: failedDocument.id)
            }
            return
        }
        let document = Self.makeFailedDocument(
            remotePath: remotePath,
            fileName: fileName,
            message: displayMessage,
            byteCount: byteCount
        )
        documents.append(document)
        activateDocument(id: document.id)
    }

    public func requestAIForActiveDocument() {
        guard let request = aiRequestForActiveDocument() else {
            return
        }
        onAIQuestionRequested?(request)
    }

    @discardableResult
    public func requestClose(
        parentWindow: NSWindow?,
        closeConfirmer: RemoteTextEditorCloseConfirming
    ) -> RemoteTextEditorCloseDisposition {
        cancelTabDragTracking()
        if hasPendingWindowClose {
            return .pending
        }
        guard pendingTabCloseDocumentIDs.isEmpty else {
            return .cancelled
        }
        pendingCloseResolutionExpected = false
        let dirtyDocumentIDs = documents.filter(\.isDirty).map(\.id)
        guard dirtyDocumentIDs.isEmpty == false else {
            return .ready
        }
        var decisions: [(documentID: String, decision: RemoteTextEditorCloseDecision)] = []
        for documentID in dirtyDocumentIDs {
            guard let document = document(id: documentID) else {
                continue
            }
            let decision = closeConfirmer.confirmClose(fileName: document.fileName, parentWindow: parentWindow)
            guard decision != .cancel else {
                return .cancelled
            }
            decisions.append((documentID, decision))
        }

        let asyncSaveDocumentIDs = Set(decisions.compactMap { item -> String? in
            guard item.decision == .save,
                  document(id: item.documentID)?.onSaveTextAsync != nil
            else { return nil }
            return item.documentID
        })
        hasPendingWindowClose = asyncSaveDocumentIDs.isEmpty == false
        pendingWindowCloseDocumentIDs = asyncSaveDocumentIDs
        isEvaluatingWindowClose = true
        for item in decisions where item.decision == .save {
            do {
                try saveDocument(id: item.documentID)
            } catch {
                cancelPendingWindowClose()
                isEvaluatingWindowClose = false
                presentSaveError(error, parentWindow: parentWindow)
                return .cancelled
            }
        }
        isEvaluatingWindowClose = false

        let asyncSaveFailedOrChanged = asyncSaveDocumentIDs.contains { documentID in
            guard let document = document(id: documentID) else { return true }
            return document.saveState == .failed || (document.saveState != .saving && document.isDirty)
        }
        if asyncSaveFailedOrChanged {
            cancelPendingWindowClose()
            return .cancelled
        }
        if hasPendingWindowClose, pendingWindowCloseDocumentIDs.isEmpty {
            hasPendingWindowClose = false
        }
        guard hasPendingWindowClose else {
            return .ready
        }
        pendingCloseResolutionExpected = true
        return .pending
    }

    @discardableResult
    public func canClose(
        parentWindow: NSWindow?,
        closeConfirmer: RemoteTextEditorCloseConfirming
    ) -> Bool {
        requestClose(parentWindow: parentWindow, closeConfirmer: closeConfirmer) == .ready
    }

    deinit {
        if let tabDragMonitor { NSEvent.removeMonitor(tabDragMonitor) }
        if let editorPointerEventMonitor { NSEvent.removeMonitor(editorPointerEventMonitor) }
        if let editorPointerEventWindow {
            editorPointerEventWindow.acceptsMouseMovedEvents =
                editorPointerEventWindowPreviouslyAcceptedMouseMovedEvents
        }
        monacoReadinessWatchdog?.cancel()
        savedCloseHandshakeTimeouts.values.forEach { $0.cancel() }
        for document in documents {
            Self.unregisterRemotePreviewSource(document.previewSource)
        }
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let liveResizeEndObserver {
            NotificationCenter.default.removeObserver(liveResizeEndObserver)
        }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "stacioEditor")
    }

    private static func makeDocument(
        localURL: URL,
        onSave _: ((URL) throws -> Void)?
    ) -> RemoteTextEditorDocument {
        let identity = FileTransferDocumentIdentity.local(url: localURL)
        let fileName = localURL.lastPathComponent
        let contentKind = StacioFileDisplay.contentKind(forFileName: fileName)
        if let displayMode = RemoteTextEditorDocumentDisplayMode(contentKind: contentKind),
           displayMode != .text
        {
            return RemoteTextEditorDocument(
                id: identity.documentID,
                monacoURI: identity.monacoURI,
                localURL: localURL,
                fileName: fileName,
                path: localURL.path,
                byteCount: localFileByteCount(at: localURL),
                text: "",
                originalText: "",
                languageIdentifier: displayMode.rawValue,
                canEdit: false,
                errorText: nil,
                onSaveText: nil,
                onSaveTextAsync: nil,
                encodingDisplayName: "-",
                saveState: .saved,
                displayMode: displayMode,
                previewSource: mediaPreviewSource(for: localURL, contentKind: contentKind),
                fileSizeText: fileSizeText(for: localURL)
            )
        }

        return RemoteTextEditorDocument(
            id: identity.documentID,
            monacoURI: identity.monacoURI,
            localURL: localURL,
            fileName: fileName,
            path: localURL.path,
            byteCount: localFileByteCount(at: localURL),
            text: "",
            originalText: "",
            languageIdentifier: StacioFileDisplay.languageIdentifier(forFileName: fileName),
            canEdit: false,
            errorText: nil,
            onSaveText: nil,
            onSaveTextAsync: nil,
            encodingDisplayName: "-",
            saveState: .saved,
            displayMode: .text,
            previewSource: nil,
            fileSizeText: fileSizeText(for: localURL)
        )
    }

    private func beginLoadingLocalDocument(
        localURL: URL,
        onSave: ((URL) throws -> Void)?
    ) {
        let identity = FileTransferDocumentIdentity.local(url: localURL)
        guard let current = document(id: identity.documentID),
              current.displayMode == .text,
              pendingLocalDocumentLoadIDs.insert(identity.documentID).inserted
        else { return }
        localTextIO.load(url: localURL) { [weak self] result in
            guard let self else { return }
            self.pendingLocalDocumentLoadIDs.remove(identity.documentID)
            guard let index = self.documents.firstIndex(where: { $0.id == identity.documentID }) else {
                return
            }
            switch result {
            case .success(let loaded):
                self.documents[index] = Self.makeLoadedLocalTextDocument(
                    localURL: localURL,
                    loaded: loaded,
                    localTextIO: self.localTextIO,
                    onSave: onSave
                )
            case .failure(let error):
                self.documents[index] = Self.makeFailedLocalTextDocument(
                    localURL: localURL,
                    byteCount: current.byteCount,
                    message: RuntimeDiagnosticFormatter.userMessage(for: error)
                )
            }
            self.markDirtyIfNeeded()
            self.syncWorkspaceToWebView()
        }
    }

    private static func makeLoadedLocalTextDocument(
        localURL: URL,
        loaded: FileTransferLocalTextReadResult,
        localTextIO: FileTransferLocalTextIO,
        onSave: ((URL) throws -> Void)?
    ) -> RemoteTextEditorDocument {
        guard let textDocument = loaded.document else {
            return makeFailedLocalTextDocument(
                localURL: localURL,
                byteCount: loaded.byteCount,
                message: RemoteTextEditorError.nonUTF8Text(localURL.lastPathComponent).localizedDescription
            )
        }
        let identity = FileTransferDocumentIdentity.local(url: localURL)
        let fileName = localURL.lastPathComponent
        return RemoteTextEditorDocument(
            id: identity.documentID,
            monacoURI: identity.monacoURI,
            localURL: localURL,
            fileName: fileName,
            path: localURL.path,
            byteCount: loaded.byteCount,
            text: textDocument.text,
            originalText: textDocument.text,
            languageIdentifier: StacioFileDisplay.languageIdentifier(
                forFileName: fileName,
                content: textDocument.text
            ),
            canEdit: true,
            errorText: nil,
            onSaveText: nil,
            onSaveTextAsync: { updatedText, completion in
                localTextIO.save(
                    document: textDocument,
                    updatedText: updatedText,
                    fileName: fileName,
                    url: localURL,
                    afterWrite: { try onSave?(localURL) },
                    completion: completion
                )
            },
            encodingDisplayName: textDocument.encoding.displayName,
            saveState: .saved,
            displayMode: .text,
            previewSource: nil,
            fileSizeText: fileSizeText(byteCount: loaded.byteCount)
        )
    }

    private static func makeFailedLocalTextDocument(
        localURL: URL,
        byteCount: UInt64,
        message: String
    ) -> RemoteTextEditorDocument {
        let identity = FileTransferDocumentIdentity.local(url: localURL)
        let fileName = localURL.lastPathComponent
        return RemoteTextEditorDocument(
            id: identity.documentID,
            monacoURI: identity.monacoURI,
            localURL: localURL,
            fileName: fileName,
            path: localURL.path,
            byteCount: byteCount,
            text: "",
            originalText: "",
            languageIdentifier: StacioFileDisplay.languageIdentifier(forFileName: fileName),
            canEdit: false,
            errorText: message,
            onSaveText: nil,
            onSaveTextAsync: nil,
            encodingDisplayName: "-",
            saveState: .saved,
            displayMode: .text,
            previewSource: nil,
            fileSizeText: fileSizeText(byteCount: byteCount)
        )
    }

    private static func makeDocument(
        document: RemoteTextEditorDocumentDescriptor,
        onSaveText: ((String) throws -> Void)?,
        onSaveTextAsync: RemoteTextEditorAsyncSaveHandler?
    ) -> RemoteTextEditorDocument {
        let displayMode = RemoteTextEditorDocumentDisplayMode(contentKind: document.contentKind) ?? .text
        let localURL = URL(fileURLWithPath: document.remotePath)
        if displayMode != .text {
            return RemoteTextEditorDocument(
                id: document.documentID,
                monacoURI: document.monacoURI,
                localURL: localURL,
                fileName: document.fileName,
                path: document.remotePath,
                byteCount: document.byteCount,
                text: "",
                originalText: "",
                languageIdentifier: displayMode.rawValue,
                canEdit: false,
                errorText: nil,
                onSaveText: nil,
                onSaveTextAsync: nil,
                encodingDisplayName: "-",
                saveState: .saved,
                displayMode: displayMode,
                previewSource: document.previewSource,
                fileSizeText: fileSizeText(byteCount: document.byteCount)
            )
        }

        return RemoteTextEditorDocument(
            id: document.documentID,
            monacoURI: document.monacoURI,
            localURL: localURL,
            fileName: document.fileName,
            path: document.remotePath,
            byteCount: document.byteCount,
            text: document.content,
            originalText: document.content,
            languageIdentifier: StacioFileDisplay.languageIdentifier(
                forFileName: document.fileName,
                content: document.content
            ),
            canEdit: true,
            errorText: nil,
            onSaveText: onSaveText,
            onSaveTextAsync: onSaveTextAsync,
            encodingDisplayName: document.encodingDisplayName,
            saveState: .saved,
            displayMode: .text,
            previewSource: nil,
            fileSizeText: fileSizeText(byteCount: document.byteCount)
        )
    }

    private static func makeFailedDocument(
        remotePath: String,
        fileName: String,
        message: String,
        byteCount: UInt64
    ) -> RemoteTextEditorDocument {
        let identity = FileTransferDocumentIdentity.remote(
            runtimeID: "legacy",
            path: remotePath,
            fileName: fileName
        )
        return RemoteTextEditorDocument(
            id: identity.documentID,
            monacoURI: identity.monacoURI,
            localURL: URL(fileURLWithPath: remotePath),
            fileName: fileName,
            path: remotePath,
            byteCount: byteCount,
            text: "",
            originalText: "",
            languageIdentifier: StacioFileDisplay.languageIdentifier(forFileName: fileName),
            canEdit: false,
            errorText: RemoteTextEditorError.openFailed(fileName, message).localizedDescription,
            onSaveText: nil,
            onSaveTextAsync: nil,
            encodingDisplayName: "-",
            saveState: .failed,
            displayMode: .text,
            previewSource: nil,
            fileSizeText: fileSizeText(byteCount: byteCount)
        )
    }

    private static func mediaPreviewSource(for localURL: URL, contentKind: RemoteFileContentKind) -> String? {
        guard let data = try? Data(contentsOf: localURL) else {
            return nil
        }
        return "data:\(mimeType(for: localURL, contentKind: contentKind));base64,\(data.base64EncodedString())"
    }

    private static func mimeType(for localURL: URL, contentKind: RemoteFileContentKind) -> String {
        let fileExtension = localURL.pathExtension.lowercased()
        switch fileExtension {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "bmp":
            return "image/bmp"
        case "webp":
            return "image/webp"
        case "svg":
            return "image/svg+xml"
        case "ico":
            return "image/x-icon"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "ogg":
            return "audio/ogg"
        case "aac":
            return "audio/aac"
        case "flac":
            return "audio/flac"
        case "m4a":
            return "audio/mp4"
        case "mp4":
            return "video/mp4"
        case "webm":
            return "video/webm"
        case "avi":
            return "video/x-msvideo"
        case "mov":
            return "video/quicktime"
        case "mkv":
            return "video/x-matroska"
        default:
            switch contentKind {
            case .image:
                return "image/*"
            case .audio:
                return "audio/*"
            case .video:
                return "video/*"
            case .text, .other:
                return "application/octet-stream"
            }
        }
    }

    private static func fileSizeText(for localURL: URL) -> String {
        let byteCount = localFileByteCount(at: localURL)
        return fileSizeText(byteCount: byteCount)
    }

    private static func fileSizeText(byteCount: UInt64) -> String {
        return String(format: "%.2f KB", Double(byteCount) / 1_024)
    }

    private static func localFileByteCount(at localURL: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?
            .uint64Value ?? 0
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            RemoteFileOnlineMediaSchemeHandler.shared,
            forURLScheme: RemoteFileOnlineMediaRegistry.scheme
        )
        let scriptHandler = RemoteTextEditorScriptMessageHandler(editor: self)
        configuration.userContentController.add(scriptHandler, name: "stacioEditor")
        scriptMessageHandler = scriptHandler

        let editorWebView = WKWebView(frame: .zero, configuration: configuration)
        editorWebView.translatesAutoresizingMaskIntoConstraints = false
        editorWebView.wantsLayer = true
        editorWebView.navigationDelegate = self
        editorWebView.setAccessibilityIdentifier("Stacio.Editor.webView")
        editorWebView.setValue(false, forKey: "drawsBackground")
        return editorWebView
    }

    private func makeEditorLoadingOverlay() -> NSView {
        editorLoadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        editorLoadingOverlay.wantsLayer = true
        editorLoadingOverlay.setAccessibilityIdentifier("Stacio.Editor.loadingOverlay")

        editorLoadingIndicator.style = .spinning
        editorLoadingIndicator.controlSize = .small
        editorLoadingIndicator.isDisplayedWhenStopped = false

        editorLoadingStatusLabel.alignment = .center
        editorLoadingStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        editorLoadingStatusLabel.setAccessibilityIdentifier("Stacio.Editor.loadingStatus")

        editorLoadingRetryButton.target = self
        editorLoadingRetryButton.action = #selector(retryMonacoLoading(_:))
        editorLoadingRetryButton.bezelStyle = .rounded
        editorLoadingRetryButton.controlSize = .small
        editorLoadingRetryButton.setAccessibilityIdentifier("Stacio.Editor.retryLoading")

        let content = NSStackView(views: [
            editorLoadingIndicator,
            editorLoadingStatusLabel,
            editorLoadingRetryButton
        ])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        editorLoadingOverlay.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: editorLoadingOverlay.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: editorLoadingOverlay.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: editorLoadingOverlay.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: editorLoadingOverlay.trailingAnchor, constant: -16)
        ])
        return editorLoadingOverlay
    }

    private func makeToolbar() -> NSView {
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(toolbar)
        toolbar.setAccessibilityIdentifier("Stacio.Editor.Toolbar")

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        let lineNumbers = makeToolbarButton(
            symbolName: "list.number",
            accessibilityLabel: "显示或隐藏行号",
            identifier: "Stacio.Editor.Toolbar.lineNumbers",
            action: #selector(toggleLineNumbersPressed(_:)),
            isToggle: true
        )
        let wordWrap = makeToolbarButton(
            symbolName: "arrow.turn.down.right",
            accessibilityLabel: "开启或关闭自动换行",
            identifier: "Stacio.Editor.Toolbar.wordWrap",
            action: #selector(toggleWordWrapPressed(_:)),
            isToggle: true
        )
        let minimap = makeToolbarButton(
            symbolName: "map",
            accessibilityLabel: "显示或隐藏小地图",
            identifier: "Stacio.Editor.Toolbar.minimap",
            action: #selector(toggleMinimapPressed(_:)),
            isToggle: true
        )
        let find = makeToolbarButton(
            symbolName: "magnifyingglass",
            accessibilityLabel: "查找",
            identifier: "Stacio.Editor.Toolbar.find",
            action: #selector(findPressed(_:)),
            isToggle: false
        )
        let replace = makeToolbarButton(
            symbolName: "arrow.triangle.2.circlepath",
            accessibilityLabel: "查找和替换",
            identifier: "Stacio.Editor.Toolbar.replace",
            action: #selector(replacePressed(_:)),
            isToggle: false
        )
        let backup = makeToolbarButton(
            symbolName: "externaldrive.badge.plus",
            accessibilityLabel: "备份当前编辑文件",
            identifier: "Stacio.Editor.Toolbar.backup",
            action: #selector(backupPressed(_:)),
            isToggle: false
        )
        let restore = makeToolbarButton(
            symbolName: "clock.arrow.circlepath",
            accessibilityLabel: "恢复备份文件",
            identifier: "Stacio.Editor.Toolbar.restore",
            action: #selector(restorePressed(_:)),
            isToggle: false
        )
        let askAI = makeToolbarButton(
            symbolName: "sparkles",
            accessibilityLabel: "发送当前文件给 AI",
            identifier: "Stacio.Editor.Toolbar.askAI",
            action: #selector(askAIPressed(_:)),
            isToggle: false
        )
        let collapse = makeToolbarButton(
            symbolName: "rectangle.compress.vertical",
            accessibilityLabel: "收起编辑器",
            identifier: "Stacio.Editor.Toolbar.collapse",
            action: #selector(collapsePressed(_:)),
            isToggle: false
        )
        let close = makeToolbarButton(
            symbolName: "xmark.circle",
            accessibilityLabel: "关闭编辑器",
            identifier: "Stacio.Editor.Toolbar.close",
            action: #selector(closePressed(_:)),
            isToggle: false
        )
        lineNumbersButton = lineNumbers
        wordWrapButton = wordWrap
        minimapButton = minimap
        collapseButton = collapse

        stack.addArrangedSubview(close)
        [lineNumbers, wordWrap, minimap].forEach(stack.addArrangedSubview)

        let dragHandle = RemoteEditorToolbarDragHandleView(
            frame: NSRect(x: 0, y: 0, width: 48, height: 24)
        )
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.toolTip = L10n.EditorPresentation.toolbarDrag
        dragHandle.setAccessibilityLabel(L10n.EditorPresentation.toolbarDrag)
        dragHandle.setAccessibilityIdentifier("Stacio.Editor.Toolbar.dragHandle")
        dragHandle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dragHandle.onDrag = { [weak self] event in self?.onDragDetachRequested?(event) }
        toolbarDragHandle = dragHandle
        stack.addArrangedSubview(dragHandle)
        NSLayoutConstraint.activate([
            dragHandle.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            dragHandle.heightAnchor.constraint(equalToConstant: 24)
        ])
        [find, replace, backup, restore, askAI, collapse].forEach(stack.addArrangedSubview)

        let presentation = NSSegmentedControl(
            frame: NSRect(x: 0, y: 0, width: 58, height: 24)
        )
        presentation.segmentCount = 2
        presentation.trackingMode = .momentary
        presentation.segmentStyle = .texturedRounded
        presentation.setWidth(30, forSegment: 0)
        presentation.setWidth(22, forSegment: 1)
        presentation.translatesAutoresizingMaskIntoConstraints = false
        presentation.target = self
        presentation.action = #selector(presentationControlPressed(_:))
        presentation.setAccessibilityIdentifier("Stacio.Editor.Toolbar.presentation")
        presentation.setImage(NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil), forSegment: 0)
        presentation.setImage(
            NSImage(systemSymbolName: presentationDisplayImageNameForTesting, accessibilityDescription: nil),
            forSegment: 1
        )
        presentation.toolTip = L10n.EditorPresentation.detach
        presentation.setAccessibilityLabel(L10n.EditorPresentation.detach)
        presentationControl = presentation
        stack.addArrangedSubview(presentation)
        NSLayoutConstraint.activate([
            presentation.widthAnchor.constraint(equalToConstant: 58),
            presentation.heightAnchor.constraint(equalToConstant: 24)
        ])

        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)
        ])
        updateToolbarButtonStates()
        updatePresentationControls(presentationControlsSnapshot)
        return toolbar
    }

    @objc private func presentationControlPressed(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 {
            onPresentationMenuRequested?(sender)
        } else {
            onTogglePresentationRequested?()
        }
    }

    private func makeToolbarButton(
        symbolName: String,
        accessibilityLabel: String,
        identifier: String,
        action: Selector,
        isToggle: Bool
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let button = NSButton(image: image, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.imagePosition = .imageOnly
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(identifier)
        if isToggle {
            button.setButtonType(.toggle)
        }
        StacioDesignSystem.styleToolbarButton(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return button
    }

    private func updateToolbarButtonStates() {
        updateToolbarToggleButton(lineNumbersButton, isOn: editorDisplayOptions.lineNumbersEnabled)
        updateToolbarToggleButton(wordWrapButton, isOn: editorDisplayOptions.wordWrapEnabled)
        updateToolbarToggleButton(minimapButton, isOn: editorDisplayOptions.minimapEnabled)
    }

    private func updateToolbarToggleButton(_ button: NSButton?, isOn: Bool) {
        guard let button else { return }
        button.state = isOn ? .on : .off
        StacioDesignSystem.setLayerBackgroundColor(
            button,
            color: isOn ? StacioDesignSystem.theme.controlHoverColor : .clear
        )
        button.contentTintColor = isOn
            ? StacioDesignSystem.theme.accentColor
            : StacioDesignSystem.theme.secondaryTextColor
    }

    @objc private func toggleLineNumbersPressed(_ sender: NSButton) {
        updateDisplayOptions { $0.lineNumbersEnabled.toggle() }
    }

    @objc private func toggleWordWrapPressed(_ sender: NSButton) {
        updateDisplayOptions { $0.wordWrapEnabled.toggle() }
    }

    @objc private func toggleMinimapPressed(_ sender: NSButton) {
        updateDisplayOptions { $0.minimapEnabled.toggle() }
    }

    @objc private func findPressed(_ sender: NSButton) {
        runEditorAction("actions.find")
    }

    @objc private func replacePressed(_ sender: NSButton) {
        runEditorAction("editor.action.startFindReplaceAction")
    }

    @objc private func backupPressed(_ sender: NSButton) {
        onBackupRequested?()
    }

    @objc private func restorePressed(_ sender: NSButton) {
        onRestoreRequested?()
    }

    @objc private func askAIPressed(_ sender: NSButton) {
        requestAIForActiveDocument()
    }

    @objc private func collapsePressed(_ sender: NSButton) {
        onToggleCollapseRequested?()
    }

    @objc private func closePressed(_ sender: NSButton) {
        if let onCloseRequested {
            onCloseRequested()
        } else {
            onStandaloneWindowCloseRequested?()
        }
    }

    private func updateDisplayOptions(_ update: (inout RemoteTextEditorDisplayOptions) -> Void) {
        update(&editorDisplayOptions)
        editorDisplayOptions.save(defaults: editorOptionsDefaults)
        updateToolbarButtonStates()
        applyDisplayOptionsToEditor()
    }

    private func applyDisplayOptionsToEditor() {
        callEditorFunction("applyDisplayOptions", payload: editorDisplayOptions)
    }

    private func requestSaveActiveDocument() {
        if isEditorReady {
            callEditorFunction("saveActiveDocument", payload: EmptyEditorPayload())
            return
        }
        do {
            try performSave()
        } catch {
            presentSaveError(error, parentWindow: view.window)
        }
    }

    private func runEditorAction(_ actionID: String) {
        callEditorFunction("runEditorAction", payload: EditorActionPayload(actionID: actionID))
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return false
        }
        switch key {
        case "s":
            requestSaveActiveDocument()
            return true
        case "f":
            runEditorAction("actions.find")
            return true
        case "h":
            runEditorAction("editor.action.startFindReplaceAction")
            return true
        default:
            return false
        }
    }

    private func observeSettingsChanges() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettingsStore.didChangeNotification,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            self?.applyCurrentTheme()
        }
    }

    private func observeWindowLiveResizeEnd() {
        guard liveResizeEndObserver == nil else { return }
        liveResizeEndObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let resizedWindow = notification.object as? NSWindow,
                  self.isViewLoaded,
                  self.view.window === resizedWindow
            else { return }
            self.editorLiveResizeDidEnd()
        }
    }

    private func applyCurrentTheme() {
        let appearance = isViewLoaded ? view.effectiveAppearance : NSApp.effectiveAppearance
        let settings = settingsStore.snapshot()
        currentThemeIdentifier = RemoteTextEditorTheme.monacoIdentifier(
            settings: settings,
            appearance: appearance
        )
        view.layer?.backgroundColor = (currentThemeIdentifier == "vs-dark"
            ? NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.078, alpha: 1)
            : NSColor.textBackgroundColor
        ).cgColor
        editorLoadingOverlay.layer?.backgroundColor = view.layer?.backgroundColor
        editorLoadingStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        if isEditorReady == false {
            webView?.layer?.backgroundColor = view.layer?.backgroundColor
        }
        callEditorFunction("setTheme", payload: ThemePayload(settings: settings, theme: currentThemeIdentifier))
    }

    private func loadMonacoEditorHTML(resetReadinessRecoveryBudget: Bool = false) {
        cancelTabDragTracking()
        resetEditorPointerInteractionState()
        cancelAllSavedCloseHandshakes()
        cancelMonacoReadinessWatchdog()
        if resetReadinessRecoveryBudget {
            monacoReadinessRecoveryReloadCount = 0
        }
        monacoPageLoadGeneration += 1
        monacoPageLoadCountForTestingStorage += 1
        isMonacoRuntimeReady = false
        isEditorReady = false
        lastRequestedEditorLayoutSize = .zero
        forcePendingEditorLayoutRequest = false
        updateWebViewVisibilityForEditorReadiness()
        showMonacoLoading()
        let baseURL = MonacoEditorResourceLocator.monacoBaseURL()
        monacoNavigation = webView?.loadHTMLString(
            Self.editorHTML(pageLoadGeneration: monacoPageLoadGeneration),
            baseURL: baseURL
        )
        scheduleMonacoReadinessWatchdog()
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView,
              navigation == nil || navigation === monacoNavigation
        else { return }
        scheduleMonacoReadinessWatchdog()
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleMonacoNavigationFailure(webView: webView, navigation: navigation, error: error)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleMonacoNavigationFailure(webView: webView, navigation: navigation, error: error)
    }

    private func handleMonacoNavigationFailure(
        webView: WKWebView,
        navigation: WKNavigation?,
        error: Error
    ) {
        guard webView === self.webView,
              navigation == nil || navigation === monacoNavigation
        else { return }
        let navigationError = error as NSError
        guard navigationError.domain != NSURLErrorDomain
                || navigationError.code != NSURLErrorCancelled
        else { return }
        cancelAllSavedCloseHandshakes()
        cancelMonacoReadinessWatchdog()
        scheduleMonacoReadinessRecovery()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        cancelAllSavedCloseHandshakes()
        cancelMonacoReadinessWatchdog()
        isMonacoRuntimeReady = false
        isEditorReady = false
        updateWebViewVisibilityForEditorReadiness()
        showMonacoLoading()
        recoverMonacoReadinessIfNeeded()
    }

    private func presentSaveError(_ error: Error, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Files.saveRemoteEditFailedTitle
        alert.informativeText = RuntimeDiagnosticFormatter.userMessage(for: error)
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }

    fileprivate func handleScriptMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let name = body["name"] as? String,
              let messagePageLoadGeneration = (body["pageLoadGeneration"] as? NSNumber)?.intValue,
              messagePageLoadGeneration == monacoPageLoadGeneration
        else {
            return
        }
        let payload = body["payload"] as? [String: Any]
        switch name {
        case "tabDragCandidate":
            guard let x = payload?["x"] as? NSNumber,
                  let y = payload?["y"] as? NSNumber,
                  let pointerID = payload?["pointerID"] as? NSNumber,
                  let eventButtons = payload?["buttons"] as? NSNumber
            else { return }
            let clientPoint = NSPoint(x: x.doubleValue, y: y.doubleValue)
            let pointInWindow: NSPoint
            if let webView {
                pointInWindow = webView.convert(
                    NSPoint(x: clientPoint.x, y: webView.bounds.height - clientPoint.y),
                    to: nil
                )
            } else {
                pointInWindow = clientPoint
            }
            beginTabDragCandidate(
                pageLoadGeneration: messagePageLoadGeneration,
                pointInWindow: pointInWindow,
                pointerID: pointerID.intValue,
                eventButtons: eventButtons.intValue,
                pressedMouseButtons: NSEvent.pressedMouseButtons
            )
        case "tabDragCancelled":
            if let pointerID = payload?["pointerID"] as? NSNumber,
               pointerID.intValue != tabDragPointerID
            {
                return
            }
            cancelTabDragTracking()
        case "ready":
            guard isMonacoRuntimeReady == false else { return }
            isMonacoRuntimeReady = true
            monacoInitializationWasInterruptedByLiveResize = false
            scheduleMonacoReadinessWatchdog()
            syncWorkspaceToWebView()
        case "workspaceReady":
            guard isMonacoRuntimeReady,
                  payload?["activeDocumentID"] as? String == activeDocumentID,
                  (payload?["documentCount"] as? NSNumber)?.intValue == documents.count
            else { return }
            isEditorReady = true
            monacoReadinessRecoveryReloadCount = 0
            cancelMonacoReadinessWatchdog()
            updateWebViewVisibilityForEditorReadiness()
            hideMonacoLoading()
            scheduleEditorLayoutIfNeeded(force: true)
        case "changed":
            guard let id = payload?["id"] as? String,
                  let content = payload?["content"] as? String
            else { return }
            updateDocumentText(
                id: id,
                text: content,
                revision: (payload?["revision"] as? NSNumber)?.intValue
            )
        case "save":
            var saveTargetID = activeDocumentID
            if let id = payload?["id"] as? String,
               let content = payload?["content"] as? String
            {
                saveTargetID = id
                updateDocumentText(
                    id: id,
                    text: content,
                    revision: (payload?["revision"] as? NSNumber)?.intValue
                )
            }
            do {
                try saveDocument(id: saveTargetID)
            } catch {
                presentSaveError(error, parentWindow: view.window)
            }
        case "cursor":
            cursorLine = payload?["line"] as? Int ?? cursorLine
            cursorColumn = payload?["column"] as? Int ?? cursorColumn
        case "languageChanged":
            guard let id = payload?["id"] as? String,
                  let languageIdentifier = payload?["languageIdentifier"] as? String
            else { return }
            updateDocumentLanguage(id: id, languageIdentifier: languageIdentifier)
        case "switchTab":
            guard let targetID = payload?["targetID"] as? String else { return }
            handleSwitchTabRequest(
                targetID: targetID,
                currentID: payload?["currentID"] as? String,
                content: payload?["content"] as? String,
                revision: (payload?["revision"] as? NSNumber)?.intValue
            )
        case "closeTab":
            if let currentID = payload?["currentID"] as? String,
               let content = payload?["content"] as? String
            {
                updateDocumentText(
                    id: currentID,
                    text: content,
                    revision: (payload?["revision"] as? NSNumber)?.intValue
                )
            }
            guard let targetID = payload?["targetID"] as? String else { return }
            closeDocument(id: targetID)
        case "closeHandshake":
            handleSavedCloseHandshake(payload)
        default:
            break
        }
    }

    private func updateDocumentText(
        id: String,
        text: String,
        revision: Int? = nil,
        syncTabs: Bool = true
    ) {
        guard let index = documents.firstIndex(where: { $0.id == id }),
              documents[index].canEdit
        else {
            return
        }
        if let revision, revision < documents[index].revision {
            return
        }
        let textChanged = documents[index].text != text
        let revisionAdvanced = revision.map { $0 > documents[index].revision } ?? textChanged
        if textChanged || revisionAdvanced {
            pendingTabCloseDocumentIDs.remove(id)
            pendingSavedCloseHandshakes.removeValue(forKey: id)
            cancelSavedCloseHandshakeTimeout(documentID: id)
            cancelPendingWindowClose()
        }
        documents[index].text = text
        if let revision {
            documents[index].revision = revision
        } else if textChanged {
            documents[index].revision += 1
        }
        if documents[index].saveState != .saving {
            documents[index].saveState = documents[index].isDirty ? .dirty : .saved
        }
        documents[index].saveFailureMessage = nil
        markDirtyIfNeeded()
        if syncTabs {
            syncTabStateToWebView()
        }
    }

    private func updateDocumentLanguage(id: String, languageIdentifier: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else {
            return
        }
        let trimmedLanguage = languageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_+"))
        let normalizedLanguage = trimmedLanguage.isEmpty
            || trimmedLanguage.rangeOfCharacter(from: allowedCharacters.inverted) != nil
            ? "plaintext"
            : trimmedLanguage
        documents[index].languageIdentifier = normalizedLanguage
    }

    private func handleSwitchTabRequest(
        targetID: String,
        currentID: String?,
        content: String?,
        revision: Int? = nil
    ) {
        guard documents.contains(where: { $0.id == targetID }) else {
            return
        }
        if let currentID, let content {
            updateDocumentText(id: currentID, text: content, revision: revision, syncTabs: false)
        }
        activateDocument(id: targetID)
    }

    private func activateDocument(id: String) {
        guard documents.contains(where: { $0.id == id }) else {
            return
        }
        activeDocumentID = id
        markDirtyIfNeeded()
        syncActiveDocumentToWebView()
    }

    private func closeDocument(
        id: String,
        closeConfirmer: RemoteTextEditorCloseConfirming? = nil
    ) {
        guard documents.count > 1,
              let index = documents.firstIndex(where: { $0.id == id })
        else {
            if let onCloseRequested {
                onCloseRequested()
            } else {
                onStandaloneWindowCloseRequested?()
            }
            return
        }
        guard pendingTabCloseDocumentIDs.contains(id) == false else {
            return
        }
        if documents[index].isDirty {
            let confirmer = closeConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
            switch confirmer.confirmClose(fileName: documents[index].fileName, parentWindow: view.window) {
            case .save:
                let waitsForAsyncSave = documents[index].onSaveTextAsync != nil
                if waitsForAsyncSave {
                    pendingTabCloseDocumentIDs.insert(id)
                }
                do {
                    try saveDocument(id: id)
                } catch {
                    pendingTabCloseDocumentIDs.remove(id)
                    presentSaveError(error, parentWindow: view.window)
                    return
                }
                if waitsForAsyncSave {
                    return
                }
            case .discard:
                break
            case .cancel:
                syncWorkspaceToWebView()
                return
            }
        }
        removeDocument(id: id)
    }

    private func removeDocument(id: String) {
        guard documents.count > 1,
              let index = documents.firstIndex(where: { $0.id == id })
        else { return }
        pendingTabCloseDocumentIDs.remove(id)
        pendingWindowCloseDocumentIDs.remove(id)
        let wasActive = id == activeDocumentID
        Self.unregisterRemotePreviewSource(documents[index].previewSource)
        documents.remove(at: index)
        if wasActive {
            let nextIndex = min(index, documents.count - 1)
            activeDocumentID = documents[nextIndex].id
        }
        markDirtyIfNeeded()
        syncWorkspaceToWebView()
    }

    private static func unregisterRemotePreviewSource(_ source: String?) {
        guard let source,
              let url = URL(string: source),
              url.scheme == RemoteFileOnlineMediaRegistry.scheme
                || (url.scheme == "http" && url.host == "127.0.0.1")
        else { return }
        RemoteFileOnlineMediaRegistry.shared.unregister(url: url)
    }

    private func saveDocument(id: String) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard documents[index].canEdit else {
            throw RemoteTextEditorError.nonUTF8Text(documents[index].fileName)
        }
        guard documents[index].saveState != .saving else { return }
        let text = documents[index].text
        let revision = documents[index].revision
        let saveRequestID = UUID()
        documents[index].saveRequestID = saveRequestID
        documents[index].saveState = .saving
        documents[index].saveFailureMessage = nil
        markDirtyIfNeeded()
        syncTabStateToWebView()
        if let asyncSave = documents[index].onSaveTextAsync {
            asyncSave(text) { [weak self] result in
                self?.finishAsyncSave(
                    documentID: id,
                    requestID: saveRequestID,
                    savedText: text,
                    savedRevision: revision,
                    result: result
                )
            }
            return
        }
        do {
            try documents[index].onSaveText?(text)
        } catch {
            documents[index].saveState = .failed
            documents[index].saveFailureMessage = RuntimeDiagnosticFormatter.userMessage(for: error)
            documents[index].saveRequestID = nil
            markDirtyIfNeeded()
            syncTabStateToWebView()
            throw error
        }
        documents[index].originalText = text
        documents[index].saveState = .saved
        documents[index].saveFailureMessage = nil
        documents[index].saveRequestID = nil
        markDirtyIfNeeded()
        syncTabStateToWebView()
    }

    private func finishAsyncSave(
        documentID: String,
        requestID: UUID,
        savedText: String,
        savedRevision: Int,
        result: Result<Void, Error>
    ) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }),
              documents[index].saveRequestID == requestID
        else { return }
        documents[index].saveRequestID = nil
        let wasPendingTabClose = pendingTabCloseDocumentIDs.contains(documentID)
        let wasPendingWindowClose = hasPendingWindowClose
            && pendingWindowCloseDocumentIDs.contains(documentID)
        switch result {
        case .success:
            documents[index].originalText = savedText
            documents[index].saveState = documents[index].isDirty ? .dirty : .saved
            documents[index].saveFailureMessage = nil
            if documents[index].isDirty {
                pendingTabCloseDocumentIDs.remove(documentID)
                cancelPendingWindowClose()
            } else if wasPendingTabClose || wasPendingWindowClose {
                beginSavedCloseHandshake(
                    documentID: documentID,
                    savedText: savedText,
                    savedRevision: savedRevision
                )
            }
        case .failure(let error):
            pendingTabCloseDocumentIDs.remove(documentID)
            pendingSavedCloseHandshakes.removeValue(forKey: documentID)
            cancelSavedCloseHandshakeTimeout(documentID: documentID)
            documents[index].saveState = .failed
            documents[index].saveFailureMessage = RuntimeDiagnosticFormatter.userMessage(for: error)
            cancelPendingWindowClose()
        }
        markDirtyIfNeeded()
        syncTabStateToWebView()
    }

    private func beginSavedCloseHandshake(
        documentID: String,
        savedText: String,
        savedRevision: Int
    ) {
        guard isEditorReady, isViewLoaded, webView != nil else {
            finishSavedClose(documentID: documentID)
            return
        }
        let requestID = UUID().uuidString
        pendingSavedCloseHandshakes[documentID] = PendingSavedCloseHandshake(
            requestID: requestID,
            savedText: savedText,
            savedRevision: savedRevision
        )
        scheduleSavedCloseHandshakeTimeout(documentID: documentID, requestID: requestID)
        callEditorFunction(
            "confirmSavedContentBeforeClose",
            payload: EditorCloseHandshakeRequestPayload(
                documentID: documentID,
                requestID: requestID
            ),
            requiresFunction: true
        ) { [weak self] error in
            guard error != nil else { return }
            self?.cancelSavedCloseHandshake(documentID: documentID, requestID: requestID)
        }
    }

    private func handleSavedCloseHandshake(_ payload: [String: Any]?) {
        guard let documentID = payload?["id"] as? String,
              let requestID = payload?["requestID"] as? String,
              let content = payload?["content"] as? String,
              let revision = (payload?["revision"] as? NSNumber)?.intValue,
              let pending = pendingSavedCloseHandshakes[documentID],
              pending.requestID == requestID,
              let index = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        pendingSavedCloseHandshakes.removeValue(forKey: documentID)
        cancelSavedCloseHandshakeTimeout(documentID: documentID)

        guard content == pending.savedText,
              revision == pending.savedRevision,
              documents[index].text == pending.savedText,
              documents[index].revision == pending.savedRevision
        else {
            pendingTabCloseDocumentIDs.remove(documentID)
            documents[index].text = content
            documents[index].revision = max(documents[index].revision, revision)
            documents[index].saveState = documents[index].isDirty ? .dirty : .saved
            documents[index].saveFailureMessage = nil
            cancelPendingWindowClose()
            markDirtyIfNeeded()
            syncTabStateToWebView()
            return
        }
        finishSavedClose(documentID: documentID)
    }

    private func finishSavedClose(documentID: String) {
        cancelSavedCloseHandshakeTimeout(documentID: documentID)
        let shouldRemoveTab = pendingTabCloseDocumentIDs.remove(documentID) != nil
        if hasPendingWindowClose, pendingWindowCloseDocumentIDs.contains(documentID) {
            pendingWindowCloseDocumentIDs.remove(documentID)
        }
        if shouldRemoveTab {
            removeDocument(id: documentID)
        }
        if hasPendingWindowClose,
           pendingWindowCloseDocumentIDs.isEmpty,
           isEvaluatingWindowClose == false
        {
            hasPendingWindowClose = false
            resolvePendingClose(.ready)
            onWindowCloseReady?()
        }
    }

    private func cancelPendingWindowClose() {
        let shouldResolve = hasPendingWindowClose && pendingCloseResolutionExpected
        hasPendingWindowClose = false
        pendingWindowCloseDocumentIDs.removeAll()
        for documentID in pendingSavedCloseHandshakes.keys
            where pendingTabCloseDocumentIDs.contains(documentID) == false
        {
            cancelSavedCloseHandshakeTimeout(documentID: documentID)
        }
        pendingSavedCloseHandshakes = pendingSavedCloseHandshakes.filter {
            pendingTabCloseDocumentIDs.contains($0.key)
        }
        if shouldResolve {
            resolvePendingClose(.cancelled)
        }
    }

    private func resolvePendingClose(_ resolution: RemoteTextEditorCloseResolution) {
        guard pendingCloseResolutionExpected else { return }
        pendingCloseResolutionExpected = false
        onPendingCloseResolved?(resolution)
        onStandaloneWindowCloseResolved?(resolution)
    }

    private func scheduleSavedCloseHandshakeTimeout(documentID: String, requestID: String) {
        cancelSavedCloseHandshakeTimeout(documentID: documentID)
        let timeout = DispatchWorkItem { [weak self] in
            self?.cancelSavedCloseHandshake(documentID: documentID, requestID: requestID)
        }
        savedCloseHandshakeTimeouts[documentID] = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.savedCloseHandshakeTimeout,
            execute: timeout
        )
    }

    private func cancelSavedCloseHandshakeTimeout(documentID: String) {
        savedCloseHandshakeTimeouts.removeValue(forKey: documentID)?.cancel()
    }

    private func cancelSavedCloseHandshake(documentID: String, requestID: String) {
        guard pendingSavedCloseHandshakes[documentID]?.requestID == requestID else { return }
        pendingSavedCloseHandshakes.removeValue(forKey: documentID)
        cancelSavedCloseHandshakeTimeout(documentID: documentID)
        pendingTabCloseDocumentIDs.remove(documentID)
        if hasPendingWindowClose, pendingWindowCloseDocumentIDs.contains(documentID) {
            cancelPendingWindowClose()
        }
    }

    private func cancelAllSavedCloseHandshakes() {
        guard pendingSavedCloseHandshakes.isEmpty == false else { return }
        let documentIDs = Set(pendingSavedCloseHandshakes.keys)
        pendingSavedCloseHandshakes.removeAll()
        for documentID in documentIDs {
            cancelSavedCloseHandshakeTimeout(documentID: documentID)
            pendingTabCloseDocumentIDs.remove(documentID)
        }
        if hasPendingWindowClose {
            cancelPendingWindowClose()
        }
    }

    private func aiRequestForActiveDocument() -> RemoteTextEditorAIRequest? {
        guard let document = activeDocument,
              document.displayMode == .text,
              document.canEdit,
              document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }

        let attachmentText = Self.aiAttachmentText(document.text)
        let attachment = AIAssistantAttachment(
            filename: document.fileName,
            mimeType: Self.aiAttachmentMimeType(forFileName: document.fileName),
            byteCount: document.text.lengthOfBytes(using: .utf8),
            textPreview: attachmentText
        )
        let question = "请阅读附件“\(document.fileName)”，解释并排查这个文件，指出潜在风险、配置问题和可改进点。先给结论，再列建议；不要直接生成会修改文件的命令，除非我明确要求。"
        return RemoteTextEditorAIRequest(question: question, attachment: attachment)
    }

    private static func aiAttachmentText(_ text: String) -> String {
        guard text.count > aiDocumentAttachmentTextLimit else {
            return text
        }
        return String(text.prefix(aiDocumentAttachmentTextLimit))
            + "\n\n[附件内容已截断，仅包含前 \(aiDocumentAttachmentTextLimit) 个字符]"
    }

    private static func aiAttachmentMimeType(forFileName fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "md", "markdown":
            return "text/markdown"
        case "json":
            return "application/json"
        case "csv":
            return "text/csv"
        case "xml":
            return "application/xml"
        case "html", "htm":
            return "text/html"
        case "yaml", "yml":
            return "application/yaml"
        case "swift":
            return "text/x-swift"
        case "sh", "bash", "zsh":
            return "text/x-shellscript"
        case "py":
            return "text/x-python"
        case "js":
            return "text/javascript"
        case "ts":
            return "text/typescript"
        case "css":
            return "text/css"
        default:
            return "text/plain"
        }
    }

    private func markDirtyIfNeeded() {
        guard let activeDocument else { return }
        onDirtyStateChanged?(hasUnsavedChanges)
        onActiveDocumentChanged?(activeDocument.fileName, hasUnsavedChanges)
        onWindowPresentationChanged?(activeDocument.fileName, hasUnsavedChanges)
        onStandaloneWindowPresentationChanged?(activeDocument.fileName, hasUnsavedChanges)
    }

    private func syncWorkspaceToWebView() {
        guard isMonacoRuntimeReady else { return }
        let pageLoadGeneration = monacoPageLoadGeneration
        callEditorFunction(
            "loadWorkspace",
            payload: EditorWorkspacePayload(
                documents: documents.map(EditorDocumentPayload.init(document:)),
                activeDocumentID: activeDocumentID,
                displayOptions: editorDisplayOptions,
                theme: ThemePayload(settings: settingsStore.snapshot(), theme: currentThemeIdentifier)
            )
        ) { [weak self] error in
            guard let self,
                  self.monacoPageLoadGeneration == pageLoadGeneration,
                  self.isEditorReady == false,
                  error != nil
            else { return }
            self.cancelMonacoReadinessWatchdog()
            self.scheduleMonacoReadinessRecovery()
        }
    }

    private func syncActiveDocumentToWebView() {
        guard isEditorReady, let activeDocument else { return }
        callEditorFunction("activateDocument", payload: EditorDocumentPayload(document: activeDocument))
    }

    private func syncTabStateToWebView() {
        guard isEditorReady else { return }
        callEditorFunction(
            "updateTabs",
            payload: EditorTabsPayload(
                documents: documents.map(EditorDocumentPayload.init(document:)),
                activeDocumentID: activeDocumentID
            )
        )
    }

    private func callEditorFunction<Payload: Encodable>(
        _ functionName: String,
        payload: Payload,
        requiresFunction: Bool = false,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard isViewLoaded, let webView else {
            completion?(RemoteTextEditorJavaScriptError.bridgeUnavailable)
            return
        }
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else {
            completion?(RemoteTextEditorJavaScriptError.invalidPayload)
            return
        }
        editorFunctionCallsForTestingStorage.append(functionName)
        let script: String
        if requiresFunction {
            script = """
            (() => {
              const editor = window.StacioEditor;
              if (!editor || typeof editor.\(functionName) !== 'function') {
                throw new Error('StacioEditor.\(functionName) is unavailable');
              }
              return editor.\(functionName)(\(json));
            })();
            """
        } else {
            script = "window.StacioEditor && window.StacioEditor.\(functionName)(\(json));"
        }
        editorFunctionScriptsForTestingStorage.append(script)
        if let completion {
            webView.evaluateJavaScript(script) { _, error in
                completion(error)
            }
        } else {
            webView.evaluateJavaScript(script)
        }
    }

    private func document(id: String) -> RemoteTextEditorDocument? {
        documents.first { $0.id == id }
    }

    private var activeDocument: RemoteTextEditorDocument? {
        documents.first { $0.id == activeDocumentID }
    }

    private func lineCount(for text: String) -> Int {
        guard text.isEmpty == false else { return 1 }
        let components = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") {
            return max(1, components.count - 1)
        }
        return max(1, components.count)
    }

    private static let editorPageLoadGenerationPlaceholder = "__STACIO_MONACO_PAGE_LOAD_GENERATION__"

    private static func editorHTML(pageLoadGeneration: Int) -> String {
        editorHTMLTemplate.replacingOccurrences(
            of: editorPageLoadGenerationPlaceholder,
            with: String(pageLoadGeneration)
        )
    }

    private static let editorHTMLTemplate = #"""
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'self' file: blob: data: stacio-remote-media: 'unsafe-inline' 'unsafe-eval'; worker-src blob: file:; img-src 'self' file: data: blob: stacio-remote-media:; media-src 'self' file: data: blob: stacio-remote-media:;">
  <link rel="preload" href="vs/nls.messages.zh-cn.js" as="script">
  <style>
    html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #0e1014; color: #d7dde8; }
    body.light { background: #ffffff; color: #1d1d1f; }
    #shell { display: grid; grid-template-rows: 32px minmax(0, 1fr) 24px; width: 100%; height: 100%; min-width: 0; }
    #tab-strip { display: grid; grid-template-columns: 28px minmax(0, 1fr) 28px; min-width: 0; border-bottom: 1px solid rgba(128,128,128,.24); background: rgba(0,0,0,.18); }
    body.light #tab-strip { background: #f3f4f6; }
    #tabs { display: flex; align-items: stretch; gap: 1px; min-width: 0; overflow-x: auto; overflow-y: hidden; scrollbar-width: none; }
    #tabs::-webkit-scrollbar { display: none; }
    .tab-scroll { border: 0; border-right: 1px solid rgba(128,128,128,.18); background: transparent; color: inherit; font-size: 15px; padding: 0; opacity: .72; }
    .tab-scroll:last-child { border-left: 1px solid rgba(128,128,128,.18); border-right: 0; }
    .tab-scroll:hover:not(:disabled) { background: rgba(128,128,128,.18); opacity: 1; }
    .tab-scroll:disabled { opacity: .22; }
    .tab { display: inline-flex; align-items: center; gap: 7px; min-width: 104px; max-width: 220px; padding: 0 12px 0 5px; border: 0; border-right: 1px solid rgba(128,128,128,.2); border-radius: 8px 8px 0 0; background: transparent; color: inherit; font-size: 12px; text-align: left; cursor: default; flex: 0 0 auto; }
    body.light .tab { color: #4b5563; }
    .tab.active { background: rgba(255,255,255,.08); color: #d7dde8; }
    body.light .tab.active { background: #ffffff; color: #111827; }
    .tab-title { flex: 1; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
    .dirty { width: 7px; height: 7px; border-radius: 50%; background: #ffb020; opacity: 0; flex: 0 0 auto; }
    .tab.dirty .dirty { opacity: 1; }
    .close { position: relative; width: 16px; height: 16px; border: 0; border-radius: 999px; background: currentColor; color: inherit; line-height: 16px; padding: 0; opacity: .65; flex: 0 0 16px; }
    .close::before, .close::after { content: ""; position: absolute; left: 4px; right: 4px; top: 7px; height: 2px; border-radius: 1px; background: #0e1014; }
    .close::before { transform: rotate(45deg); }
    .close::after { transform: rotate(-45deg); }
    body.light .close::before, body.light .close::after { background: #ffffff; }
    .close:hover { opacity: 1; }
    #editor-wrap { position: relative; min-width: 0; min-height: 0; }
    #editor { position: absolute; inset: 0; }
    #error { display: none; position: absolute; inset: 0; align-items: center; justify-content: center; text-align: center; padding: 32px; box-sizing: border-box; color: #c74b4b; background: inherit; font-size: 13px; line-height: 1.6; }
    #preview { display: none; position: absolute; inset: 0; min-width: 0; min-height: 0; background: #111318; color: #f3f5f8; }
    body.light #preview { background: #ffffff; color: #1d1d1f; }
    .preview-shell { width: 100%; height: 100%; display: grid; grid-template-rows: 38px minmax(0, 1fr); }
    .preview-toolbar { display: flex; align-items: center; justify-content: center; gap: 8px; border-bottom: 1px solid rgba(128,128,128,.24); background: rgba(0,0,0,.2); }
    body.light .preview-toolbar { background: #f7f7f8; }
    .preview-toolbar button { appearance: none; border: 1px solid rgba(128,128,128,.3); border-radius: 6px; background: rgba(128,128,128,.12); color: inherit; height: 26px; min-width: 30px; padding: 0 9px; font: inherit; font-size: 12px; }
    .preview-toolbar button:hover { background: rgba(128,128,128,.2); }
    .preview-stage { min-width: 0; min-height: 0; display: flex; align-items: center; justify-content: center; overflow: auto; }
    .preview-stage img { max-width: min(100%, 1600px); max-height: 100%; object-fit: contain; transform-origin: center center; cursor: zoom-in; }
    .preview-stage img.original { max-width: none; max-height: none; cursor: zoom-out; }
    .preview-stage audio { width: min(720px, calc(100% - 48px)); }
    .preview-stage video { width: min(1100px, calc(100% - 48px)); max-height: calc(100% - 48px); background: #000; }
    .preview-info { display: grid; gap: 10px; text-align: center; color: #aab2c2; font-size: 13px; padding: 32px; }
    body.light .preview-info { color: #6b7280; }
    .preview-name { color: currentColor; font-size: 16px; font-weight: 600; }
    #status { display: flex; align-items: center; justify-content: flex-end; gap: 14px; padding: 0 10px; box-sizing: border-box; border-top: 1px solid rgba(128,128,128,.2); color: #8d96a8; font-size: 11px; background: rgba(0,0,0,.16); }
    body.light #status { background: #f7f7f8; color: #6b7280; }
    #save-state.error { color: #e25555; }
    body.light #save-state.error { color: #b3261e; }
    #language { min-width: 92px; max-width: 150px; height: 19px; border: 0; border-radius: 5px; background: rgba(128,128,128,.14); color: inherit; font: inherit; padding: 0 18px 0 7px; }
    #language:disabled { opacity: .52; }
  </style>
</head>
<body>
  <div id="shell">
    <div id="tab-strip">
      <button id="tab-scroll-left" class="tab-scroll" type="button" aria-label="向左切换标签">‹</button>
      <div id="tabs"></div>
      <button id="tab-scroll-right" class="tab-scroll" type="button" aria-label="向右切换标签">›</button>
    </div>
    <div id="editor-wrap">
      <div id="editor"></div>
      <div id="error"></div>
      <div id="preview"></div>
    </div>
    <div id="status">
      <span id="save-state">已保存</span>
      <span id="cursor">1:1</span>
      <select id="language" aria-label="语言">
        <option value="plaintext">plaintext</option>
      </select>
      <span id="encoding">UTF-8</span>
    </div>
  </div>
  <script>
    window.MonacoEnvironment = Object.assign({}, window.MonacoEnvironment || {}, { Locale: 'zh-cn' });
  </script>
  <script src="vs/loader.js"></script>
  <script>
    const pageLoadGeneration = __STACIO_MONACO_PAGE_LOAD_GENERATION__;
    const post = (name, payload = {}) => {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.stacioEditor) {
        window.webkit.messageHandlers.stacioEditor.postMessage({ pageLoadGeneration, name, payload });
      }
    };

    let editor = null;
    let activeDocumentID = null;
    let documents = [];
    let suppressChange = false;
    let lastHandledTabPointerDownID = null;
    let defaultDisplayOptions = { lineNumbersEnabled: true, wordWrapEnabled: false, minimapEnabled: true };
    let savedStateClearDelay = 2000;
    let findActionID = 'actions.find';
    let replaceActionID = 'editor.action.startFindReplaceAction';
    let editorActionIDs = new Set([findActionID, replaceActionID]);
    let displayOptions = Object.assign({}, defaultDisplayOptions);
    let statusTimers = { saveState: null };
    let pendingEditorLayoutFrame = null;
    let pendingEditorLayoutFallbackTimer = null;
    const editorLayoutFallbackDelay = 200;
    const activeEditorPrimaryPointer = { value: null };

    function escapeHTML(value) {
      return String(value).replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[ch]));
    }

    function availableLanguageIDs() {
      const ids = new Set(['plaintext']);
      if (window.monaco && monaco.languages) {
        monaco.languages.getLanguages().forEach(language => ids.add(language.id));
      }
      return Array.from(ids).sort((lhs, rhs) => {
        if (lhs === 'plaintext') { return -1; }
        if (rhs === 'plaintext') { return 1; }
        return lhs.localeCompare(rhs);
      });
    }

    function performMeasuredEditorLayout() {
      if (!editor) { return; }
      const editorElement = window.document.getElementById('editor');
      const width = editorElement.clientWidth;
      const height = editorElement.clientHeight;
      if (width <= 0 || height <= 0) { return; }
      editor.layout({ width, height });
    }

    function scheduleEditorLayout() {
      if (pendingEditorLayoutFallbackTimer !== null) {
        window.clearTimeout(pendingEditorLayoutFallbackTimer);
      }
      pendingEditorLayoutFallbackTimer = window.setTimeout(() => {
        pendingEditorLayoutFallbackTimer = null;
        if (pendingEditorLayoutFrame !== null) {
          cancelAnimationFrame(pendingEditorLayoutFrame);
          pendingEditorLayoutFrame = null;
        }
        performMeasuredEditorLayout();
      }, editorLayoutFallbackDelay);

      if (pendingEditorLayoutFrame !== null) { return; }
      pendingEditorLayoutFrame = requestAnimationFrame(() => {
        pendingEditorLayoutFrame = null;
        if (pendingEditorLayoutFallbackTimer !== null) {
          window.clearTimeout(pendingEditorLayoutFallbackTimer);
          pendingEditorLayoutFallbackTimer = null;
        }
        performMeasuredEditorLayout();
      });
    }

    function normalizeLanguageIdentifier(languageIdentifier) {
      const candidate = String(languageIdentifier || '').trim();
      if (!candidate) { return 'plaintext'; }
      return availableLanguageIDs().includes(candidate) ? candidate : 'plaintext';
    }

    function populateLanguageOptions() {
      const select = window.document.getElementById('language');
      if (!select) { return; }
      const selected = select.value || 'plaintext';
      const ids = availableLanguageIDs();
      select.innerHTML = ids.map(id => `<option value="${escapeHTML(id)}">${escapeHTML(id)}</option>`).join('');
      select.value = ids.includes(selected) ? selected : 'plaintext';
    }

    function setLanguageSelectValue(languageIdentifier, allowCustom = false) {
      const select = window.document.getElementById('language');
      if (!select) { return; }
      if (!select.options.length) {
        populateLanguageOptions();
      }
      const customLanguage = String(languageIdentifier || '').trim() || 'plaintext';
      const normalizedLanguage = allowCustom ? customLanguage : normalizeLanguageIdentifier(languageIdentifier);
      if (!Array.from(select.options).some(option => option.value === normalizedLanguage)) {
        if (allowCustom) {
          const option = window.document.createElement('option');
          option.value = normalizedLanguage;
          option.textContent = normalizedLanguage;
          select.appendChild(option);
        } else {
          populateLanguageOptions();
        }
      }
      select.value = normalizedLanguage;
    }

    function findLanguage(document) {
      const explicitLanguage = normalizeLanguageIdentifier(document.languageIdentifier);
      if (explicitLanguage !== 'plaintext') {
        return explicitLanguage;
      }
      const lowerName = (document.fileName || '').toLowerCase();
      const extension = lowerName.includes('.') ? '.' + lowerName.split('.').pop() : '';
      if (window.monaco && monaco.languages) {
        const match = monaco.languages.getLanguages().find(language => {
          return (language.filenames || []).some(name => name.toLowerCase() === lowerName)
            || (extension && (language.extensions || []).some(ext => ext.toLowerCase() === extension));
        });
        if (match) {
          return match.id;
        }
      }
      return explicitLanguage;
    }

    function activeDocument() {
      return documents.find(document => document.id === activeDocumentID) || documents[0] || null;
    }

    function setSaveStateDisplay(text, isError) {
      const saveState = window.document.getElementById('save-state');
      if (!saveState) { return; }
      const nextText = text || '';
      const nextKey = `${nextText}|${Boolean(isError)}`;
      if (saveState.dataset.messageKey === nextKey && saveState.textContent === nextText) {
        return;
      }
      if (saveState.dataset.messageKey === nextKey && saveState.textContent === '') {
        return;
      }
      if (statusTimers.saveState) {
        window.clearTimeout(statusTimers.saveState);
        statusTimers.saveState = null;
      }
      saveState.dataset.messageKey = nextKey;
      saveState.textContent = nextText;
      saveState.classList.toggle('error', Boolean(isError));
      if (nextText === '已保存' && !isError) {
        statusTimers.saveState = window.setTimeout(() => {
          if (saveState.dataset.messageKey === nextKey) {
            saveState.textContent = '';
          }
        }, savedStateClearDelay);
      }
    }

    function applyDisplayOptions(options = {}) {
      options = {
        lineNumbersEnabled: options.lineNumbersEnabled !== false,
        wordWrapEnabled: options.wordWrapEnabled === true,
        minimapEnabled: options.minimapEnabled !== false
      };
      Object.assign(displayOptions, options);
      if (!editor) { return; }
      editor.updateOptions({
        lineNumbers: options.lineNumbersEnabled ? 'on' : 'off',
        wordWrap: options.wordWrapEnabled ? 'on' : 'off',
        minimap: { enabled: options.minimapEnabled }
      });
    }

    function runEditorAction(payload) {
      const actionID = typeof payload === 'string' ? payload : payload && payload.actionID;
      if (!editor || !editorActionIDs.has(actionID)) { return; }
      if (actionID === findActionID) {
        editor.getAction('actions.find').run();
        return;
      }
      if (actionID === replaceActionID) {
        editor.getAction('editor.action.startFindReplaceAction').run();
      }
    }

    function saveActiveDocument() {
      const document = activeDocument();
      if (!document || !document.canEdit) { return; }
      post('save', {
        id: activeDocumentID,
        content: editor ? editor.getValue() : document.content,
        revision: Number.isInteger(document.revision) ? document.revision : 0,
        fileName: document.fileName || ''
      });
    }

    function updateStatus() {
      const document = activeDocument();
      const position = editor ? editor.getPosition() : { lineNumber: 1, column: 1 };
      window.document.getElementById('cursor').textContent = `${position.lineNumber}:${position.column}`;
      const mode = document && document.displayMode && document.displayMode !== 'text' ? document.displayMode : null;
      const languageIdentifier = mode || (document ? findLanguage(document) : 'plaintext');
      setLanguageSelectValue(languageIdentifier, Boolean(mode));
      const languageSelect = window.document.getElementById('language');
      if (languageSelect) {
        languageSelect.disabled = Boolean(mode) || !document || !document.canEdit;
      }
      window.document.getElementById('encoding').textContent = document && document.canEdit ? (document.encodingDisplayName || 'UTF-8') : '-';
      setSaveStateDisplay(
        document ? (document.saveStateText || (document.isDirty ? '未保存改动' : '已保存')) : '已保存',
        Boolean(document && document.saveStateIsError)
      );
      post('cursor', { line: position.lineNumber, column: position.column });
    }

    function updateTabs(payloadDocuments = documents, payloadActiveID = activeDocumentID) {
      const existingDocuments = new Map(documents.map(document => [document.id, document]));
      documents = payloadDocuments.map(incoming => {
        const existing = existingDocuments.get(incoming.id);
        const incomingRevision = Number.isInteger(incoming.revision) ? incoming.revision : 0;
        const existingRevision = existing && Number.isInteger(existing.revision) ? existing.revision : 0;
        if (!existing || existingRevision <= incomingRevision) {
          return incoming;
        }
        return {
          ...incoming,
          content: existing.content,
          revision: existingRevision,
          isDirty: existing.isDirty,
          saveStateText: existing.saveStateText,
          saveStateIsError: existing.saveStateIsError
        };
      });
      activeDocumentID = payloadActiveID;
      const tabs = window.document.getElementById('tabs');
      tabs.innerHTML = documents.map(document => {
        const classes = ['tab', document.id === activeDocumentID ? 'active' : '', document.isDirty ? 'dirty' : ''].join(' ');
        return `<button type="button" class="${classes}" data-id="${escapeHTML(document.id)}" title="${escapeHTML(document.path)}">
          <span class="close" data-close="${escapeHTML(document.id)}" aria-label="关闭选项卡"></span><span class="dirty"></span><span class="tab-title">${escapeHTML(document.fileName)}</span>
        </button>`;
      }).join('');
      requestAnimationFrame(() => {
        ensureActiveTabVisible();
        updateTabScrollButtons();
      });
      updateStatus();
    }

    function renderTabState() {
      const tabs = window.document.getElementById('tabs');
      tabs.querySelectorAll('.tab').forEach(tab => {
        const id = tab.getAttribute('data-id');
        const document = documents.find(candidate => candidate.id === id);
        tab.classList.toggle('active', id === activeDocumentID);
        tab.classList.toggle('dirty', Boolean(document && document.isDirty));
      });
      requestAnimationFrame(() => {
        ensureActiveTabVisible();
        updateTabScrollButtons();
      });
    }

    function scrollTabsBy(direction) {
      const tabs = window.document.getElementById('tabs');
      const distance = Math.max(160, Math.floor(tabs.clientWidth * 0.72));
      tabs.scrollBy({ left: distance * direction, behavior: 'smooth' });
      setTimeout(updateTabScrollButtons, 180);
    }

    function ensureActiveTabVisible() {
      const tabs = window.document.getElementById('tabs');
      const active = tabs.querySelector('.tab.active');
      if (active) {
        active.scrollIntoView({ inline: 'nearest', block: 'nearest' });
      }
      updateTabScrollButtons();
    }

    function updateTabScrollButtons() {
      const tabs = window.document.getElementById('tabs');
      const left = window.document.getElementById('tab-scroll-left');
      const right = window.document.getElementById('tab-scroll-right');
      const maxScroll = Math.max(0, tabs.scrollWidth - tabs.clientWidth);
      left.disabled = tabs.scrollLeft <= 1;
      right.disabled = tabs.scrollLeft >= maxScroll - 1;
    }

    function snapshotActiveEditorContent() {
      const document = activeDocument();
      const content = editor ? editor.getValue() : '';
      if (document && document.canEdit) {
        if (content !== document.content) {
          document.revision = (Number.isInteger(document.revision) ? document.revision : 0) + 1;
        }
        document.content = content;
        document.isDirty = document.content !== document.originalContent;
        document.saveStateText = document.isDirty ? '未保存改动' : '已保存';
        document.saveStateIsError = false;
      }
      return {
        id: activeDocumentID,
        content,
        revision: document && Number.isInteger(document.revision) ? document.revision : 0
      };
    }

    function confirmSavedContentBeforeClose(payload) {
      if (!payload || !payload.documentID || !payload.requestID) { return; }
      const document = documents.find(candidate => candidate.id === payload.documentID);
      if (!document) { return; }
      let content = document.content || '';
      if (document.id === activeDocumentID && editor && document.canEdit) {
        const editorContent = editor.getValue();
        if (editorContent !== content) {
          document.revision = (Number.isInteger(document.revision) ? document.revision : 0) + 1;
          document.content = editorContent;
          document.isDirty = document.content !== document.originalContent;
        }
        content = editorContent;
      }
      post('closeHandshake', {
        id: document.id,
        requestID: payload.requestID,
        content,
        revision: Number.isInteger(document.revision) ? document.revision : 0
      });
    }

    function setActiveLanguage(languageIdentifier) {
      const document = activeDocument();
      if (!editor || !window.monaco || !document || (document.displayMode && document.displayMode !== 'text')) {
        updateStatus();
        return;
      }
      const model = editor.getModel();
      if (!model) { return; }
      languageIdentifier = normalizeLanguageIdentifier(languageIdentifier);
      document.languageIdentifier = languageIdentifier;
      monaco.editor.setModelLanguage(model, languageIdentifier);
      updateStatus();
      post('languageChanged', { id: document.id, languageIdentifier });
    }

    function switchToTab(targetID) {
      if (!targetID || targetID === activeDocumentID) { return false; }
      const targetDocument = documents.find(document => document.id === targetID);
      if (!targetDocument) { return false; }
      setEditorDocument(targetDocument, { preserveTabs: true });
      return true;
    }

    function activateTabFromEvent(event) {
      const target = event.target instanceof Element ? event.target : event.target && event.target.parentElement;
      if (!target) { return; }
      const tabs = window.document.getElementById('tabs');
      const excludedControl = target.closest('[data-close], .close, .tab-scroll');
      if (excludedControl) {
        return false;
      }
      const tab = target.closest('.tab');
      if (!tab || !tabs.contains(tab)) { return false; }
      const targetID = tab.getAttribute('data-id');
      const snapshot = snapshotActiveEditorContent();
      if (switchToTab(targetID)) {
        event.preventDefault();
        event.stopPropagation();
        post('switchTab', {
          targetID,
          currentID: snapshot.id,
          content: snapshot.content,
          revision: snapshot.revision
        });
        return true;
      }
      return false;
    }

    function handleTabsPointerDown(event) {
      if (event.button !== 0) { return; }
      if (activateTabFromEvent(event)) {
        lastHandledTabPointerDownID = event.pointerId;
        window.setTimeout(() => {
          if (lastHandledTabPointerDownID === event.pointerId) {
            lastHandledTabPointerDownID = null;
          }
        }, 350);
      }
    }

    function handleTabDragCandidate(event) {
      if (event.button !== 0 || (event.buttons & 1) === 0) { return; }
      if (event.target.closest('.tab-close, .tab-scroll') || event.target.closest('.close')) { return; }
      const tab = event.target.closest('.tab');
      if (!tab) { return; }
      post('tabDragCandidate', {
        x: event.clientX,
        y: event.clientY,
        pointerID: event.pointerId,
        buttons: event.buttons
      });
    }

    function cancelTabDragCandidate(event) {
      const pointerID = event && Number.isInteger(event.pointerId) ? event.pointerId : null;
      post('tabDragCancelled', pointerID === null ? {} : { pointerID });
    }

    function rememberEditorPrimaryPointer(event) {
      const editorElement = window.document.getElementById('editor');
      const target = event.target instanceof Element ? event.target : null;
      if (event.button !== 0 || (event.buttons & 1) === 0 || !target || !editorElement.contains(target)) {
        return;
      }
      activeEditorPrimaryPointer.value = {
        pointerID: event.pointerId,
        pointerType: event.pointerType || 'mouse',
        startedAtEpochMilliseconds: Date.now(),
        target,
        clientX: event.clientX,
        clientY: event.clientY,
        screenX: event.screenX,
        screenY: event.screenY
      };
    }

    function forgetEditorPrimaryPointer(event) {
      const activePointer = activeEditorPrimaryPointer.value;
      if (!activePointer || !event || event.pointerId === activePointer.pointerID) {
        activeEditorPrimaryPointer.value = null;
      }
    }

    function releaseStalePointerInteraction(payload) {
      const activePointer = activeEditorPrimaryPointer.value;
      if (!activePointer) { return false; }
      const notAfterEpochMilliseconds = Number(payload && payload.notAfterEpochMilliseconds);
      if (!Number.isFinite(notAfterEpochMilliseconds)
        || activePointer.startedAtEpochMilliseconds > notAfterEpochMilliseconds) {
        return false;
      }
      activeEditorPrimaryPointer.value = null;
      const requestedClientX = Number(payload && payload.clientX);
      const requestedClientY = Number(payload && payload.clientY);
      const clientX = Number.isFinite(requestedClientX) ? requestedClientX : activePointer.clientX;
      const clientY = Number.isFinite(requestedClientY) ? requestedClientY : activePointer.clientY;
      const fallbackTarget = window.document.elementFromPoint(clientX, clientY)
        || window.document.getElementById('editor');
      const target = activePointer.target && activePointer.target.isConnected
        ? activePointer.target
        : fallbackTarget;
      if (!target) { return false; }

      const pointerOptions = {
        bubbles: true,
        cancelable: true,
        composed: true,
        pointerId: activePointer.pointerID,
        pointerType: activePointer.pointerType,
        isPrimary: true,
        button: 0,
        buttons: 0,
        clientX,
        clientY,
        screenX: activePointer.screenX + (clientX - activePointer.clientX),
        screenY: activePointer.screenY + (clientY - activePointer.clientY)
      };
      if (window.PointerEvent) {
        target.dispatchEvent(new PointerEvent('pointerup', pointerOptions));
      }
      target.dispatchEvent(new MouseEvent('mouseup', pointerOptions));
      try {
        if (typeof target.hasPointerCapture === 'function'
          && target.hasPointerCapture(activePointer.pointerID)) {
          target.releasePointerCapture(activePointer.pointerID);
        }
      } catch (_) {
        // WebKit can discard native capture before the JavaScript bridge runs.
      }
      return true;
    }

    function handleTabsMouseDown(event) {
      if (window.PointerEvent) { return false; }
      return activateTabFromEvent(event);
    }

    function handleTabsClick(event) {
      if (lastHandledTabPointerDownID === event.pointerId) {
        lastHandledTabPointerDownID = null;
        event.preventDefault();
        event.stopPropagation();
        return;
      }
      const target = event.target instanceof Element ? event.target : event.target && event.target.parentElement;
      if (!target) { return; }
      const tabs = window.document.getElementById('tabs');
      const closeButton = target.closest('[data-close]');
      if (closeButton && tabs.contains(closeButton)) {
        event.preventDefault();
        event.stopPropagation();
        const snapshot = snapshotActiveEditorContent();
        post('closeTab', {
          targetID: closeButton.getAttribute('data-close'),
          currentID: snapshot.id,
          content: snapshot.content,
          revision: snapshot.revision
        });
        return;
      }
      activateTabFromEvent(event);
    }

    function setTheme(payload) {
      const options = payload && typeof payload === 'object' ? payload : {};
      const theme = options.theme || (typeof payload === 'string' ? payload : 'vs-dark');
      window.document.body.classList.toggle('light', theme === 'vs');
      if (window.monaco) {
        if (options.monacoTheme) {
          monaco.editor.defineTheme(theme, options.monacoTheme);
        }
        monaco.editor.setTheme(theme);
        if (editor) {
          editor.updateOptions({
            fontFamily: options.fontFamily || 'SFMono-Regular, Menlo, Monaco, Consolas, monospace',
            fontSize: options.fontSize || 13
          });
        }
      }
    }

    function renderPreview(document) {
      const preview = window.document.getElementById('preview');
      preview.innerHTML = '';
      const shell = window.document.createElement('div');
      shell.className = 'preview-shell';
      const toolbar = window.document.createElement('div');
      toolbar.className = 'preview-toolbar';
      const stage = window.document.createElement('div');
      stage.className = 'preview-stage';
      shell.appendChild(toolbar);
      shell.appendChild(stage);
      preview.appendChild(shell);

      function toolbarButton(label, action) {
        const button = window.document.createElement('button');
        button.type = 'button';
        button.textContent = label;
        button.addEventListener('click', action);
        toolbar.appendChild(button);
        return button;
      }

      function renderInfo(message) {
        toolbar.style.display = 'none';
        const info = window.document.createElement('div');
        info.className = 'preview-info';
        const name = window.document.createElement('div');
        name.className = 'preview-name';
        name.textContent = document.fileName || '';
        const detail = window.document.createElement('div');
        detail.textContent = message;
        const size = window.document.createElement('div');
        size.textContent = document.fileSizeText || '';
        info.appendChild(name);
        info.appendChild(detail);
        info.appendChild(size);
        stage.appendChild(info);
      }

      if (!document.previewSource) {
        renderInfo('无法加载预览');
        return;
      }

      if (document.displayMode === 'image') {
        let zoom = 1;
        let rotation = 0;
        let original = false;
        const image = window.document.createElement('img');
        image.src = document.previewSource;
        image.alt = document.fileName || '';
        image.addEventListener('click', () => {
          original = !original;
          updateImage();
        });
        function updateImage() {
          image.classList.toggle('original', original);
          image.style.transform = `scale(${zoom}) rotate(${rotation}deg)`;
        }
        toolbarButton('-', () => {
          zoom = Math.max(0.2, zoom - 0.1);
          updateImage();
        });
        toolbarButton('+', () => {
          zoom = Math.min(5, zoom + 0.1);
          updateImage();
        });
        toolbarButton('1:1', () => {
          original = !original;
          updateImage();
        });
        toolbarButton('↻', () => {
          rotation = (rotation + 90) % 360;
          updateImage();
        });
        stage.appendChild(image);
        updateImage();
        return;
      }

      toolbar.style.display = 'none';
      if (document.displayMode === 'audio') {
        const info = window.document.createElement('div');
        info.className = 'preview-info';
        const name = window.document.createElement('div');
        name.className = 'preview-name';
        name.textContent = document.fileName || '';
        const audio = window.document.createElement('audio');
        audio.controls = true;
        audio.preload = 'metadata';
        audio.src = document.previewSource;
        const size = window.document.createElement('div');
        size.textContent = document.fileSizeText || '';
        info.appendChild(name);
        info.appendChild(audio);
        info.appendChild(size);
        stage.appendChild(info);
        return;
      }

      if (document.displayMode === 'video') {
        const video = window.document.createElement('video');
        video.controls = true;
        video.preload = 'metadata';
        video.src = document.previewSource;
        stage.appendChild(video);
        return;
      }

      renderInfo('当前文件类型不支持预览');
    }

    function setEditorDocument(document, options = {}) {
      if (!editor || !document) { return; }
      activeDocumentID = document.id;
      const language = findLanguage(document);
      const error = window.document.getElementById('error');
      const editorWrap = window.document.getElementById('editor');
      const preview = window.document.getElementById('preview');
      const displayMode = document.displayMode || 'text';
      suppressChange = true;
      if (displayMode !== 'text') {
        editorWrap.style.display = 'none';
        error.style.display = 'none';
        preview.style.display = 'block';
        renderPreview(document);
        suppressChange = false;
        if (options.preserveTabs) {
          renderTabState();
        } else {
          updateTabs(documents, activeDocumentID);
        }
        updateStatus();
        return;
      }
      preview.style.display = 'none';
      preview.innerHTML = '';
      const uri = monaco.Uri.parse(document.monacoURI || `stacio-document:untitled/${encodeURIComponent(document.fileName || 'untitled')}`);
      const nextContent = document.content || '';
      const oldModel = editor.getModel();
      let model = monaco.editor.getModel(uri);
      if (!model) {
        model = monaco.editor.createModel(nextContent, language, uri);
      } else if (model.getValue() !== nextContent) {
        model.setValue(nextContent);
      }
      monaco.editor.setModelLanguage(model, language);
      if (oldModel !== model) {
        editor.setModel(model);
        if (oldModel) { oldModel.dispose(); }
      }
      editor.updateOptions({ readOnly: !document.canEdit });
      editorWrap.style.display = document.canEdit ? 'block' : 'none';
      error.style.display = document.canEdit ? 'none' : 'flex';
      error.textContent = document.errorText || '';
      suppressChange = false;
      if (options.preserveTabs) {
        renderTabState();
      } else {
        updateTabs(documents, activeDocumentID);
      }
      updateStatus();
      scheduleEditorLayout();
      editor.focus();
    }

    function loadWorkspace(payload) {
      documents = payload.documents || [];
      activeDocumentID = payload.activeDocumentID;
      setTheme(payload.theme);
      applyDisplayOptions(payload.displayOptions || {});
      populateLanguageOptions();
      setEditorDocument(activeDocument());
      updateTabs(documents, activeDocumentID);
      post('workspaceReady', { activeDocumentID, documentCount: documents.length });
    }

    function activateDocument(document) {
      documents = documents.map(existing => existing.id === document.id ? document : existing);
      if (!documents.find(existing => existing.id === document.id)) {
        documents.push(document);
      }
      const tabAlreadyRendered = Array.from(window.document.querySelectorAll('#tabs .tab'))
        .some(tab => tab.getAttribute('data-id') === document.id);
      setEditorDocument(document, { preserveTabs: tabAlreadyRendered });
    }

    window.StacioEditor = {
      loadWorkspace,
      activateDocument,
      updateTabs,
      setTheme,
      applyDisplayOptions,
      runEditorAction,
      saveActiveDocument,
      confirmSavedContentBeforeClose,
      releaseStalePointerInteraction,
      layout: scheduleEditorLayout
    };
    window.addEventListener('pointerdown', rememberEditorPrimaryPointer, { capture: true });
    window.addEventListener('pointerup', forgetEditorPrimaryPointer, { capture: true });
    window.addEventListener('pointercancel', forgetEditorPrimaryPointer, { capture: true });
    window.document.getElementById('tabs').addEventListener('pointerdown', handleTabDragCandidate, { capture: true });
    window.document.getElementById('tabs').addEventListener('pointerdown', handleTabsPointerDown, { capture: true });
    window.document.getElementById('tabs').addEventListener('mousedown', handleTabsMouseDown);
    window.document.getElementById('tabs').addEventListener('click', handleTabsClick);
    window.document.getElementById('tabs').addEventListener('scroll', updateTabScrollButtons);
    window.addEventListener('pointerup', cancelTabDragCandidate, { capture: true });
    window.addEventListener('pointercancel', cancelTabDragCandidate, { capture: true });
    window.addEventListener('blur', cancelTabDragCandidate);
    window.document.getElementById('language').addEventListener('change', event => setActiveLanguage(event.target.value));
    window.document.getElementById('tab-scroll-left').addEventListener('click', () => scrollTabsBy(-1));
    window.document.getElementById('tab-scroll-right').addEventListener('click', () => scrollTabsBy(1));
    window.addEventListener('resize', updateTabScrollButtons);
    window.addEventListener('resize', scheduleEditorLayout);

    require.config({
      paths: { vs: 'vs' },
      "vs/nls": { availableLanguages: { "*": "zh-cn" } }
    });
    require(['vs/editor/editor.main'], () => {
      populateLanguageOptions();
      editor = monaco.editor.create(window.document.getElementById('editor'), {
        value: '',
        language: 'plaintext',
        automaticLayout: false,
        lineNumbers: 'on',
        wordWrap: 'off',
        folding: true,
        autoIndent: 'advanced',
        tabSize: 4,
        insertSpaces: true,
        minimap: { enabled: true },
        hover: { enabled: false },
        links: false,
        dragAndDrop: false,
        quickSuggestions: false,
        suggestOnTriggerCharacters: false,
        parameterHints: { enabled: false },
        codeLens: false,
        scrollBeyondLastLine: false,
        renderWhitespace: 'selection',
        fontFamily: 'SFMono-Regular, SF Mono, Menlo, Monaco, Consolas, monospace',
        fontSize: 13,
        theme: 'vs-dark'
      });
      editor.onDidChangeModelContent(() => {
        if (suppressChange) { return; }
        const document = activeDocument();
        if (!document || !document.canEdit) { return; }
        document.revision = (Number.isInteger(document.revision) ? document.revision : 0) + 1;
        document.content = editor.getValue();
        document.isDirty = document.content !== document.originalContent;
        document.saveStateText = document.isDirty ? '未保存改动' : '已保存';
        document.saveStateIsError = false;
        updateTabs(documents, activeDocumentID);
        post('changed', {
          id: document.id,
          content: document.content,
          revision: document.revision
        });
      });
      editor.onDidChangeCursorPosition(updateStatus);
      editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
        saveActiveDocument();
      });
      editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyF, () => runEditorAction({ actionID: findActionID }));
      editor.addCommand(monaco.KeyMod.WinCtrl | monaco.KeyCode.KeyF, () => runEditorAction({ actionID: findActionID }));
      editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyH, () => runEditorAction({ actionID: replaceActionID }));
      editor.addCommand(monaco.KeyMod.WinCtrl | monaco.KeyCode.KeyH, () => runEditorAction({ actionID: replaceActionID }));
      scheduleEditorLayout();
      post('ready');
    });
  </script>
</body>
</html>
"""#
}

@MainActor
private final class RemoteEditorToolbarDragHandleView: NSView {
    var onDrag: ((NSEvent) -> Void)?
    private static let threshold: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 16, height: 12))
        let imageView = NSImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, event.buttonNumber == 0 else { return }
        let start = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = next.locationInWindow
            if next.type == .leftMouseDragged,
               hypot(point.x - start.x, point.y - start.y) > Self.threshold {
                onDrag?(next)
                return
            }
            if next.type == .leftMouseUp { return }
        }
    }
}

@MainActor
public protocol RemoteTextEditorWindowControllerDelegate: AnyObject {
    func remoteTextEditorWindowShouldClose(
        _ controller: RemoteTextEditorWindowController
    ) -> Bool
    func remoteTextEditorWindowDidClose(
        _ controller: RemoteTextEditorWindowController,
        forRedock: Bool
    )
    func remoteTextEditorWindowDidChangeFrame(
        _ controller: RemoteTextEditorWindowController,
        frame: NSRect,
        userInitiated: Bool
    )
    func remoteTextEditorWindowWillEnterFullScreen(
        _ controller: RemoteTextEditorWindowController
    )
    func remoteTextEditorWindowDidExitFullScreen(
        _ controller: RemoteTextEditorWindowController
    )
}

public enum RemoteTextEditorWindowMigrationError: Error, Equatable {
    case occupied
    case contentMismatch
    case invalidContainment
    case windowUnavailable
}

@MainActor
public final class RemoteTextEditorWindowController: NSWindowController, NSWindowDelegate {
    public static let initialContentSize = NSSize(width: 980, height: 720)
    public static let minimumContentSize = NSSize(width: 720, height: 480)
    private static let windowStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
    ]

    public static func frameSize(forContentSize contentSize: NSSize) -> NSSize {
        NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: windowStyleMask
        ).size
    }

    public static var initialFrameSize: NSSize {
        frameSize(forContentSize: initialContentSize)
    }

    public static var minimumFrameSize: NSSize {
        frameSize(forContentSize: minimumContentSize)
    }

    public weak var presentationDelegate: RemoteTextEditorWindowControllerDelegate?
    public var editorViewController: RemoteTextEditorViewController {
        guard let installedEditorViewController else {
            preconditionFailure("The editor window shell does not currently host an editor")
        }
        return installedEditorViewController
    }
    public private(set) var installedEditorViewController: RemoteTextEditorViewController?
    public var onClose: (@MainActor (RemoteTextEditorWindowController) -> Void)?
    public private(set) var isInNativeFullScreen = false
    public var nativeFullscreenToggleCountForTesting: Int {
        (window as? RemoteEditorWindow)?.toggleFullScreenCallCount ?? 0
    }

    private var standaloneLifecycleAdapter: RemoteTextEditorStandaloneWindowLifecycleAdapter?
    private var isClosingForRedock = false
    private var allowsDeferredClose = false
    private var programmaticFrameDepth = 0
    private var programmaticFrameGeneration = 0
    private var lastProgrammaticFrame: NSRect?

    public init() {
        let window = RemoteEditorWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
            styleMask: Self.windowStyleMask,
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(Self.initialContentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    public convenience init(
        editorViewController: RemoteTextEditorViewController,
        closeConfirmer: RemoteTextEditorCloseConfirming? = nil
    ) {
        self.init()
        do {
            try installEditor(editorViewController)
        } catch {
            preconditionFailure("A fresh editor window must accept its initial editor: \(error)")
        }
        let adapter = RemoteTextEditorStandaloneWindowLifecycleAdapter(
            controller: self,
            editor: editorViewController,
            closeConfirmer: closeConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
        )
        standaloneLifecycleAdapter = adapter
        presentationDelegate = adapter
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    func validateEmptyShellForMigration() throws {
        guard let window else {
            throw RemoteTextEditorWindowMigrationError.windowUnavailable
        }
        guard installedEditorViewController == nil,
              window.contentViewController == nil
        else {
            throw RemoteTextEditorWindowMigrationError.occupied
        }
    }

    public func installEditor(_ editor: RemoteTextEditorViewController) throws {
        guard let window else {
            throw RemoteTextEditorWindowMigrationError.windowUnavailable
        }
        if let current = installedEditorViewController {
            guard current === editor else {
                throw RemoteTextEditorWindowMigrationError.occupied
            }
            return
        }
        guard editor.parent == nil,
              editor.isViewLoaded == false || editor.view.superview == nil
        else {
            throw RemoteTextEditorWindowMigrationError.invalidContainment
        }
        guard window.contentViewController == nil else {
            throw RemoteTextEditorWindowMigrationError.occupied
        }

        let preservedContentSize = window.contentLayoutRect.size
        installedEditorViewController = editor
        window.contentViewController = editor
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(preservedContentSize)
        updateDocumentPresentation(
            fileName: editor.activeFileNameForTesting,
            isDirty: editor.hasUnsavedChangesForTesting
        )
    }

    public func removeEditorForMigration(_ editor: RemoteTextEditorViewController) throws {
        guard let current = installedEditorViewController, current === editor else {
            throw RemoteTextEditorWindowMigrationError.contentMismatch
        }
        guard let window, window.contentViewController === editor else {
            throw RemoteTextEditorWindowMigrationError.contentMismatch
        }
        window.contentViewController = nil
        installedEditorViewController = nil
    }

    public func closeShellForRedock() {
        if let editor = installedEditorViewController {
            try? removeEditorForMigration(editor)
        }
        if installedEditorViewController != nil || window?.contentViewController != nil {
            window?.contentViewController = nil
            installedEditorViewController = nil
        }
        isClosingForRedock = true
        window?.close()
    }

    public func completeDeferredUserClose() {
        allowsDeferredClose = true
        if window?.isVisible == true {
            window?.performClose(nil)
        } else {
            window?.close()
        }
    }

    public func applyProgrammaticFrame(_ frame: NSRect, display: Bool) {
        guard let window else { return }
        programmaticFrameGeneration += 1
        let generation = programmaticFrameGeneration
        programmaticFrameDepth += 1
        defer { programmaticFrameDepth -= 1 }
        if let remoteEditorWindow = window as? RemoteEditorWindow {
            remoteEditorWindow.setFrameWithoutScreenConstraint(frame, display: display)
        } else {
            window.setFrame(frame, display: display)
        }
        lastProgrammaticFrame = window.frame
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.programmaticFrameGeneration == generation else {
                return
            }
            (window as? RemoteEditorWindow)?.finishProgrammaticFramePlacement()
            guard self.lastProgrammaticFrame.map({
                      Self.framesApproximatelyEqual(window.frame, $0)
                  }) == true
            else {
                return
            }
            self.lastProgrammaticFrame = nil
        }
    }

    public func updateDocumentPresentation(fileName: String, isDirty: Bool) {
        window?.title = Self.windowTitle(fileName: fileName, isDirty: isDirty)
        window?.isDocumentEdited = isDirty
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowsDeferredClose {
            allowsDeferredClose = false
            return true
        }
        return presentationDelegate?.remoteTextEditorWindowShouldClose(self) ?? true
    }

    public func windowWillClose(_ notification: Notification) {
        let delegate = presentationDelegate
        let closedForRedock = isClosingForRedock
        presentationDelegate = nil
        window?.delegate = nil
        standaloneLifecycleAdapter?.detach()
        standaloneLifecycleAdapter = nil
        onClose?(self)
        delegate?.remoteTextEditorWindowDidClose(self, forRedock: closedForRedock)
    }

    public func windowDidMove(_ notification: Notification) {
        reportFrameChange()
    }

    public func windowDidResize(_ notification: Notification) {
        reportFrameChange()
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        isInNativeFullScreen = true
        presentationDelegate?.remoteTextEditorWindowWillEnterFullScreen(self)
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        isInNativeFullScreen = false
        presentationDelegate?.remoteTextEditorWindowDidExitFullScreen(self)
    }

    public func simulateUserFrameChangeForTesting(_ frame: NSRect) {
        window?.setFrame(frame, display: false)
        presentationDelegate?.remoteTextEditorWindowDidChangeFrame(
            self,
            frame: frame,
            userInitiated: true
        )
    }

    public func simulateWillEnterFullScreenForTesting() {
        windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
    }

    public func simulateDidExitFullScreenForTesting() {
        windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
    }

    private func reportFrameChange() {
        guard let frame = window?.frame else { return }
        let matchesProgrammaticFrame = lastProgrammaticFrame.map {
            Self.framesApproximatelyEqual($0, frame)
        } ?? false
        presentationDelegate?.remoteTextEditorWindowDidChangeFrame(
            self,
            frame: frame,
            userInitiated: programmaticFrameDepth == 0 && matchesProgrammaticFrame == false
        )
    }

    private static func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5
            && abs(lhs.minY - rhs.minY) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5
            && abs(lhs.height - rhs.height) <= 0.5
    }

    private static func windowTitle(fileName: String, isDirty: Bool) -> String {
        isDirty ? "● \(fileName)" : fileName
    }
}

private final class RemoteEditorWindow: NSWindow {
    private var bypassesScreenConstraint = false
    private(set) var toggleFullScreenCallCount = 0

    func setFrameWithoutScreenConstraint(_ frame: NSRect, display: Bool) {
        bypassesScreenConstraint = true
        setFrame(frame, display: display)
    }

    func finishProgrammaticFramePlacement() {
        bypassesScreenConstraint = false
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        bypassesScreenConstraint ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func toggleFullScreen(_ sender: Any?) {
        toggleFullScreenCallCount += 1
        super.toggleFullScreen(sender)
    }
}

@MainActor
private final class RemoteTextEditorStandaloneWindowLifecycleAdapter:
    RemoteTextEditorWindowControllerDelegate
{
    private weak var controller: RemoteTextEditorWindowController?
    private weak var editor: RemoteTextEditorViewController?
    private let closeConfirmer: RemoteTextEditorCloseConfirming
    private var isWaitingForCloseResolution = false

    init(
        controller: RemoteTextEditorWindowController,
        editor: RemoteTextEditorViewController,
        closeConfirmer: RemoteTextEditorCloseConfirming
    ) {
        self.controller = controller
        self.editor = editor
        self.closeConfirmer = closeConfirmer
        editor.onStandaloneWindowPresentationChanged = { [weak controller] fileName, isDirty in
            controller?.updateDocumentPresentation(fileName: fileName, isDirty: isDirty)
        }
        editor.onStandaloneWindowCloseRequested = { [weak controller] in
            controller?.window?.performClose(nil)
        }
        editor.onStandaloneWindowCloseResolved = { [weak self] resolution in
            self?.closeDidResolve(resolution)
        }
    }

    func detach() {
        editor?.onStandaloneWindowPresentationChanged = nil
        editor?.onStandaloneWindowCloseRequested = nil
        editor?.onStandaloneWindowCloseResolved = nil
        isWaitingForCloseResolution = false
    }

    func remoteTextEditorWindowShouldClose(
        _ controller: RemoteTextEditorWindowController
    ) -> Bool {
        guard isWaitingForCloseResolution == false, let editor else { return false }
        switch editor.requestClose(parentWindow: controller.window, closeConfirmer: closeConfirmer) {
        case .ready:
            return true
        case .cancelled:
            return false
        case .pending:
            isWaitingForCloseResolution = true
            return false
        }
    }

    func remoteTextEditorWindowDidClose(
        _ controller: RemoteTextEditorWindowController,
        forRedock: Bool
    ) {
        detach()
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

    private func closeDidResolve(_ resolution: RemoteTextEditorCloseResolution) {
        guard isWaitingForCloseResolution else { return }
        isWaitingForCloseResolution = false
        if resolution == .ready {
            controller?.completeDeferredUserClose()
        }
    }
}

private enum RemoteTextEditorDocumentDisplayMode: String {
    case text
    case image
    case audio
    case video

    init?(contentKind: RemoteFileContentKind) {
        switch contentKind {
        case .text, .other:
            self = .text
        case .image:
            self = .image
        case .audio:
            self = .audio
        case .video:
            self = .video
        }
    }
}

public struct RemoteTextEditorBackupCandidate: Equatable {
    public let fileName: String
    public let remotePath: String
    public let localURL: URL
    public let size: UInt64
}

private struct RemoteTextEditorDocument {
    let id: String
    let monacoURI: String
    let localURL: URL
    let fileName: String
    let path: String
    let byteCount: UInt64
    var text: String
    var originalText: String
    var revision: Int = 0
    var languageIdentifier: String
    let canEdit: Bool
    let errorText: String?
    let onSaveText: ((String) throws -> Void)?
    let onSaveTextAsync: RemoteTextEditorAsyncSaveHandler?
    let encodingDisplayName: String
    var saveState: RemoteTextEditorSaveState
    var saveFailureMessage: String? = nil
    var saveRequestID: UUID? = nil
    let displayMode: RemoteTextEditorDocumentDisplayMode
    let previewSource: String?
    let fileSizeText: String

    var isDirty: Bool {
        canEdit && text != originalText
    }

    var saveStatusText: String {
        switch saveState {
        case .failed:
            let message = saveFailureMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? saveState.displayText : "保存失败：\(message)"
        case .saved, .dirty, .saving:
            return saveState.displayText
        }
    }

    var saveStatusIsError: Bool {
        saveState == .failed
    }
}

private struct EditorDocumentPayload: Encodable {
    let id: String
    let monacoURI: String
    let fileName: String
    let path: String
    let content: String
    let originalContent: String
    let revision: Int
    let languageIdentifier: String
    let canEdit: Bool
    let encodingDisplayName: String
    let isDirty: Bool
    let saveStateText: String
    let saveStateIsError: Bool
    let errorText: String?
    let displayMode: String
    let previewSource: String?
    let fileSizeText: String

    init(document: RemoteTextEditorDocument) {
        id = document.id
        monacoURI = document.monacoURI
        fileName = document.fileName
        path = document.path
        content = document.text
        originalContent = document.originalText
        revision = document.revision
        languageIdentifier = document.languageIdentifier
        canEdit = document.canEdit
        encodingDisplayName = document.encodingDisplayName
        isDirty = document.isDirty
        saveStateText = document.saveStatusText
        saveStateIsError = document.saveStatusIsError
        errorText = document.errorText
        displayMode = document.displayMode.rawValue
        previewSource = document.previewSource
        fileSizeText = document.fileSizeText
    }
}

private struct EditorWorkspacePayload: Encodable {
    let documents: [EditorDocumentPayload]
    let activeDocumentID: String
    let displayOptions: RemoteTextEditorDisplayOptions
    let theme: ThemePayload
}

private struct EditorTabsPayload: Encodable {
    let documents: [EditorDocumentPayload]
    let activeDocumentID: String
}

private struct EditorCloseHandshakeRequestPayload: Encodable {
    let documentID: String
    let requestID: String
}

private struct PendingSavedCloseHandshake {
    let requestID: String
    let savedText: String
    let savedRevision: Int
}

private enum RemoteTextEditorJavaScriptError: Error {
    case bridgeUnavailable
    case invalidPayload
}

private struct EditorActionPayload: Encodable {
    let actionID: String
}

private struct EditorPointerReleasePayload: Encodable {
    let notAfterEpochMilliseconds: Double
    let clientX: Double?
    let clientY: Double?
}

private struct EmptyEditorPayload: Encodable {}

private struct ThemePayload: Encodable {
    let theme: String
    let fontFamily: String
    let fontSize: Int
    let monacoTheme: MonacoThemePayload?

    init(settings: AppSettings, theme: String) {
        self.theme = theme
        self.fontFamily = RemoteTextEditorTheme.monacoFontFamily(settings: settings)
        self.fontSize = Int(settings.terminalFontSize.rounded())
        self.monacoTheme = RemoteTextEditorTheme.monacoThemePayload(settings: settings, themeIdentifier: theme)
    }
}

private final class RemoteTextEditorScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var editor: RemoteTextEditorViewController?

    init(editor: RemoteTextEditorViewController) {
        self.editor = editor
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak editor] in
            editor?.handleScriptMessage(message)
        }
    }
}

private enum MonacoEditorResourceLocator {
    static func monacoBaseURL() -> URL {
        for candidate in candidateBaseURLs() {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("vs/loader.js").path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private static func candidateBaseURLs() -> [URL] {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appResourceURL = Bundle.main.resourceURL?.appendingPathComponent("MonacoEditor")
        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("node_modules/monaco-editor/min")
        let sourceURL = repoRoot.appendingPathComponent("node_modules/monaco-editor/min")
        return [appResourceURL, cwdURL, sourceURL].compactMap { $0 }
    }
}

private final class RemoteTextEditorRootView: NSView, StacioEffectiveAppearanceRefreshHandling {
    var onEffectiveAppearanceDidChange: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onLiveResizeStarted: (() -> Void)?
    var onLiveResizeEnded: (() -> Void)?
    var onWindowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        onLiveResizeStarted?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onLiveResizeEnded?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let window {
            StacioDesignSystem.scheduleWindowDynamicColorsRefresh(window)
            return
        }
        stacioRefreshEffectiveAppearance()
    }

    func stacioRefreshEffectiveAppearance() {
        onEffectiveAppearanceDidChange?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
