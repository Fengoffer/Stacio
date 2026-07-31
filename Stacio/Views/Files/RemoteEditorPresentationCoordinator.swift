import AppKit

public enum RemoteEditorPresentationMode: Equatable {
    case closed
    case opening
    case docked
    case dockedHidden
    case floating
    case displayMaximized
}

public struct RemoteEditorPresentationSnapshot: Equatable {
    public let mode: RemoteEditorPresentationMode
    public let hasEditor: Bool
    public let isTransitioning: Bool
    public let detachedFeatureEnabled: Bool

    public init(
        mode: RemoteEditorPresentationMode,
        hasEditor: Bool,
        isTransitioning: Bool,
        detachedFeatureEnabled: Bool
    ) {
        self.mode = mode
        self.hasEditor = hasEditor
        self.isTransitioning = isTransitioning
        self.detachedFeatureEnabled = detachedFeatureEnabled
    }

    public var canCollapse: Bool { mode == .docked || mode == .dockedHidden }
    public var isCollapsed: Bool { mode == .dockedHidden }
    public var isDetached: Bool { mode == .floating || mode == .displayMaximized }
}

public enum RemoteEditorPresentationError: Error, Equatable {
    case transitionInProgress
    case invalidTransition
    case dockHostUnavailable
    case windowCreationFailed
    case screenUnavailable
}

@MainActor
public protocol RemoteEditorPresentationRouting: RemoteEditOpening, AnyObject {
    var currentEditor: RemoteTextEditorViewController? { get }
    var snapshot: RemoteEditorPresentationSnapshot { get }
    var onSnapshotChanged: ((RemoteEditorPresentationSnapshot) -> Void)? { get set }
    var onAIQuestionRequested: ((String) -> Void)? { get set }

    func collapseDockedEditor()
    func expandDockedEditor()
    func requestAIForActiveDocument()
    @discardableResult
    func requestClose(
        parentWindow: NSWindow?,
        completion: ((RemoteTextEditorCloseResolution) -> Void)?
    ) -> RemoteTextEditorCloseDisposition
}

public typealias RemoteEditorFactory = @MainActor (
    _ document: RemoteTextEditorDocumentDescriptor,
    _ saveHandler: ((String) throws -> Void)?
) -> RemoteTextEditorViewController

public typealias RemoteEditorOpenProgressFactory = @MainActor (
    _ selection: RemoteFileSelection,
    _ mode: RemoteFileOpenMode
) -> RemoteFileOpenProgressViewController

@MainActor
public final class RemoteEditorPresentationCoordinator: RemoteEditorPresentationRouting {
    private enum State {
        case closed
        case opening(requestID: UUID, progress: RemoteFileOpenProgressViewController)
        case docked(RemoteTextEditorViewController)
        case dockedHidden(RemoteTextEditorViewController)
        case floating(
            RemoteTextEditorViewController,
            RemoteTextEditorWindowController,
            NSRect,
            RemoteEditorScreenIdentity?
        )
        case displayMaximized(
            RemoteTextEditorViewController,
            RemoteTextEditorWindowController,
            RemoteEditorScreenIdentity,
            NSRect?
        )
    }

    private struct OpenRequestKey: Hashable {
        let remotePath: String
        let modeLogName: String
    }

    public var onSnapshotChanged: ((RemoteEditorPresentationSnapshot) -> Void)?
    public var onAIQuestionRequested: ((String) -> Void)?
    public var onWillPresentDockedEditor: ((CGFloat) -> Void)?

    private weak var dockHost: (any RemoteEditorDockHosting)?
    private let presentationStore: any RemoteEditorPresentationStoring
    private let screenProvider: any RemoteEditorScreenProviding
    private let licenseAccess: any LicenseFeatureAccessProviding
    private let authorizer: any LicensedFeatureAuthorizing
    private let closeConfirmer: any RemoteTextEditorCloseConfirming
    private let fallbackOpener: any RemoteEditOpening
    private let editorFactory: RemoteEditorFactory
    private let progressFactory: RemoteEditorOpenProgressFactory

    private var state: State = .closed
    private var activeOpenRequestIDs: [OpenRequestKey: UUID] = [:]
    private var isTransitioning = false
    private weak var pendingCloseEditor: RemoteTextEditorViewController?
    private var pendingCloseCompletions: [(RemoteTextEditorCloseResolution) -> Void] = []

