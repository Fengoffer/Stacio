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

public enum RemoteTextEditorCloseDecision {
    case save
    case discard
    case cancel
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
    public let remotePath: String
    public let fileName: String
    public let content: String
    public let contentKind: RemoteFileContentKind
    public let previewSource: String?
    public let byteCount: UInt64

    public init(
        remotePath: String,
        fileName: String,
        content: String,
        contentKind: RemoteFileContentKind = .text,
        previewSource: String? = nil,
        byteCount: UInt64 = 0
    ) {
        self.remotePath = remotePath
        self.fileName = fileName
        self.content = content
        self.contentKind = contentKind
        self.previewSource = previewSource
        self.byteCount = byteCount
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
    private static let aiDocumentExcerptLimit = 12_000

    public let localURL: URL
    public var onDirtyStateChanged: ((Bool) -> Void)?
    public var onActiveDocumentChanged: ((String, Bool) -> Void)?
    public var onCloseRequested: (() -> Void)?
    public var onAIQuestionRequested: ((String) -> Void)?

    private let settingsStore: AppSettingsStore
    private var webView: WKWebView?
    private var scriptMessageHandler: RemoteTextEditorScriptMessageHandler?
    private var settingsObserver: NSObjectProtocol?
    private var documents: [RemoteTextEditorDocument]
    private var activeDocumentID: String
    private var currentThemeIdentifier = "vs-dark"
    private var isEditorReady = false
    private var cursorLine = 1
    private var cursorColumn = 1
    private let editorOptionsDefaults: UserDefaults
    private var editorDisplayOptions: RemoteTextEditorDisplayOptions
    private weak var lineNumbersButton: NSButton?
    private weak var wordWrapButton: NSButton?
    private weak var minimapButton: NSButton?
    private var editorFunctionCallsForTestingStorage: [String] = []
    private var editorFunctionScriptsForTestingStorage: [String] = []

    public init(
        localURL: URL,
        settingsStore: AppSettingsStore = .shared,
        editorOptionsDefaults: UserDefaults = .standard,
        onSave: ((URL) throws -> Void)? = nil
    ) {
        self.localURL = localURL
        self.settingsStore = settingsStore
        self.editorOptionsDefaults = editorOptionsDefaults
        self.editorDisplayOptions = RemoteTextEditorDisplayOptions.load(defaults: editorOptionsDefaults)
        let document = Self.makeDocument(localURL: localURL, onSave: onSave)
        self.documents = [document]
        self.activeDocumentID = document.id
        super.init(nibName: nil, bundle: nil)
        title = localURL.lastPathComponent
    }

    public init(
        document: RemoteTextEditorDocumentDescriptor,
        settingsStore: AppSettingsStore = .shared,
        editorOptionsDefaults: UserDefaults = .standard,
        onSaveText: ((String) throws -> Void)? = nil
    ) {
        self.localURL = URL(fileURLWithPath: document.remotePath)
        self.settingsStore = settingsStore
        self.editorOptionsDefaults = editorOptionsDefaults
        self.editorDisplayOptions = RemoteTextEditorDisplayOptions.load(defaults: editorOptionsDefaults)
        let editorDocument = Self.makeDocument(document: document, onSaveText: onSaveText)
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
        root.wantsLayer = true
        root.setAccessibilityIdentifier("Stacio.Editor.root")

        let toolbar = makeToolbar()
        let editorWebView = makeWebView()
        root.addSubview(toolbar)
        root.addSubview(editorWebView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 34),
            editorWebView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorWebView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorWebView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            editorWebView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        webView = editorWebView
        view = root
        observeSettingsChanges()
        applyCurrentTheme()
        loadMonacoEditorHTML()
        markDirtyIfNeeded()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(webView)
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
        activeDocument?.canEdit == true ? "UTF-8" : "-"
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
        Self.editorHTML
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
        isEditorReady = true
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

    public func closeDocumentForTesting(fileName: String) {
        guard let document = documents.first(where: { $0.fileName == fileName }) else {
            return
        }
        closeDocument(id: document.id)
    }

    public func openDocument(localURL: URL, onSave: ((URL) throws -> Void)? = nil) {
        if let existing = documents.first(where: { $0.localURL.path == localURL.path }) {
            activateDocument(id: existing.id)
            return
        }
        let document = Self.makeDocument(localURL: localURL, onSave: onSave)
        documents.append(document)
        activateDocument(id: document.id)
    }

    public func openDocument(
        _ descriptor: RemoteTextEditorDocumentDescriptor,
        onSaveText: ((String) throws -> Void)? = nil
    ) {
        if let existing = documents.first(where: { $0.path == descriptor.remotePath }) {
            activateDocument(id: existing.id)
            return
        }
        let document = Self.makeDocument(document: descriptor, onSaveText: onSaveText)
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
        guard let prompt = aiQuestionForActiveDocument() else {
            return
        }
        onAIQuestionRequested?(prompt)
    }

    @discardableResult
    public func canClose(
        parentWindow: NSWindow?,
        closeConfirmer: RemoteTextEditorCloseConfirming
    ) -> Bool {
        let dirtyDocumentIDs = documents.filter(\.isDirty).map(\.id)
        guard dirtyDocumentIDs.isEmpty == false else {
            return true
        }
        for documentID in dirtyDocumentIDs {
            guard let document = document(id: documentID) else {
                continue
            }
            switch closeConfirmer.confirmClose(fileName: document.fileName, parentWindow: parentWindow) {
            case .save:
                do {
                    try saveDocument(id: documentID)
                } catch {
                    presentSaveError(error, parentWindow: parentWindow)
                    return false
                }
            case .discard:
                continue
            case .cancel:
                return false
            }
        }
        return true
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "stacioEditor")
    }

    private static func makeDocument(
        localURL: URL,
        onSave: ((URL) throws -> Void)?
    ) -> RemoteTextEditorDocument {
        let fileName = localURL.lastPathComponent
        let contentKind = StacioFileDisplay.contentKind(forFileName: fileName)
        if let displayMode = RemoteTextEditorDocumentDisplayMode(contentKind: contentKind),
           displayMode != .text
        {
            return RemoteTextEditorDocument(
                id: UUID().uuidString,
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
                saveState: .saved,
                displayMode: displayMode,
                previewSource: mediaPreviewSource(for: localURL, contentKind: contentKind),
                fileSizeText: fileSizeText(for: localURL)
            )
        }

        let data = (try? Data(contentsOf: localURL)) ?? Data()
        guard data.contains(0) == false,
              let text = String(data: data, encoding: .utf8)
        else {
            return RemoteTextEditorDocument(
                id: UUID().uuidString,
                localURL: localURL,
                fileName: fileName,
                path: localURL.path,
                byteCount: UInt64(data.count),
                text: "",
                originalText: "",
                languageIdentifier: StacioFileDisplay.languageIdentifier(forFileName: fileName),
                canEdit: false,
                errorText: RemoteTextEditorError.nonUTF8Text(fileName).localizedDescription,
                onSaveText: nil,
                saveState: .saved,
                displayMode: .text,
                previewSource: nil,
                fileSizeText: fileSizeText(for: localURL)
            )
        }

        return RemoteTextEditorDocument(
            id: UUID().uuidString,
            localURL: localURL,
            fileName: fileName,
            path: localURL.path,
            byteCount: UInt64(data.count),
            text: text,
            originalText: text,
            languageIdentifier: StacioFileDisplay.languageIdentifier(forFileName: fileName, content: text),
            canEdit: true,
            errorText: nil,
            onSaveText: { text in
                try text.write(to: localURL, atomically: true, encoding: .utf8)
                try onSave?(localURL)
            },
            saveState: .saved,
            displayMode: .text,
            previewSource: nil,
            fileSizeText: fileSizeText(for: localURL)
        )
    }

    private static func makeDocument(
        document: RemoteTextEditorDocumentDescriptor,
        onSaveText: ((String) throws -> Void)?
    ) -> RemoteTextEditorDocument {
        let displayMode = RemoteTextEditorDocumentDisplayMode(contentKind: document.contentKind) ?? .text
        let localURL = URL(fileURLWithPath: document.remotePath)
        if displayMode != .text {
            return RemoteTextEditorDocument(
                id: UUID().uuidString,
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
                saveState: .saved,
                displayMode: displayMode,
                previewSource: document.previewSource,
                fileSizeText: fileSizeText(byteCount: document.byteCount)
            )
        }

        return RemoteTextEditorDocument(
            id: UUID().uuidString,
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
        RemoteTextEditorDocument(
            id: UUID().uuidString,
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
        editorWebView.navigationDelegate = self
        editorWebView.setAccessibilityIdentifier("Stacio.Editor.webView")
        editorWebView.setValue(false, forKey: "drawsBackground")
        return editorWebView
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
        lineNumbersButton = lineNumbers
        wordWrapButton = wordWrap
        minimapButton = minimap

        [lineNumbers, wordWrap, minimap].forEach(stack.addArrangedSubview)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        [find, replace].forEach(stack.addArrangedSubview)

        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)
        ])
        updateToolbarButtonStates()
        return toolbar
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
        callEditorFunction("setTheme", payload: ThemePayload(settings: settings, theme: currentThemeIdentifier))
    }

