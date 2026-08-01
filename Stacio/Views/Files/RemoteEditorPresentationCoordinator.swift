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
    func detachEditor() throws
    func redockEditor() throws
    func presentEditor(on screen: RemoteEditorScreenIdentity) throws
    func availableScreensDidChange()
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

public typealias RemoteLocalEditorFactory = @MainActor (
    _ localURL: URL,
    _ saveHandler: RemoteEditSaveHandler?
) -> RemoteTextEditorViewController

public typealias RemoteEditorWindowFactory = @MainActor () throws -> RemoteTextEditorWindowController

@MainActor
public final class RemoteEditorPresentationCoordinator:
    RemoteEditorPresentationRouting,
    RemoteTextEditorWindowControllerDelegate
{
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
    private let windowFactory: RemoteEditorWindowFactory
    private let editorFactory: RemoteEditorFactory
    private let localEditorFactory: RemoteLocalEditorFactory
    private let progressFactory: RemoteEditorOpenProgressFactory
    private let notificationCenter: NotificationCenter

    private var state: State = .closed
    private var activeOpenRequestIDs: [OpenRequestKey: UUID] = [:]
    private var activeOpenRequestKeysByID: [UUID: OpenRequestKey] = [:]
    private var isTransitioning = false
    private weak var pendingCloseEditor: RemoteTextEditorViewController?
    private var pendingCloseCompletions: [(RemoteTextEditorCloseResolution) -> Void] = []
    private weak var windowHandlingCloseRequest: RemoteTextEditorWindowController?
    private var screenChangeObserver: NSObjectProtocol?

    public init(
        dockHost: any RemoteEditorDockHosting,
        presentationStore: any RemoteEditorPresentationStoring,
        screenProvider: any RemoteEditorScreenProviding,
        licenseAccess: any LicenseFeatureAccessProviding = UnrestrictedLicenseFeatureAccessProvider(),
        authorizer: any LicensedFeatureAuthorizing = LicenseFeatureAuthorizer(),
        closeConfirmer: (any RemoteTextEditorCloseConfirming)? = nil,
        fallbackOpener: (any RemoteEditOpening)? = nil,
        windowFactory: @escaping RemoteEditorWindowFactory = {
            RemoteTextEditorWindowController()
        },
        editorFactory: @escaping RemoteEditorFactory = { document, saveHandler in
            RemoteTextEditorViewController(document: document, onSaveText: saveHandler)
        },
        localEditorFactory: @escaping RemoteLocalEditorFactory = { localURL, saveHandler in
            RemoteTextEditorViewController(
                localURL: localURL,
                onSave: { _ in try saveHandler?() }
            )
        },
        progressFactory: @escaping RemoteEditorOpenProgressFactory = { selection, mode in
            RemoteFileOpenProgressViewController(selection: selection, mode: mode)
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.dockHost = dockHost
        self.presentationStore = presentationStore
        self.screenProvider = screenProvider
        self.licenseAccess = licenseAccess
        self.authorizer = authorizer
        self.closeConfirmer = closeConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
        self.fallbackOpener = fallbackOpener ?? AppKitRemoteEditOpener()
        self.windowFactory = windowFactory
        self.editorFactory = editorFactory
        self.localEditorFactory = localEditorFactory
        self.progressFactory = progressFactory
        self.notificationCenter = notificationCenter
        screenChangeObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.availableScreensDidChange()
            }
        }
    }

    deinit {
        if let screenChangeObserver {
            notificationCenter.removeObserver(screenChangeObserver)
        }
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
        prepareRemoteOpen(selection: selection, mode: mode) != nil
    }

    public func prepareRemoteOpen(
        selection: RemoteFileSelection,
        mode: RemoteFileOpenMode
    ) -> RemoteEditOpenRequest? {
        guard handlesInWorkspace(mode) else {
            return fallbackOpener.prepareRemoteOpen(selection: selection, mode: mode)
        }
        guard isTransitioning == false, pendingCloseEditor == nil else { return nil }
        let key = requestKey(remotePath: selection.path, mode: mode)
        guard activeOpenRequestIDs[key] == nil else { return nil }

        let request = RemoteEditOpenRequest()
        activeOpenRequestIDs[key] = request.id
        activeOpenRequestKeysByID[request.id] = key
        if currentEditor != nil {
            if case .dockedHidden = state {
                expandDockedEditor()
            }
            return request
        }

        guard case .closed = state, let dockHost else {
            invalidateOpenRequest(request.id)
            return nil
        }
        let progress = progressFactory(selection, mode)
        progress.onCloseRequested = { [weak self, weak progress] in
            guard let self, let progress else { return }
            self.closeOpeningPlaceholder(requestID: request.id, progress: progress)
        }
        do {
            onWillPresentDockedEditor?(targetSidecarWidth)
            try dockHost.installEditorContent(progress)
            state = .opening(requestID: request.id, progress: progress)
            publishSnapshot()
            return request
        } catch {
            invalidateOpenRequest(request.id)
            return nil
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
        guard pendingCloseEditor == nil else { return }
        if case .opening(let requestID, _) = state,
           activeOpenRequestKeysByID[requestID] != nil
        {
            openLocalCopy(
                at: url,
                mode: mode,
                applicationURL: applicationURL,
                saveHandler: saveHandler,
                request: RemoteEditOpenRequest(id: requestID)
            )
            return
        }
        openLocalCopyWithoutPreparedRequest(
            at: url,
            mode: mode,
            applicationURL: applicationURL,
            saveHandler: saveHandler
        )
    }

    public func openLocalCopy(
        at url: URL,
        mode: RemoteFileOpenMode,
        applicationURL: URL?,
        saveHandler: RemoteEditSaveHandler?,
        request: RemoteEditOpenRequest
    ) {
        guard handlesInWorkspace(mode) else {
            fallbackOpener.openLocalCopy(
                at: url,
                mode: mode,
                applicationURL: applicationURL,
                saveHandler: saveHandler,
                request: request
            )
            return
        }
        guard let requestID = consumeActiveRequest(request, mode: mode) else { return }
        guard pendingCloseEditor == nil else { return }
        if let editor = currentEditor {
            editor.openDocument(localURL: url) { _ in try saveHandler?() }
            if case .dockedHidden = state {
                expandDockedEditor()
            }
            publishSnapshot()
            return
        }
        guard case .opening(let activeID, let progress) = state,
              activeID == requestID,
              dockHost != nil
        else { return }
        let editor = localEditorFactory(url, saveHandler)
        wireEditorCallbacks(editor)
        replaceOpeningProgress(progress, requestID: requestID, with: editor)
    }

    private func openLocalCopyWithoutPreparedRequest(
        at url: URL,
        mode: RemoteFileOpenMode,
        applicationURL: URL?,
        saveHandler: RemoteEditSaveHandler?
    ) {
        guard pendingCloseEditor == nil else { return }
        if let editor = currentEditor {
            editor.openDocument(localURL: url) { _ in try saveHandler?() }
            if case .dockedHidden = state {
                expandDockedEditor()
            }
            publishSnapshot()
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
        let editor = localEditorFactory(url, saveHandler)
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
        guard let request = activeRequest(remotePath: document.remotePath, mode: mode) else { return }
        openRemoteDocument(document, mode: mode, saveHandler: saveHandler, request: request)
    }

    public func openRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        mode: RemoteFileOpenMode,
        saveHandler: ((String) throws -> Void)?,
        request: RemoteEditOpenRequest
    ) {
        guard handlesInWorkspace(mode) else {
            fallbackOpener.openRemoteDocument(
                document,
                mode: mode,
                saveHandler: saveHandler,
                request: request
            )
            return
        }
        guard let requestID = consumeActiveRequest(
            request,
            expectedKey: requestKey(remotePath: document.remotePath, mode: mode)
        ) else { return }
        guard pendingCloseEditor == nil else { return }
        if let editor = currentEditor {
            editor.openDocument(document, onSaveText: saveHandler)
            if case .dockedHidden = state {
                expandDockedEditor()
            }
            publishSnapshot()
            return
        }
        guard case .opening(let activeID, let progress) = state,
              activeID == requestID
        else { return }

        let editor = editorFactory(document, saveHandler)
        wireEditorCallbacks(editor)
        replaceOpeningProgress(progress, requestID: requestID, with: editor)
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
        guard let request = activeRequest(remotePath: selection.path, mode: mode) else { return }
        remoteOpenDidFail(selection: selection, mode: mode, message: message, request: request)
    }

    public func remoteOpenDidFail(
        selection: RemoteFileSelection,
        mode: RemoteFileOpenMode,
        message: String,
        request: RemoteEditOpenRequest
    ) {
        guard handlesInWorkspace(mode) else {
            fallbackOpener.remoteOpenDidFail(
                selection: selection,
                mode: mode,
                message: message,
                request: request
            )
            return
        }
        guard let requestID = consumeActiveRequest(
            request,
            expectedKey: requestKey(remotePath: selection.path, mode: mode)
        ) else { return }
        guard pendingCloseEditor == nil else { return }
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

    public func detachEditor() throws {
        guard isTransitioning == false else {
            throw RemoteEditorPresentationError.transitionInProgress
        }
        switch state {
        case .docked, .dockedHidden:
            break
        case .closed, .opening, .floating, .displayMaximized:
            throw RemoteEditorPresentationError.invalidTransition
        }

        try authorizer.authorize(.detachedFileEditor)
        try performThrowingTransition {
            let editor: RemoteTextEditorViewController
            let sourceState = state
            switch sourceState {
            case .docked(let current), .dockedHidden(let current):
                editor = current
            case .closed, .opening, .floating, .displayMaximized:
                throw RemoteEditorPresentationError.invalidTransition
            }
            let screens = screenProvider.availableScreens()
            guard let screen = preferredFloatingScreen(from: screens) else {
                throw RemoteEditorPresentationError.screenUnavailable
            }
            let frame = resolvedFloatingFrame(on: screen)
            let windowController = try makeEditorWindow()
            try moveDockedEditorToWindow(
                editor: editor,
                sourceState: sourceState,
                windowController: windowController,
                frame: frame,
                floatingScreen: screen,
                displayScreen: nil,
                restoreFrame: nil
            )
        }
    }

    public func redockEditor() throws {
        guard isTransitioning == false else {
            throw RemoteEditorPresentationError.transitionInProgress
        }
        guard let dockHost else {
            throw RemoteEditorPresentationError.dockHostUnavailable
        }

        let editor: RemoteTextEditorViewController
        let windowController: RemoteTextEditorWindowController
        let sourceState = state
        let sourceFrame: NSRect
        switch sourceState {
        case .floating(let currentEditor, let currentWindow, let frame, _):
            editor = currentEditor
            windowController = currentWindow
            sourceFrame = currentWindow.window?.frame ?? frame
        case .displayMaximized(let currentEditor, let currentWindow, _, _):
            editor = currentEditor
            windowController = currentWindow
            sourceFrame = currentWindow.window?.frame ?? .zero
        case .closed, .opening, .docked, .dockedHidden:
            throw RemoteEditorPresentationError.invalidTransition
        }

        let wasVisible = windowController.window?.isVisible == true
        try performThrowingTransition {
            do {
                onWillPresentDockedEditor?(targetSidecarWidth)
                try windowController.removeEditorForMigration(editor)
                do {
                    try dockHost.installEditorContent(editor)
                } catch {
                    try windowController.installEditor(editor)
                    windowController.presentationDelegate = self
                    windowController.applyProgrammaticFrame(sourceFrame, display: false)
                    if wasVisible {
                        windowController.showWindow(nil)
                        windowController.window?.makeKeyAndOrderFront(nil)
                    }
                    state = sourceState
                    throw error
                }
                dockHost.setEditorSidecarCollapsed(false)
                if case .floating = sourceState {
                    presentationStore.saveFloatingFrame(sourceFrame)
                }
                state = .docked(editor)
                windowController.presentationDelegate = nil
                windowController.closeShellForRedock()
                dockHost.synchronizeEditorLayout()
                editor.synchronizeLayoutAfterContainerChange()
            } catch {
                state = sourceState
                throw error
            }
        }
    }

    public func presentEditor(on screenIdentity: RemoteEditorScreenIdentity) throws {
        guard isTransitioning == false else {
            throw RemoteEditorPresentationError.transitionInProgress
        }
        switch state {
        case .docked, .dockedHidden, .floating, .displayMaximized:
            break
        case .closed, .opening:
            throw RemoteEditorPresentationError.invalidTransition
        }

        try authorizer.authorize(.detachedFileEditor)
        try performThrowingTransition {
            let screens = screenProvider.availableScreens()
            guard let target = RemoteEditorScreenResolver.resolve(screenIdentity, screens: screens) else {
                throw RemoteEditorPresentationError.screenUnavailable
            }

            switch state {
            case .docked(let editor), .dockedHidden(let editor):
                let sourceState = state
                let restoreFrame = presentationStore.floatingFrame()
                    ?? resolvedFloatingFrame(on: preferredFloatingScreen(from: screens) ?? target)
                let windowController = try makeEditorWindow()
                try moveDockedEditorToWindow(
                    editor: editor,
                    sourceState: sourceState,
                    windowController: windowController,
                    frame: target.visibleFrame,
                    floatingScreen: nil,
                    displayScreen: target,
                    restoreFrame: restoreFrame
                )
            case .floating(let editor, let windowController, let normalFrame, _):
                presentationStore.saveFloatingFrame(normalFrame)
                windowController.applyProgrammaticFrame(target.visibleFrame, display: true)
                state = .displayMaximized(
                    editor,
                    windowController,
                    target.identity,
                    normalFrame
                )
                presentationStore.saveScreenIdentity(target.identity)
                editor.synchronizeLayoutAfterContainerChange()
            case .displayMaximized(let editor, let windowController, _, let restoreFrame):
                windowController.applyProgrammaticFrame(target.visibleFrame, display: true)
                state = .displayMaximized(
                    editor,
                    windowController,
                    target.identity,
                    restoreFrame
                )
                presentationStore.saveScreenIdentity(target.identity)
                editor.synchronizeLayoutAfterContainerChange()
            case .closed, .opening:
                throw RemoteEditorPresentationError.invalidTransition
            }
        }
    }

    public func availableScreensDidChange() {
        guard isTransitioning == false else { return }
        let screens = screenProvider.availableScreens()
        guard screens.isEmpty == false else { return }

        switch state {
        case .floating(let editor, let windowController, let frame, let identity):
            guard windowController.isInNativeFullScreen == false else { return }
            guard screens.contains(where: { intersects(frame, $0.visibleFrame) }) == false else {
                return
            }
            guard let fallback = resolvedScreen(identity, from: screens)
                ?? workbenchScreen(from: screens)
                ?? screens.first
            else { return }
            let clamped = RemoteEditorScreenResolver.clamp(
                frame,
                to: fallback.visibleFrame,
                minimumSize: RemoteTextEditorWindowController.minimumFrameSize
            )
            windowController.applyProgrammaticFrame(clamped, display: true)
            state = .floating(editor, windowController, clamped, fallback.identity)
            presentationStore.saveFloatingFrame(clamped)
            presentationStore.saveScreenIdentity(fallback.identity)
            editor.synchronizeLayoutAfterContainerChange()
            publishSnapshot()
        case .displayMaximized(
            let editor,
            let windowController,
            let identity,
            let restoreFrame
        ):
            guard windowController.isInNativeFullScreen == false else { return }
            guard let target = resolvedScreen(identity, from: screens)
                ?? workbenchScreen(from: screens)
                ?? screens.first
            else { return }
            windowController.applyProgrammaticFrame(target.visibleFrame, display: true)
            state = .displayMaximized(
                editor,
                windowController,
                target.identity,
                restoreFrame
            )
            presentationStore.saveScreenIdentity(target.identity)
            editor.synchronizeLayoutAfterContainerChange()
            publishSnapshot()
        case .closed, .opening, .docked, .dockedHidden:
            break
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
        guard isTransitioning == false else {
            completion?(.cancelled)
            return .cancelled
        }
        if let completion {
            pendingCloseCompletions.append(completion)
        }
        if pendingCloseEditor != nil {
            return .pending
        }
        switch state {
        case .closed:
            invalidateAllOpenRequests()
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

    public func remoteTextEditorWindowShouldClose(
        _ controller: RemoteTextEditorWindowController
    ) -> Bool {
        windowHandlingCloseRequest = controller
        defer { windowHandlingCloseRequest = nil }
        return requestClose(parentWindow: controller.window, completion: nil) == .ready
    }

    public func remoteTextEditorWindowDidClose(
        _ controller: RemoteTextEditorWindowController,
        forRedock: Bool
    ) {
        guard forRedock == false else { return }
        let editor: RemoteTextEditorViewController
        switch state {
        case .floating(let currentEditor, let currentWindow, _, _),
             .displayMaximized(let currentEditor, let currentWindow, _, _):
            guard currentWindow === controller else { return }
            editor = currentEditor
        case .closed, .opening, .docked, .dockedHidden:
            return
        }
        if controller.installedEditorViewController === editor {
            try? controller.removeEditorForMigration(editor)
        }
        pendingCloseEditor = nil
        invalidateAllOpenRequests()
        state = .closed
        publishSnapshot()
        finishCloseCompletions(.ready)
    }

    public func remoteTextEditorWindowDidChangeFrame(
        _ controller: RemoteTextEditorWindowController,
        frame: NSRect,
        userInitiated: Bool
    ) {
        guard userInitiated,
              isTransitioning == false,
              controller.isInNativeFullScreen == false
        else { return }
        let screens = screenProvider.availableScreens()
        let screen = screen(containing: frame, in: screens)
            ?? workbenchScreen(from: screens)
            ?? screens.first

        switch state {
        case .floating(let editor, let currentWindow, _, _):
            guard currentWindow === controller else { return }
            state = .floating(editor, controller, frame, screen?.identity)
            presentationStore.saveFloatingFrame(frame)
            presentationStore.saveScreenIdentity(screen?.identity)
            publishSnapshot()
        case .displayMaximized(let editor, let currentWindow, _, _):
            guard currentWindow === controller else { return }
            state = .floating(editor, controller, frame, screen?.identity)
            presentationStore.saveFloatingFrame(frame)
            presentationStore.saveScreenIdentity(screen?.identity)
            publishSnapshot()
        case .closed, .opening, .docked, .dockedHidden:
            break
        }
    }

    public func remoteTextEditorWindowWillEnterFullScreen(
        _ controller: RemoteTextEditorWindowController
    ) {}

    public func remoteTextEditorWindowDidExitFullScreen(
        _ controller: RemoteTextEditorWindowController
    ) {
        guard isTransitioning == false else { return }
        let screens = screenProvider.availableScreens()
        switch state {
        case .floating(let editor, let currentWindow, let frame, let identity):
            guard currentWindow === controller else { return }
            guard let target = resolvedScreen(identity, from: screens)
                ?? workbenchScreen(from: screens)
                ?? screens.first
            else { return }
            let clamped = RemoteEditorScreenResolver.clamp(
                frame,
                to: target.visibleFrame,
                minimumSize: RemoteTextEditorWindowController.minimumFrameSize
            )
            controller.applyProgrammaticFrame(clamped, display: true)
            state = .floating(editor, controller, clamped, target.identity)
            presentationStore.saveFloatingFrame(clamped)
            presentationStore.saveScreenIdentity(target.identity)
            editor.synchronizeLayoutAfterContainerChange()
            publishSnapshot()
        case .displayMaximized(
            let editor,
            let currentWindow,
            let identity,
            let restoreFrame
        ):
            guard currentWindow === controller else { return }
            guard let target = resolvedScreen(identity, from: screens)
                ?? workbenchScreen(from: screens)
                ?? screens.first
            else { return }
            controller.applyProgrammaticFrame(target.visibleFrame, display: true)
            state = .displayMaximized(
                editor,
                controller,
                target.identity,
                restoreFrame
            )
            presentationStore.saveScreenIdentity(target.identity)
            editor.synchronizeLayoutAfterContainerChange()
            publishSnapshot()
        case .closed, .opening, .docked, .dockedHidden:
            break
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

    private func makeEditorWindow() throws -> RemoteTextEditorWindowController {
        do {
            return try windowFactory()
        } catch {
            throw RemoteEditorPresentationError.windowCreationFailed
        }
    }

    private func moveDockedEditorToWindow(
        editor: RemoteTextEditorViewController,
        sourceState: State,
        windowController: RemoteTextEditorWindowController,
        frame: NSRect,
        floatingScreen: RemoteEditorScreenDescriptor?,
        displayScreen: RemoteEditorScreenDescriptor?,
        restoreFrame: NSRect?
    ) throws {
        guard let dockHost else {
            throw RemoteEditorPresentationError.dockHostUnavailable
        }
        let sourceWasHidden = dockHost.isEditorSidecarCollapsed
        var removedFromDock = false

        func destinationState() -> State {
            if let displayScreen {
                return .displayMaximized(
                    editor,
                    windowController,
                    displayScreen.identity,
                    restoreFrame
                )
            }
            return .floating(
                editor,
                windowController,
                frame,
                floatingScreen?.identity
            )
        }

        do {
            try windowController.validateEmptyShellForMigration()
            try dockHost.removeEditorContent(editor)
            removedFromDock = true
            try windowController.installEditor(editor)
            windowController.presentationDelegate = self
            windowController.applyProgrammaticFrame(frame, display: displayScreen != nil)
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
            dockHost.setEditorSidecarCollapsed(true)
            state = destinationState()
            if let displayScreen {
                if let restoreFrame {
                    presentationStore.saveFloatingFrame(restoreFrame)
                }
                presentationStore.saveScreenIdentity(displayScreen.identity)
            } else {
                presentationStore.saveFloatingFrame(frame)
                presentationStore.saveScreenIdentity(floatingScreen?.identity)
            }
            updateWindowPresentation(for: editor)
            editor.synchronizeLayoutAfterContainerChange()
        } catch let transitionError {
            if windowController.installedEditorViewController === editor {
                try? windowController.removeEditorForMigration(editor)
            }
            guard removedFromDock else {
                state = sourceState
                windowController.presentationDelegate = nil
                windowController.closeShellForRedock()
                throw transitionError
            }
            do {
                try dockHost.installEditorContent(editor)
                dockHost.setEditorSidecarCollapsed(sourceWasHidden)
                state = sourceState
                windowController.presentationDelegate = nil
                windowController.closeShellForRedock()
            } catch {
                if let occupant = windowController.installedEditorViewController,
                   occupant !== editor
                {
                    try? windowController.removeEditorForMigration(occupant)
                }
                try? windowController.installEditor(editor)
                windowController.presentationDelegate = self
                windowController.applyProgrammaticFrame(frame, display: false)
                windowController.showWindow(nil)
                windowController.window?.makeKeyAndOrderFront(nil)
                state = destinationState()
            }
            throw transitionError
        }
    }

    private func resolvedFloatingFrame(on screen: RemoteEditorScreenDescriptor) -> NSRect {
        let requested: NSRect
        if let saved = presentationStore.floatingFrame() {
            requested = saved
        } else {
            let frameSize = RemoteTextEditorWindowController.initialFrameSize
            requested = NSRect(
                x: screen.visibleFrame.midX - (frameSize.width / 2),
                y: screen.visibleFrame.midY - (frameSize.height / 2),
                width: frameSize.width,
                height: frameSize.height
            )
        }
        return RemoteEditorScreenResolver.clamp(
            requested,
            to: screen.visibleFrame,
            minimumSize: RemoteTextEditorWindowController.minimumFrameSize
        )
    }

    private func preferredFloatingScreen(
        from screens: [RemoteEditorScreenDescriptor]
    ) -> RemoteEditorScreenDescriptor? {
        resolvedScreen(presentationStore.screenIdentity(), from: screens)
            ?? workbenchScreen(from: screens)
            ?? screens.first
    }

    private func workbenchScreen(
        from screens: [RemoteEditorScreenDescriptor]
    ) -> RemoteEditorScreenDescriptor? {
        guard let descriptor = screenProvider.descriptor(containing: dockHost?.parentWindow) else {
            return nil
        }
        return resolvedScreen(descriptor.identity, from: screens)
            ?? screens.first(where: { $0 == descriptor })
    }

    private func resolvedScreen(
        _ identity: RemoteEditorScreenIdentity?,
        from screens: [RemoteEditorScreenDescriptor]
    ) -> RemoteEditorScreenDescriptor? {
        RemoteEditorScreenResolver.resolve(identity, screens: screens)
    }

    private func screen(
        containing frame: NSRect,
        in screens: [RemoteEditorScreenDescriptor]
    ) -> RemoteEditorScreenDescriptor? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let containing = screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }
        return screens.max { lhs, rhs in
            intersectionArea(frame, lhs.visibleFrame) < intersectionArea(frame, rhs.visibleFrame)
        }
    }

    private func intersects(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        intersectionArea(lhs, rhs) > 0
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard intersection.isNull == false else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
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

    private func activeRequest(
        remotePath: String,
        mode: RemoteFileOpenMode
    ) -> RemoteEditOpenRequest? {
        let key = requestKey(remotePath: remotePath, mode: mode)
        guard let requestID = activeOpenRequestIDs[key] else { return nil }
        return RemoteEditOpenRequest(id: requestID)
    }

    private func consumeActiveRequest(
        _ request: RemoteEditOpenRequest,
        mode: RemoteFileOpenMode
    ) -> UUID? {
        guard let key = activeOpenRequestKeysByID[request.id], key.modeLogName == mode.logName else {
            return nil
        }
        return consumeActiveRequest(request, expectedKey: key)
    }

    private func consumeActiveRequest(
        _ request: RemoteEditOpenRequest,
        expectedKey: OpenRequestKey
    ) -> UUID? {
        guard activeOpenRequestKeysByID[request.id] == expectedKey,
              activeOpenRequestIDs[expectedKey] == request.id
        else { return nil }
        activeOpenRequestKeysByID[request.id] = nil
        activeOpenRequestIDs[expectedKey] = nil
        return request.id
    }

    private func invalidateOpenRequest(_ requestID: UUID) {
        guard let key = activeOpenRequestKeysByID.removeValue(forKey: requestID) else { return }
        if activeOpenRequestIDs[key] == requestID {
            activeOpenRequestIDs[key] = nil
        }
    }

    private func invalidateAllOpenRequests() {
        activeOpenRequestIDs.removeAll()
        activeOpenRequestKeysByID.removeAll()
    }

    private func invalidateOpenRequests(for progress: RemoteFileOpenProgressViewController) {
        guard case .opening(let requestID, let currentProgress) = state,
              currentProgress === progress
        else { return }
        invalidateOpenRequest(requestID)
    }

    private func replaceOpeningProgress(
        _ progress: RemoteFileOpenProgressViewController,
        requestID: UUID,
        with editor: RemoteTextEditorViewController
    ) {
        guard let dockHost else { return }
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
            _ = self.requestClose(
                parentWindow: self.parentWindow(for: editor),
                completion: nil
            )
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
            if let editor {
                self.updateWindowPresentation(for: editor)
            }
            self.publishSnapshot()
        }
        editor.onActiveDocumentChanged = { [weak self, weak editor] _, _ in
            guard let self, self.currentEditor === editor else { return }
            if let editor {
                self.updateWindowPresentation(for: editor)
            }
            self.publishSnapshot()
        }
        editor.onAIQuestionRequested = { [weak self] question in
            self?.onAIQuestionRequested?(question)
        }
    }

    private func finishEditorClose(_ editor: RemoteTextEditorViewController) -> Bool {
        guard pendingCloseEditor === editor || currentEditor === editor else { return false }
        var detachedWindow: RemoteTextEditorWindowController?
        do {
            switch state {
            case .docked, .dockedHidden:
                guard let dockHost else {
                    throw RemoteEditorPresentationError.dockHostUnavailable
                }
                try dockHost.removeEditorContent(editor)
            case .floating(_, let windowController, _, _),
                 .displayMaximized(_, let windowController, _, _):
                try windowController.removeEditorForMigration(editor)
                detachedWindow = windowController
            case .closed, .opening:
                break
            }
        } catch {
            pendingCloseEditor = nil
            finishCloseCompletions(.cancelled)
            return false
        }
        pendingCloseEditor = nil
        invalidateAllOpenRequests()
        state = .closed
        publishSnapshot()
        finishCloseCompletions(.ready)
        if let detachedWindow,
           windowHandlingCloseRequest !== detachedWindow
        {
            detachedWindow.completeDeferredUserClose()
        }
        return true
    }

    private func parentWindow(for editor: RemoteTextEditorViewController) -> NSWindow? {
        switch state {
        case .floating(let current, let windowController, _, _):
            return current === editor ? windowController.window : dockHost?.parentWindow
        case .displayMaximized(let current, let windowController, _, _):
            return current === editor ? windowController.window : dockHost?.parentWindow
        case .closed, .opening, .docked, .dockedHidden:
            return dockHost?.parentWindow
        }
    }

    private func updateWindowPresentation(for editor: RemoteTextEditorViewController) {
        let windowController: RemoteTextEditorWindowController?
        switch state {
        case .floating(let current, let window, _, _):
            windowController = current === editor ? window : nil
        case .displayMaximized(let current, let window, _, _):
            windowController = current === editor ? window : nil
        case .closed, .opening, .docked, .dockedHidden:
            windowController = nil
        }
        windowController?.updateDocumentPresentation(
            fileName: editor.activeFileNameForTesting,
            isDirty: editor.hasUnsavedChangesForTesting
        )
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

    private func performThrowingTransition(_ action: () throws -> Void) throws {
        guard isTransitioning == false else {
            throw RemoteEditorPresentationError.transitionInProgress
        }
        isTransitioning = true
        publishSnapshot()
        defer {
            isTransitioning = false
            publishSnapshot()
        }
        try action()
    }

    private func publishSnapshot() {
        onSnapshotChanged?(snapshot)
    }
}