    public init(
        dockHost: any RemoteEditorDockHosting,
        presentationStore: any RemoteEditorPresentationStoring,
        screenProvider: any RemoteEditorScreenProviding,
        licenseAccess: any LicenseFeatureAccessProviding = UnrestrictedLicenseFeatureAccessProvider(),
        authorizer: any LicensedFeatureAuthorizing = LicenseFeatureAuthorizer(),
        closeConfirmer: (any RemoteTextEditorCloseConfirming)? = nil,
        fallbackOpener: (any RemoteEditOpening)? = nil,
        editorFactory: @escaping RemoteEditorFactory = { document, saveHandler in
            RemoteTextEditorViewController(document: document, onSaveText: saveHandler)
        },
        progressFactory: @escaping RemoteEditorOpenProgressFactory = { selection, mode in
            RemoteFileOpenProgressViewController(selection: selection, mode: mode)
        }
    ) {
        self.dockHost = dockHost
        self.presentationStore = presentationStore
        self.screenProvider = screenProvider
        self.licenseAccess = licenseAccess
        self.authorizer = authorizer
        self.closeConfirmer = closeConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
        self.fallbackOpener = fallbackOpener ?? AppKitRemoteEditOpener()
        self.editorFactory = editorFactory
        self.progressFactory = progressFactory
    }

    public var currentEditor: RemoteTextEditorViewController? {
        switch state {
        case .closed, .opening:
            return nil
        case .docked(let editor), .dockedHidden(let editor):
            return editor
        case .floating(let editor, _, _, _), .displayMaximized(let editor, _, _, _):
            return editor
        }
    }

    public var snapshot: RemoteEditorPresentationSnapshot {
        RemoteEditorPresentationSnapshot(
            mode: presentationMode,
            hasEditor: currentEditor != nil,
            isTransitioning: isTransitioning,
            detachedFeatureEnabled: licenseAccess.isEnabled(.detachedFileEditor)
        )
    }

    public func refreshLicenseState() {
        publishSnapshot()
    }

    public func prepareToOpenRemote(
        selection: RemoteFileSelection,
        mode: RemoteFileOpenMode
    ) -> Bool {
        guard handlesInWorkspace(mode) else {
            return fallbackOpener.prepareToOpenRemote(selection: selection, mode: mode)
        }
        guard isTransitioning == false else { return false }
        let key = requestKey(remotePath: selection.path, mode: mode)
        guard activeOpenRequestIDs[key] == nil else { return false }

        let requestID = UUID()
        activeOpenRequestIDs[key] = requestID
        if currentEditor != nil {
            if case .dockedHidden = state {
                expandDockedEditor()
            }
            return true
        }

        guard case .closed = state, let dockHost else {
            activeOpenRequestIDs[key] = nil
            return false
        }
        let progress = progressFactory(selection, mode)
        progress.onCloseRequested = { [weak self, weak progress] in
            guard let self, let progress else { return }
            self.closeOpeningPlaceholder(requestID: requestID, progress: progress)
        }
        do {
            onWillPresentDockedEditor?(targetSidecarWidth)
            try dockHost.installEditorContent(progress)
            state = .opening(requestID: requestID, progress: progress)
            publishSnapshot()
            return true
        } catch {
            activeOpenRequestIDs[key] = nil
            return false
        }
    }

    public func openLocalCopy(
        at url: URL,
        mode: RemoteFileOpenMode,
        applicationURL: URL?,
        saveHandler: RemoteEditSaveHandler?
    ) {
        guard handlesInWorkspace(mode) else {
            fallbackOpener.openLocalCopy(
                at: url,
                mode: mode,
                applicationURL: applicationURL,
                saveHandler: saveHandler
            )
            return
        }
        if let editor = currentEditor {
            editor.openDocument(localURL: url) { _ in try saveHandler?() }
            if case .dockedHidden = state {
                expandDockedEditor()
            }
            return
        }
        guard case .closed = state, let dockHost else {
            fallbackOpener.openLocalCopy(
                at: url,
                mode: mode,
                applicationURL: applicationURL,
                saveHandler: saveHandler
            )
            return
        }
        let editor = RemoteTextEditorViewController(
            localURL: url,
            onSave: { _ in try saveHandler?() }
        )
        wireEditorCallbacks(editor)
        do {
            onWillPresentDockedEditor?(targetSidecarWidth)
            try dockHost.installEditorContent(editor)
            state = .docked(editor)
            publishSnapshot()
        } catch {
            fallbackOpener.openLocalCopy(
                at: url,
                mode: mode,
                applicationURL: applicationURL,
                saveHandler: saveHandler
            )
        }
    }