    private func loadMonacoEditorHTML() {
        let baseURL = MonacoEditorResourceLocator.monacoBaseURL()
        webView?.loadHTMLString(Self.editorHTML, baseURL: baseURL)
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
              let name = body["name"] as? String
        else {
            return
        }
        let payload = body["payload"] as? [String: Any]
        switch name {
        case "ready":
            isEditorReady = true
            syncWorkspaceToWebView()
        case "changed":
            guard let id = payload?["id"] as? String,
                  let content = payload?["content"] as? String
            else { return }
            updateDocumentText(id: id, text: content)
        case "save":
            var saveTargetID = activeDocumentID
            if let id = payload?["id"] as? String,
               let content = payload?["content"] as? String
            {
                saveTargetID = id
                updateDocumentText(id: id, text: content)
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
                content: payload?["content"] as? String
            )
        case "closeTab":
            if let currentID = payload?["currentID"] as? String,
               let content = payload?["content"] as? String
            {
                updateDocumentText(id: currentID, text: content)
            }
            guard let targetID = payload?["targetID"] as? String else { return }
            closeDocument(id: targetID)
        default:
            break
        }
    }

    private func updateDocumentText(id: String, text: String, syncTabs: Bool = true) {
        guard let index = documents.firstIndex(where: { $0.id == id }),
              documents[index].canEdit
        else {
            return
        }
        documents[index].text = text
        documents[index].saveState = documents[index].isDirty ? .dirty : .saved
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

    private func handleSwitchTabRequest(targetID: String, currentID: String?, content: String?) {
        guard documents.contains(where: { $0.id == targetID }) else {
            return
        }
        if let currentID, let content {
            updateDocumentText(id: currentID, text: content, syncTabs: false)
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

    private func closeDocument(id: String) {
        guard documents.count > 1,
              let index = documents.firstIndex(where: { $0.id == id })
        else {
            onCloseRequested?()
            return
        }
        if documents[index].isDirty {
            let confirmer = AppKitRemoteTextEditorCloseConfirmer()
            switch confirmer.confirmClose(fileName: documents[index].fileName, parentWindow: view.window) {
            case .save:
                do {
                    try saveDocument(id: id)
                } catch {
                    presentSaveError(error, parentWindow: view.window)
                    return
                }
            case .discard:
                break
            case .cancel:
                syncWorkspaceToWebView()
                return
            }
        }
        let wasActive = documents[index].id == activeDocumentID
        documents.remove(at: index)
        if wasActive {
            let nextIndex = min(index, documents.count - 1)
            activeDocumentID = documents[nextIndex].id
        }
        markDirtyIfNeeded()
        syncWorkspaceToWebView()
    }

    private func saveDocument(id: String) throws {
        guard let index = documents.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard documents[index].canEdit else {
            throw RemoteTextEditorError.nonUTF8Text(documents[index].fileName)
        }
        let text = documents[index].text
        documents[index].saveState = .saving
        documents[index].saveFailureMessage = nil
        markDirtyIfNeeded()
        syncTabStateToWebView()
        do {
            try documents[index].onSaveText?(text)
        } catch {
            documents[index].saveState = .failed
            documents[index].saveFailureMessage = RuntimeDiagnosticFormatter.userMessage(for: error)
            markDirtyIfNeeded()
            syncTabStateToWebView()
            throw error
        }
        documents[index].originalText = text
        documents[index].saveState = .saved
        documents[index].saveFailureMessage = nil
        markDirtyIfNeeded()
        syncTabStateToWebView()
    }

    private func aiQuestionForActiveDocument() -> String? {
        guard let document = activeDocument,
              document.displayMode == .text,
              document.canEdit,
              document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        let excerpt = Self.truncatedAIExcerpt(document.text)
        let suffix = document.text.count > Self.aiDocumentExcerptLimit
            ? "\n\n内容已截断，只包含前 \(Self.aiDocumentExcerptLimit) 个字符。"
            : ""
        return """
        解释并排查这个远程文件，指出潜在风险、配置问题和可改进点。先给结论，再列建议；不要直接生成会修改远程文件的命令，除非我明确要求。

        文件：\(document.fileName)
        路径：\(document.path)
        语言：\(document.languageIdentifier)

        ```\(document.languageIdentifier)
        \(excerpt)
        ```
        \(suffix)
        """
    }

    private static func truncatedAIExcerpt(_ text: String) -> String {
        guard text.count > aiDocumentExcerptLimit else {
            return text
        }
        return String(text.prefix(aiDocumentExcerptLimit))
    }

    private func markDirtyIfNeeded() {
        guard let activeDocument else { return }
        onDirtyStateChanged?(hasUnsavedChanges)
        onActiveDocumentChanged?(activeDocument.fileName, hasUnsavedChanges)
    }

    private func syncWorkspaceToWebView() {
        guard isEditorReady else { return }
        callEditorFunction(
            "loadWorkspace",
            payload: EditorWorkspacePayload(
                documents: documents.map(EditorDocumentPayload.init(document:)),
                activeDocumentID: activeDocumentID,
                displayOptions: editorDisplayOptions,
                theme: ThemePayload(settings: settingsStore.snapshot(), theme: currentThemeIdentifier)
            )
        )
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

    private func callEditorFunction<Payload: Encodable>(_ functionName: String, payload: Payload) {
        guard isViewLoaded,
              let webView,
              let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        editorFunctionCallsForTestingStorage.append(functionName)
        let script = "window.StacioEditor && window.StacioEditor.\(functionName)(\(json));"
        editorFunctionScriptsForTestingStorage.append(script)
        webView.evaluateJavaScript(script, completionHandler: nil)
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

    private static let editorHTML = #"""
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
    const post = (name, payload = {}) => {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.stacioEditor) {
        window.webkit.messageHandlers.stacioEditor.postMessage({ name, payload });
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
      window.document.getElementById('encoding').textContent = document && document.canEdit ? 'UTF-8' : '-';
      setSaveStateDisplay(
        document ? (document.saveStateText || (document.isDirty ? '未保存改动' : '已保存')) : '已保存',
        Boolean(document && document.saveStateIsError)
      );
      post('cursor', { line: position.lineNumber, column: position.column });
    }

    function updateTabs(payloadDocuments = documents, payloadActiveID = activeDocumentID) {
      documents = payloadDocuments;
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
        document.content = content;
        document.isDirty = document.content !== document.originalContent;
        document.saveStateText = document.isDirty ? '未保存改动' : '已保存';
        document.saveStateIsError = false;
      }
      return { id: activeDocumentID, content };
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
      const closeButton = target.closest('[data-close]');
      if (closeButton && tabs.contains(closeButton)) {
        return false;
      }
      const tab = target.closest('.tab');
      if (!tab || !tabs.contains(tab)) { return false; }
      const targetID = tab.getAttribute('data-id');
      const snapshot = snapshotActiveEditorContent();
      if (switchToTab(targetID)) {
        event.preventDefault();
        event.stopPropagation();
        post('switchTab', { targetID, currentID: snapshot.id, content: snapshot.content });
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
        post('closeTab', { targetID: closeButton.getAttribute('data-close'), currentID: snapshot.id, content: snapshot.content });
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
      const uri = monaco.Uri.file(document.path || document.fileName || 'untitled');
      const model = monaco.editor.createModel(document.content || '', language, uri);
      monaco.editor.setModelLanguage(model, language);
      const oldModel = editor.getModel();
      editor.setModel(model);
      if (oldModel) { oldModel.dispose(); }
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
      saveActiveDocument
    };
    window.document.getElementById('tabs').addEventListener('pointerdown', handleTabsPointerDown, { capture: true });
    window.document.getElementById('tabs').addEventListener('mousedown', handleTabsMouseDown);
    window.document.getElementById('tabs').addEventListener('click', handleTabsClick);
    window.document.getElementById('tabs').addEventListener('scroll', updateTabScrollButtons);
    window.document.getElementById('language').addEventListener('change', event => setActiveLanguage(event.target.value));
    window.document.getElementById('tab-scroll-left').addEventListener('click', () => scrollTabsBy(-1));
    window.document.getElementById('tab-scroll-right').addEventListener('click', () => scrollTabsBy(1));
    window.addEventListener('resize', updateTabScrollButtons);

    require.config({
      paths: { vs: 'vs' },
      "vs/nls": { availableLanguages: { "*": "zh-cn" } }
    });
    require(['vs/editor/editor.main'], () => {
      populateLanguageOptions();
      editor = monaco.editor.create(window.document.getElementById('editor'), {
        value: '',
        language: 'plaintext',
        automaticLayout: true,
        lineNumbers: 'on',
        wordWrap: 'off',
        folding: true,
        autoIndent: 'advanced',
        tabSize: 4,
        insertSpaces: true,
        minimap: { enabled: true },
        hover: { enabled: false },
        links: false,
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
        document.content = editor.getValue();
        document.isDirty = document.content !== document.originalContent;
        document.saveStateText = document.isDirty ? '未保存改动' : '已保存';
        document.saveStateIsError = false;
        updateTabs(documents, activeDocumentID);
        post('changed', { id: document.id, content: document.content });
      });
      editor.onDidChangeCursorPosition(updateStatus);
      editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
        saveActiveDocument();
      });
      editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyF, () => runEditorAction({ actionID: findActionID }));
      editor.addCommand(monaco.KeyMod.WinCtrl | monaco.KeyCode.KeyF, () => runEditorAction({ actionID: findActionID }));
      editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyH, () => runEditorAction({ actionID: replaceActionID }));
      editor.addCommand(monaco.KeyMod.WinCtrl | monaco.KeyCode.KeyH, () => runEditorAction({ actionID: replaceActionID }));
      post('ready');
    });
  </script>
</body>
</html>
"""#
}

@MainActor
public final class RemoteTextEditorWindowController: NSWindowController, NSWindowDelegate {
    public let editorViewController: RemoteTextEditorViewController
    public var onClose: (@MainActor (RemoteTextEditorWindowController) -> Void)?

    private let closeConfirmer: RemoteTextEditorCloseConfirming

    public init(
        editorViewController: RemoteTextEditorViewController,
        closeConfirmer: RemoteTextEditorCloseConfirming? = nil
    ) {
        self.editorViewController = editorViewController
        self.closeConfirmer = closeConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle(fileName: editorViewController.activeFileNameForTesting, isDirty: false)
        window.contentViewController = editorViewController
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        window.delegate = self
        editorViewController.onDirtyStateChanged = { [weak window, weak editorViewController] isDirty in
            let fileName = editorViewController?.activeFileNameForTesting ?? ""
            window?.title = Self.windowTitle(fileName: fileName, isDirty: isDirty)
            window?.isDocumentEdited = isDirty
        }
        editorViewController.onActiveDocumentChanged = { [weak window] fileName, isDirty in
            window?.title = Self.windowTitle(fileName: fileName, isDirty: isDirty)
            window?.isDocumentEdited = isDirty
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        editorViewController.canClose(parentWindow: sender, closeConfirmer: closeConfirmer)
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    private static func windowTitle(fileName: String, isDirty: Bool) -> String {
        isDirty ? "● \(fileName)" : fileName
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
    let localURL: URL
    let fileName: String
    let path: String
    let byteCount: UInt64
    var text: String
    var originalText: String
    var languageIdentifier: String
    let canEdit: Bool
    let errorText: String?
    let onSaveText: ((String) throws -> Void)?
    var saveState: RemoteTextEditorSaveState
    var saveFailureMessage: String? = nil
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
    let fileName: String
    let path: String
    let content: String
    let originalContent: String
    let languageIdentifier: String
    let canEdit: Bool
    let isDirty: Bool
    let saveStateText: String
    let saveStateIsError: Bool
    let errorText: String?
    let displayMode: String
    let previewSource: String?
    let fileSizeText: String

    init(document: RemoteTextEditorDocument) {
        id = document.id
        fileName = document.fileName
        path = document.path
        content = document.text
        originalContent = document.originalText
        languageIdentifier = document.languageIdentifier
        canEdit = document.canEdit
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

private struct EditorActionPayload: Encodable {
    let actionID: String
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