    public func openRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        mode: RemoteFileOpenMode,
        saveHandler: ((String) throws -> Void)?
    ) {
        guard handlesInWorkspace(mode) else {
            fallbackOpener.openRemoteDocument(document, mode: mode, saveHandler: saveHandler)
            return
        }
        guard let requestID = consumeActiveRequest(remotePath: document.remotePath, mode: mode) else {
            return
        }
        if let editor = currentEditor {
            editor.openDocument(document, onSaveText: saveHandler)
            if case .dockedHidden = state {
                expandDockedEditor()
            }
            publishSnapshot()
            return
        }
        guard case .opening(let activeID, let progress) = state,
              activeID == requestID,
              let dockHost
        else { return }

        let editor = editorFactory(document, saveHandler)
        wireEditorCallbacks(editor)
        do {
            try dockHost.removeEditorContent(progress)
            do {
                try dockHost.installEditorContent(editor)
            } catch {
                do {
                    try dockHost.installEditorContent(progress)
                    progress.showFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
                    state = .opening(requestID: requestID, progress: progress)
                } catch {
                    state = .closed
                }
                publishSnapshot()
                return
            }
            state = .docked(editor)
            publishSnapshot()
        } catch {
            state = .opening(requestID: requestID, progress: progress)
            publishSnapshot()
        }
    }

    public func remoteOpenDidFail(
        selection: RemoteFileSelection,
        mode: RemoteFileOpenMode,
        message: String
    ) {
        guard handlesInWorkspace(mode) else {
            fallbackOpener.remoteOpenDidFail(selection: selection, mode: mode, message: message)
            return
        }
        guard let requestID = consumeActiveRequest(remotePath: selection.path, mode: mode) else {
            return
        }
        if let editor = currentEditor {
            editor.openFailedDocument(
                remotePath: selection.path,
                fileName: (selection.path as NSString).lastPathComponent,
                message: message,
                byteCount: selection.size
            )
            if case .dockedHidden = state {
                expandDockedEditor()
            }
            publishSnapshot()
            return
        }
        guard case .opening(let activeID, let progress) = state, activeID == requestID else {
            return
        }
        progress.showFailure(message)
        publishSnapshot()
    }

    public func compareLocalCopies(_ urls: [URL], parentWindow: NSWindow?) throws {
        try fallbackOpener.compareLocalCopies(urls, parentWindow: parentWindow)
    }

    public func collapseDockedEditor() {
        guard case .docked(let editor) = state, let dockHost else { return }
        performTransition {
            dockHost.setEditorSidecarCollapsed(true)
            state = .dockedHidden(editor)
        }
    }

    public func expandDockedEditor() {
        guard case .dockedHidden(let editor) = state, let dockHost else { return }
        performTransition {
            dockHost.setEditorSidecarCollapsed(false)
            state = .docked(editor)
            dockHost.synchronizeEditorLayout()
        }
    }

    public func requestAIForActiveDocument() {
        currentEditor?.requestAIForActiveDocument()
    }

    @discardableResult
    public func requestClose(
        parentWindow: NSWindow?,
        completion: ((RemoteTextEditorCloseResolution) -> Void)?
    ) -> RemoteTextEditorCloseDisposition {
        if let completion {
            pendingCloseCompletions.append(completion)
        }
        if pendingCloseEditor != nil {
            return .pending
        }
        switch state {
        case .closed:
            finishCloseCompletions(.ready)
            return .ready
        case .opening(_, let progress):
            guard let dockHost else {
                finishCloseCompletions(.cancelled)
                return .cancelled
            }
            invalidateOpenRequests(for: progress)
            do {
                try dockHost.removeEditorContent(progress)
            } catch {
                finishCloseCompletions(.cancelled)
                return .cancelled
            }
            state = .closed
            publishSnapshot()
            finishCloseCompletions(.ready)
            return .ready
        case .docked(let editor), .dockedHidden(let editor),
             .floating(let editor, _, _, _), .displayMaximized(let editor, _, _, _):
            pendingCloseEditor = editor
            let disposition = editor.requestClose(
                parentWindow: parentWindow,
                closeConfirmer: closeConfirmer
            )
            switch disposition {
            case .ready:
                return finishEditorClose(editor) ? .ready : .cancelled
            case .cancelled:
                pendingCloseEditor = nil
                finishCloseCompletions(.cancelled)
                return .cancelled
            case .pending:
                return .pending
            }
        }
    }

    private var presentationMode: RemoteEditorPresentationMode {
        switch state {
        case .closed: .closed
        case .opening: .opening
        case .docked: .docked
        case .dockedHidden: .dockedHidden
        case .floating: .floating
        case .displayMaximized: .displayMaximized
        }
    }

    private var targetSidecarWidth: CGFloat {
        presentationStore.sidecarTargetWidth()
            ?? WorkbenchCenterContainerViewController.defaultEditorTargetWidth
    }

    private func handlesInWorkspace(_ mode: RemoteFileOpenMode) -> Bool {
        mode == .textEditor || mode == .mediaPreview
    }

    private func requestKey(
        remotePath: String,
        mode: RemoteFileOpenMode
    ) -> OpenRequestKey {
        OpenRequestKey(remotePath: remotePath, modeLogName: mode.logName)
    }

    private func consumeActiveRequest(
        remotePath: String,
        mode: RemoteFileOpenMode
    ) -> UUID? {
        activeOpenRequestIDs.removeValue(
            forKey: requestKey(remotePath: remotePath, mode: mode)
        )
    }

    private func invalidateOpenRequests(for progress: RemoteFileOpenProgressViewController) {
        guard case .opening(let requestID, let currentProgress) = state,
              currentProgress === progress
        else { return }
        activeOpenRequestIDs = activeOpenRequestIDs.filter { $0.value != requestID }
    }

    private func closeOpeningPlaceholder(
        requestID: UUID,
        progress: RemoteFileOpenProgressViewController
    ) {
        guard case .opening(let activeID, let currentProgress) = state,
              activeID == requestID,
              currentProgress === progress
        else { return }
        _ = requestClose(parentWindow: dockHost?.parentWindow, completion: nil)
    }

    private func wireEditorCallbacks(_ editor: RemoteTextEditorViewController) {
        editor.onCloseRequested = { [weak self] in
            guard let self else { return }
            _ = self.requestClose(parentWindow: self.dockHost?.parentWindow, completion: nil)
        }
        editor.onPendingCloseResolved = { [weak self, weak editor] resolution in
            guard let self, let editor, self.pendingCloseEditor === editor else { return }
            switch resolution {
            case .ready:
                _ = self.finishEditorClose(editor)
            case .cancelled:
                self.pendingCloseEditor = nil
                self.finishCloseCompletions(.cancelled)
            }
        }
        editor.onDirtyStateChanged = { [weak self, weak editor] _ in
            guard let self, self.currentEditor === editor else { return }
            self.publishSnapshot()
        }
        editor.onActiveDocumentChanged = { [weak self, weak editor] _, _ in
            guard let self, self.currentEditor === editor else { return }
            self.publishSnapshot()
        }
        editor.onAIQuestionRequested = { [weak self] question in
            self?.onAIQuestionRequested?(question)
        }
    }

    private func finishEditorClose(_ editor: RemoteTextEditorViewController) -> Bool {
        guard pendingCloseEditor === editor || currentEditor === editor else { return false }
        do {
            switch state {
            case .docked, .dockedHidden:
                guard let dockHost else {
                    throw RemoteEditorPresentationError.dockHostUnavailable
                }
                try dockHost.removeEditorContent(editor)
            case .closed, .opening, .floating, .displayMaximized:
                break
            }
        } catch {
            pendingCloseEditor = nil
            finishCloseCompletions(.cancelled)
            return false
        }
        pendingCloseEditor = nil
        state = .closed
        publishSnapshot()
        finishCloseCompletions(.ready)
        return true
    }

    private func finishCloseCompletions(_ resolution: RemoteTextEditorCloseResolution) {
        let completions = pendingCloseCompletions
        pendingCloseCompletions.removeAll()
        completions.forEach { $0(resolution) }
    }

    private func performTransition(_ action: () -> Void) {
        guard isTransitioning == false else { return }
        isTransitioning = true
        publishSnapshot()
        action()
        isTransitioning = false
        publishSnapshot()
    }

    private func publishSnapshot() {
        onSnapshotChanged?(snapshot)
    }
}
