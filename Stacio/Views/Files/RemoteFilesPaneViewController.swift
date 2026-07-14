import AppKit

public final class RemoteFilesPaneViewController: NSViewController {
    private enum RightWorkspaceLayout {
        static let storedCapabilityWidthKey = "Stacio.RemoteFiles.rightCapabilityWidth"
        static let userSetCapabilityWidthKey = "Stacio.RemoteFiles.rightCapabilityWidth.userSet"
        static let minimumFilesWidth: CGFloat = 240
        static let minimumCapabilityWidth: CGFloat = 420
        static let preferredCapabilityWidth: CGFloat = 680
        static let defaultCapabilityWidthFraction: CGFloat = 0.72
    }

    public let runtimeID: String
    public let context: TunnelLiveSessionContext?
    public let ftpContext: FTPLiveSessionContext?
    public private(set) var initialLoadError: Error?
    public var currentRemotePath: String {
        guard isViewLoaded else { return initialRemotePath }
        return filesViewController.currentRemotePath
    }

    private let filesViewController = FilesViewController()
    private let workspaceSplitView = NSSplitView()
    private let bridge: RemoteFilesBridging
    private var transferScheduler: SCPTransferScheduling?
    private var ftpTransferScheduler: FTPTransferScheduling?
    private let rightCapabilityWidthDefaults: UserDefaults
    private let initialRemotePath: String
    private let remoteFilePathTerminalSender: (String) -> Void
    public var onAIQuestionRequested: ((String) -> Void)?
    private var filesCoordinator: FilesCoordinator?
    private var rightCapabilityViewController: NSViewController?
    private var textEditorViewController: RemoteTextEditorViewController?
    private var mediaPreviewViewController: RemoteMediaPreviewViewController?
    private var openProgressViewController: RemoteFileOpenProgressViewController?
    private var rightCapabilityCloseConfirmer: RemoteTextEditorCloseConfirming?
    private var rightCapabilityWidthConstraints: [NSLayoutConstraint] = []
    private var rightFilesMinimumWidthConstraint: NSLayoutConstraint?
    private var rightFilesCurrentWidthConstraint: NSLayoutConstraint?
    private var rightFilesWidthBeforeCollapse: CGFloat?
    private var needsInitialCapabilitySplitPosition = false
    private var isApplyingProgrammaticCapabilitySplitPosition = false
    private var rightWorkspaceOpenRequestIDs: Set<UUID> = []

    public init(
        runtimeID: String,
        context: TunnelLiveSessionContext,
        title: String,
        bridge: RemoteFilesBridging,
        transferScheduler: SCPTransferScheduling?,
        initialRemotePath: String = "~",
        rightCapabilityWidthDefaults: UserDefaults = .standard,
        remoteFilePathTerminalSender: @escaping (String) -> Void = { _ in }
    ) {
        self.runtimeID = runtimeID
        self.context = context
        self.ftpContext = nil
        self.bridge = bridge
        self.transferScheduler = transferScheduler
        self.ftpTransferScheduler = nil
        self.rightCapabilityWidthDefaults = rightCapabilityWidthDefaults
        self.initialRemotePath = Self.normalizedInitialRemotePath(initialRemotePath)
        self.remoteFilePathTerminalSender = remoteFilePathTerminalSender
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    public init(
        runtimeID: String,
        ftpContext: FTPLiveSessionContext,
        title: String,
        bridge: RemoteFilesBridging,
        ftpTransferScheduler: FTPTransferScheduling? = nil,
        rightCapabilityWidthDefaults: UserDefaults = .standard,
        remoteFilePathTerminalSender: @escaping (String) -> Void = { _ in }
    ) {
        self.runtimeID = runtimeID
        self.context = nil
        self.ftpContext = ftpContext
        self.bridge = bridge
        self.transferScheduler = nil
        self.ftpTransferScheduler = ftpTransferScheduler
        self.rightCapabilityWidthDefaults = rightCapabilityWidthDefaults
        self.initialRemotePath = "~"
        self.remoteFilePathTerminalSender = remoteFilePathTerminalSender
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = RemoteFilesShortcutRootView()
        container.onToggleFilesSidebar = { [weak self] in
            self?.toggleFilesSidebar()
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(container)

        workspaceSplitView.isVertical = true
        workspaceSplitView.dividerStyle = .thin
        workspaceSplitView.translatesAutoresizingMaskIntoConstraints = false
        workspaceSplitView.setAccessibilityIdentifier("Stacio.RemoteFiles.workspaceSplit")
        workspaceSplitView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceSplitView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        workspaceSplitView.delegate = self

        addChild(filesViewController)
        filesViewController.view.translatesAutoresizingMaskIntoConstraints = false
        filesViewController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filesViewController.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if ftpContext != nil {
            filesViewController.setEngineSummary(L10n.Files.ftpEngine)
        }
        filesViewController.onSendPathToTerminal = { [remoteFilePathTerminalSender] path in
            remoteFilePathTerminalSender(path)
        }
        container.addSubview(workspaceSplitView)
        workspaceSplitView.addArrangedSubview(filesViewController.view)
        NSLayoutConstraint.activate([
            workspaceSplitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            workspaceSplitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            workspaceSplitView.topAnchor.constraint(equalTo: container.topAnchor),
            workspaceSplitView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let coordinator = FilesCoordinator(
            bridge: bridge,
            filesViewController: filesViewController,
            liveSessionContextProvider: { [context] in context },
            liveSessionRuntimeIDProvider: { [runtimeID] in runtimeID },
            ftpSessionContextProvider: { [ftpContext] in ftpContext },
            transferScheduler: transferScheduler,
            ftpTransferScheduler: ftpTransferScheduler,
            remoteEditOpener: RemoteFilesPaneRemoteEditOpener(filesPane: self),
            remoteEditSessionIDProvider: { [runtimeID] in runtimeID }
        )
        filesCoordinator = coordinator
        view = container

        do {
            filesViewController.setCurrentRemotePath(initialRemotePath)
            try coordinator.loadCurrentLiveDirectory(remotePath: initialRemotePath)
        } catch {
            initialLoadError = error
            coordinator.showInitialLoadError(error)
        }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialCapabilitySplitPositionIfNeeded()
    }

    public var visibleTextSnapshotForTesting: String {
        filesViewController.visibleTextSnapshot
    }

    public var filesViewControllerForTesting: FilesViewController {
        filesViewController
    }

    public func closeRemoteFilesRuntime() {
        _ = transferScheduler?.disconnectTransfers(runtimeID: runtimeID)
        _ = ftpTransferScheduler?.disconnectTransfers(runtimeID: runtimeID)
        clearTransientOpenProgress()
    }

    public var textEditorViewControllerForTesting: RemoteTextEditorViewController? {
        textEditorViewController
    }

    public var mediaPreviewViewControllerForTesting: RemoteMediaPreviewViewController? {
        mediaPreviewViewController
    }

    public func presentTextEditorForTesting(
        localURL: URL,
        saveHandler: RemoteEditSaveHandler?,
        closeConfirmer: RemoteTextEditorCloseConfirming? = nil
    ) {
        presentTextEditor(localURL: localURL, saveHandler: saveHandler, closeConfirmer: closeConfirmer)
    }

    public func presentMediaPreviewForTesting(localURL: URL) {
        presentMediaPreview(localURL: localURL)
    }

    public var openProgressViewControllerForTesting: RemoteFileOpenProgressViewController? {
        openProgressViewController
    }

    @discardableResult
    public func closeRightWorkspaceForTesting() -> Bool {
        closeRightWorkspaceIfNeeded()
    }

    public func toggleFilesSidebarForTesting() {
        toggleFilesSidebar()
    }

    func presentTextEditor(
        localURL: URL,
        saveHandler: RemoteEditSaveHandler?,
        closeConfirmer: RemoteTextEditorCloseConfirming? = nil
    ) {
        if isViewLoaded == false {
            loadView()
        }
        if let textEditorViewController,
           mediaPreviewViewController == nil
        {
            textEditorViewController.openDocument(localURL: localURL) { _ in
                try saveHandler?()
            }
            return
        }
        if openProgressViewController != nil,
           textEditorViewController == nil,
           mediaPreviewViewController == nil
        {
            removeOpenProgressForReplacement()
        } else {
            guard closeRightWorkspaceIfNeeded() else {
                return
            }
        }

        let editor = RemoteTextEditorViewController(localURL: localURL) { _ in
            try saveHandler?()
        }
        rightCapabilityCloseConfirmer = closeConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
        editor.onCloseRequested = { [weak self] in
            _ = self?.closeRightWorkspaceIfNeeded()
        }
        editor.onAIQuestionRequested = { [weak self] question in
            self?.onAIQuestionRequested?(question)
        }
        textEditorViewController = editor
        mediaPreviewViewController = nil
        openProgressViewController = nil
        presentRightCapability(editor)
    }

    func presentRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        onSaveText: ((String) throws -> Void)? = nil,
        closeConfirmer: RemoteTextEditorCloseConfirming? = nil
    ) {
        if isViewLoaded == false {
            loadView()
        }
        if let textEditorViewController,
           mediaPreviewViewController == nil
        {
            textEditorViewController.openDocument(document, onSaveText: onSaveText)
            return
        }
        if openProgressViewController != nil,
           textEditorViewController == nil,
           mediaPreviewViewController == nil
        {
            removeOpenProgressForReplacement()
        } else {
            guard closeRightWorkspaceIfNeeded() else {
                return
            }
        }

        let editor = RemoteTextEditorViewController(document: document, onSaveText: onSaveText)
        rightCapabilityCloseConfirmer = closeConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
        editor.onCloseRequested = { [weak self] in
            _ = self?.closeRightWorkspaceIfNeeded()
        }
        editor.onAIQuestionRequested = { [weak self] question in
            self?.onAIQuestionRequested?(question)
        }
        textEditorViewController = editor
        mediaPreviewViewController = nil
        openProgressViewController = nil
        presentRightCapability(editor)
    }

    func presentMediaPreview(localURL: URL) {
        presentTextEditor(localURL: localURL, saveHandler: nil)
    }

    @discardableResult
    func presentOpenProgress(selection: RemoteFileSelection, mode: RemoteFileOpenMode) -> Bool {
        if isViewLoaded == false {
            loadView()
        }
        if openProgressViewController != nil,
           textEditorViewController == nil,
           mediaPreviewViewController == nil
        {
            removeOpenProgressForReplacement()
        } else {
            guard closeRightWorkspaceIfNeeded() else {
                return false
            }
        }

        let progress = RemoteFileOpenProgressViewController(selection: selection, mode: mode)
        progress.onCloseRequested = { [weak self] in
            _ = self?.closeRightWorkspaceIfNeeded()
        }
        textEditorViewController = nil
        mediaPreviewViewController = nil
        openProgressViewController = progress
        rightCapabilityCloseConfirmer = nil
        presentRightCapability(progress)
        return true
    }

    func presentOpenFailure(selection: RemoteFileSelection, mode: RemoteFileOpenMode, message: String) {
        if isViewLoaded == false {
            loadView()
        }
        if let progress = openProgressViewController {
            progress.showFailure(message)
            return
        }
        guard closeRightWorkspaceIfNeeded() else {
            return
        }

        let progress = RemoteFileOpenProgressViewController(selection: selection, mode: mode)
        progress.showFailure(message)
        progress.onCloseRequested = { [weak self] in
            _ = self?.closeRightWorkspaceIfNeeded()
        }
        textEditorViewController = nil
        mediaPreviewViewController = nil
        openProgressViewController = progress
        rightCapabilityCloseConfirmer = nil
        presentRightCapability(progress)
    }

    func clearTransientOpenProgress() {
        guard openProgressViewController != nil else {
            return
        }
        _ = closeRightWorkspaceIfNeeded()
    }

    func beginRightWorkspaceOpenRequest(selection: RemoteFileSelection, mode: RemoteFileOpenMode) -> UUID? {
        guard presentOpenProgress(selection: selection, mode: mode) else {
            return nil
        }
        let requestID = UUID()
        rightWorkspaceOpenRequestIDs.insert(requestID)
        return requestID
    }

    func isRightWorkspaceOpenRequestActive(_ requestID: UUID?) -> Bool {
        guard let requestID else {
            return false
        }
        return rightWorkspaceOpenRequestIDs.contains(requestID)
    }

    func finishRightWorkspaceOpenRequest(_ requestID: UUID?) {
        guard let requestID else {
            return
        }
        rightWorkspaceOpenRequestIDs.remove(requestID)
    }

    @discardableResult
    private func closeRightWorkspaceIfNeeded() -> Bool {
        if let editor = textEditorViewController {
            let confirmer = rightCapabilityCloseConfirmer ?? AppKitRemoteTextEditorCloseConfirmer()
            guard editor.canClose(parentWindow: view.window, closeConfirmer: confirmer) else {
                return false
            }
        }

        NSLayoutConstraint.deactivate(rightCapabilityWidthConstraints)
        rightCapabilityWidthConstraints = []
        rightFilesMinimumWidthConstraint = nil
        rightFilesCurrentWidthConstraint = nil
        rightFilesWidthBeforeCollapse = nil
        needsInitialCapabilitySplitPosition = false
        filesViewController.view.isHidden = false
        if let controller = rightCapabilityViewController {
            workspaceSplitView.removeArrangedSubview(controller.view)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        rightCapabilityViewController = nil
        textEditorViewController = nil
        mediaPreviewViewController = nil
        openProgressViewController = nil
        rightCapabilityCloseConfirmer = nil
        rightWorkspaceOpenRequestIDs.removeAll()
        view.layoutSubtreeIfNeeded()
        return true
    }

    private func removeOpenProgressForReplacement() {
        guard let progress = openProgressViewController else {
            return
        }
        NSLayoutConstraint.deactivate(rightCapabilityWidthConstraints)
        rightCapabilityWidthConstraints = []
        rightFilesMinimumWidthConstraint = nil
        rightFilesCurrentWidthConstraint = nil
        rightFilesWidthBeforeCollapse = nil
        needsInitialCapabilitySplitPosition = false
        filesViewController.view.isHidden = false
        if workspaceSplitView.arrangedSubviews.contains(progress.view) {
            workspaceSplitView.removeArrangedSubview(progress.view)
        }
        progress.view.removeFromSuperview()
        progress.removeFromParent()
        if rightCapabilityViewController === progress {
            rightCapabilityViewController = nil
        }
        openProgressViewController = nil
        rightCapabilityCloseConfirmer = nil
        rightWorkspaceOpenRequestIDs.removeAll()
    }

    private func presentRightCapability(_ controller: NSViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controller.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        withProgrammaticCapabilitySplitPosition {
            if workspaceSplitView.arrangedSubviews.contains(where: { $0 === filesViewController.view }) {
                workspaceSplitView.removeArrangedSubview(filesViewController.view)
                filesViewController.view.removeFromSuperview()
            }
            workspaceSplitView.addArrangedSubview(controller.view)
            workspaceSplitView.addArrangedSubview(filesViewController.view)
            workspaceSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            workspaceSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
            installRightCapabilityWidthConstraints(controller.view)
            workspaceSplitView.adjustSubviews()
            view.layoutSubtreeIfNeeded()
        }
        rightCapabilityViewController = controller
        needsInitialCapabilitySplitPosition = true
        applyInitialCapabilitySplitPositionIfNeeded()
    }

    private func installRightCapabilityWidthConstraints(_ capabilityView: NSView) {
        NSLayoutConstraint.deactivate(rightCapabilityWidthConstraints)
        let filesWidth = filesViewController.view.widthAnchor.constraint(
            greaterThanOrEqualToConstant: RightWorkspaceLayout.minimumFilesWidth
        )
        let capabilityWidth = capabilityView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: RightWorkspaceLayout.minimumCapabilityWidth
        )
        let currentFilesWidth = filesViewController.view.widthAnchor.constraint(
            equalToConstant: RightWorkspaceLayout.minimumFilesWidth
        )
        filesWidth.priority = .defaultHigh
        capabilityWidth.priority = .defaultHigh
        currentFilesWidth.priority = .required
        rightFilesMinimumWidthConstraint = filesWidth
        rightFilesCurrentWidthConstraint = currentFilesWidth
        rightCapabilityWidthConstraints = [filesWidth, capabilityWidth, currentFilesWidth]
        NSLayoutConstraint.activate(rightCapabilityWidthConstraints)
    }

    private func toggleFilesSidebar() {
        guard workspaceSplitView.arrangedSubviews.count == 2,
              rightCapabilityViewController != nil
        else {
            return
        }
        if workspaceSplitView.bounds.width <= 0, view.bounds.width > 0 {
            workspaceSplitView.frame = view.bounds
            workspaceSplitView.layoutSubtreeIfNeeded()
        }
        let availableWidth = workspaceSplitView.bounds.width
        guard availableWidth > 0 else { return }
        let dividerWidth = workspaceSplitView.dividerThickness
        withProgrammaticCapabilitySplitPosition {
            let shouldCollapse = filesViewController.view.isHidden == false
            if shouldCollapse == false {
                let restoredFilesWidth = max(
                    rightFilesWidthBeforeCollapse ?? RightWorkspaceLayout.minimumFilesWidth,
                    RightWorkspaceLayout.minimumFilesWidth
                )
                filesViewController.view.isHidden = false
                rightFilesMinimumWidthConstraint?.constant = RightWorkspaceLayout.minimumFilesWidth
                rightFilesCurrentWidthConstraint?.constant = restoredFilesWidth
                let capabilityWidth = max(
                    RightWorkspaceLayout.minimumCapabilityWidth,
                    availableWidth - dividerWidth - restoredFilesWidth
                )
                workspaceSplitView.setPosition(capabilityWidth, ofDividerAt: 0)
            } else {
                let currentFilesWidth = filesViewController.view.convert(
                    filesViewController.view.bounds,
                    to: view
                ).width
                rightFilesWidthBeforeCollapse = max(
                    currentFilesWidth,
                    RightWorkspaceLayout.minimumFilesWidth
                )
                rightFilesMinimumWidthConstraint?.constant = 0
                rightFilesCurrentWidthConstraint?.constant = 0
                filesViewController.view.isHidden = true
                workspaceSplitView.setPosition(
                    max(RightWorkspaceLayout.minimumCapabilityWidth, availableWidth - dividerWidth),
                    ofDividerAt: 0
                )
            }
            workspaceSplitView.adjustSubviews()
            filesViewController.view.isHidden = shouldCollapse
            view.layoutSubtreeIfNeeded()
        }
    }

    private func applyInitialCapabilitySplitPositionIfNeeded() {
        guard needsInitialCapabilitySplitPosition,
              workspaceSplitView.arrangedSubviews.count == 2
        else {
            return
        }
        if workspaceSplitView.bounds.width <= 0, view.bounds.width > 0 {
            workspaceSplitView.frame = view.bounds
            workspaceSplitView.layoutSubtreeIfNeeded()
        }
        let availableWidth = workspaceSplitView.bounds.width
        guard availableWidth > 0 else { return }
        let dividerWidth = workspaceSplitView.dividerThickness
        let minimumFilesWidth = filesViewController.view.isHidden ? 0 : RightWorkspaceLayout.minimumFilesWidth
        let maximumCapabilityWidth = availableWidth
            - dividerWidth
            - minimumFilesWidth
        guard maximumCapabilityWidth >= RightWorkspaceLayout.minimumCapabilityWidth else {
            return
        }

        let capabilityWidth = clampedInitialCapabilityWidth(
            availableWidth: availableWidth,
            maximumCapabilityWidth: maximumCapabilityWidth
        )
        let filesWidth = availableWidth - dividerWidth - capabilityWidth
        withProgrammaticCapabilitySplitPosition {
            rightFilesCurrentWidthConstraint?.constant = filesWidth
            workspaceSplitView.setPosition(capabilityWidth, ofDividerAt: 0)
            workspaceSplitView.adjustSubviews()
            view.layoutSubtreeIfNeeded()
        }
        needsInitialCapabilitySplitPosition = false
    }

    private func clampedInitialCapabilityWidth(
        availableWidth: CGFloat,
        maximumCapabilityWidth: CGFloat
    ) -> CGFloat {
        let storedWidth = storedRightCapabilityWidth()
        let defaultWidth = max(
            RightWorkspaceLayout.preferredCapabilityWidth,
            availableWidth * RightWorkspaceLayout.defaultCapabilityWidthFraction,
            RightWorkspaceLayout.minimumCapabilityWidth
        )
        let requestedWidth = storedWidth ?? defaultWidth
        return min(max(requestedWidth, RightWorkspaceLayout.minimumCapabilityWidth), maximumCapabilityWidth)
    }

    private func storedRightCapabilityWidth() -> CGFloat? {
        guard rightCapabilityWidthDefaults.bool(forKey: RightWorkspaceLayout.userSetCapabilityWidthKey) else {
            return nil
        }
        guard let number = rightCapabilityWidthDefaults.object(
            forKey: RightWorkspaceLayout.storedCapabilityWidthKey
        ) as? NSNumber else {
            return nil
        }
        let width = CGFloat(number.doubleValue)
        guard width.isFinite, width > 0 else {
            return nil
        }
        return width
    }

    private func persistUserRightCapabilityWidth(_ width: CGFloat) {
        guard width.isFinite, width > 0 else {
            return
        }
        rightCapabilityWidthDefaults.set(Double(width), forKey: RightWorkspaceLayout.storedCapabilityWidthKey)
        rightCapabilityWidthDefaults.set(true, forKey: RightWorkspaceLayout.userSetCapabilityWidthKey)
    }

    private func withProgrammaticCapabilitySplitPosition(_ action: () -> Void) {
        isApplyingProgrammaticCapabilitySplitPosition = true
        defer {
            isApplyingProgrammaticCapabilitySplitPosition = false
        }
        action()
    }

    private static func normalizedInitialRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "~" : trimmed
    }
}

extension RemoteFilesPaneViewController: NSSplitViewDelegate {
    public func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === workspaceSplitView,
              dividerIndex == 0,
              splitView.arrangedSubviews.count == 2
        else {
            return proposedPosition
        }
        let dividerWidth = splitView.dividerThickness
        let minimumFilesWidth = filesViewController.view.isHidden ? 0 : RightWorkspaceLayout.minimumFilesWidth
        let maximumCapabilityWidth = splitView.bounds.width
            - dividerWidth
            - minimumFilesWidth
        guard maximumCapabilityWidth >= RightWorkspaceLayout.minimumCapabilityWidth else {
            return proposedPosition
        }
        let capabilityWidth = min(
            max(proposedPosition, RightWorkspaceLayout.minimumCapabilityWidth),
            maximumCapabilityWidth
        )
        let filesWidth = splitView.bounds.width
            - splitView.dividerThickness
            - capabilityWidth
        rightFilesCurrentWidthConstraint?.constant = filesWidth
        if isApplyingProgrammaticCapabilitySplitPosition == false {
            persistUserRightCapabilityWidth(capabilityWidth)
        }
        return capabilityWidth
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitView = notification.object as? NSSplitView,
              splitView === workspaceSplitView
        else {
            return
        }
    }
}

@MainActor
private final class RemoteFilesPaneRemoteEditOpener: RemoteEditOpening {
    private weak var filesPane: RemoteFilesPaneViewController?
    private let fallbackOpener: RemoteEditOpening
    private var rightOpenRequestIDsByKey: [String: UUID] = [:]

    init(
        filesPane: RemoteFilesPaneViewController,
        fallbackOpener: RemoteEditOpening? = nil
    ) {
        self.filesPane = filesPane
        self.fallbackOpener = fallbackOpener ?? AppKitRemoteEditOpener()
    }

    func prepareToOpenRemote(selection: RemoteFileSelection, mode: RemoteFileOpenMode) -> Bool {
        guard let filesPane else {
            return fallbackOpener.prepareToOpenRemote(selection: selection, mode: mode)
        }

        switch mode {
        case .textEditor, .mediaPreview:
            guard let requestID = filesPane.beginRightWorkspaceOpenRequest(selection: selection, mode: mode) else {
                return false
            }
            rightOpenRequestIDsByKey[rightOpenRequestKey(remotePath: selection.path, mode: mode)] = requestID
            return true
        case .chooseApplication, .defaultApplication:
            return filesPane.presentOpenProgress(selection: selection, mode: mode)
        }
    }

    func openLocalCopy(
        at url: URL,
        mode: RemoteFileOpenMode,
        applicationURL: URL?,
        saveHandler: RemoteEditSaveHandler?
    ) {
        switch mode {
        case .textEditor:
            filesPane?.presentTextEditor(localURL: url, saveHandler: saveHandler)
        case .mediaPreview:
            filesPane?.presentMediaPreview(localURL: url)
        case .chooseApplication, .defaultApplication:
            filesPane?.clearTransientOpenProgress()
            fallbackOpener.openLocalCopy(
                at: url,
                mode: mode,
                applicationURL: applicationURL,
                saveHandler: saveHandler
            )
        }
    }

    func openRemoteDocument(
        _ document: RemoteTextEditorDocumentDescriptor,
        mode: RemoteFileOpenMode,
        saveHandler: ((String) throws -> Void)?
    ) {
        switch mode {
        case .textEditor, .mediaPreview:
            let requestKey = rightOpenRequestKey(remotePath: document.remotePath, mode: mode)
            let requestID = rightOpenRequestIDsByKey[requestKey]
            guard filesPane?.isRightWorkspaceOpenRequestActive(requestID) == true else {
                rightOpenRequestIDsByKey[requestKey] = nil
                return
            }
            filesPane?.presentRemoteDocument(document, onSaveText: saveHandler)
            filesPane?.finishRightWorkspaceOpenRequest(requestID)
            rightOpenRequestIDsByKey[requestKey] = nil
        case .chooseApplication, .defaultApplication:
            fallbackOpener.openRemoteDocument(document, mode: mode, saveHandler: saveHandler)
        }
    }

    func remoteOpenDidFail(selection: RemoteFileSelection, mode: RemoteFileOpenMode, message: String) {
        switch mode {
        case .textEditor, .mediaPreview:
            let requestKey = rightOpenRequestKey(remotePath: selection.path, mode: mode)
            let requestID = rightOpenRequestIDsByKey[requestKey]
            guard filesPane?.isRightWorkspaceOpenRequestActive(requestID) == true else {
                rightOpenRequestIDsByKey[requestKey] = nil
                return
            }
            filesPane?.presentOpenFailure(selection: selection, mode: mode, message: message)
            filesPane?.finishRightWorkspaceOpenRequest(requestID)
            rightOpenRequestIDsByKey[requestKey] = nil
        case .chooseApplication, .defaultApplication:
            filesPane?.presentOpenFailure(selection: selection, mode: mode, message: message)
        }
    }

    func compareLocalCopies(_ urls: [URL], parentWindow: NSWindow?) throws {
        try fallbackOpener.compareLocalCopies(urls, parentWindow: parentWindow)
    }

    private func rightOpenRequestKey(remotePath: String, mode: RemoteFileOpenMode) -> String {
        "\(mode.logName):\(remotePath)"
    }
}

public final class RemoteFileOpenProgressViewController: NSViewController {
    public let selection: RemoteFileSelection
    public let mode: RemoteFileOpenMode
    public var onCloseRequested: (() -> Void)?

    private let fileLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let closeButton = NSButton()

    public init(selection: RemoteFileSelection, mode: RemoteFileOpenMode) {
        self.selection = selection
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        title = (selection.path as NSString).lastPathComponent
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let root = StacioAppearanceRefreshView()
        root.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(root, color: NSColor.windowBackgroundColor)
        root.setAccessibilityIdentifier("Stacio.RemoteFileOpenProgress.root")

        let header = makeHeader()
        let body = makeBody()
        root.addSubview(header)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    public func showFailure(_ message: String) {
        loadViewIfNeeded()
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusLabel.stringValue = "远端文件打开失败"
        detailLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(message)
    }

    public var visibleTextSnapshotForTesting: String {
        loadViewIfNeeded()
        return [
            fileLabel.stringValue,
            statusLabel.stringValue,
            detailLabel.stringValue
        ].joined(separator: "\n")
    }

    private func makeHeader() -> NSView {
        let header = StacioAppearanceRefreshView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(header, color: NSColor.controlBackgroundColor)

        fileLabel.stringValue = (selection.path as NSString).lastPathComponent
        fileLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        fileLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")
        closeButton.bezelStyle = .texturedRounded
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.controlSize = .small
        closeButton.toolTip = "关闭"
        closeButton.setAccessibilityLabel("关闭")
        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(fileLabel)
        header.addSubview(closeButton)
        NSLayoutConstraint.activate([
            fileLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            fileLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            fileLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24)
        ])
        return header
    }

    private func makeBody() -> NSView {
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.startAnimation(nil)
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.setAccessibilityIdentifier("Stacio.RemoteFileOpenProgress.spinner")

        statusLabel.stringValue = mode == .chooseApplication || mode == .defaultApplication
            ? "正在准备远端文件"
            : "正在在线打开远端文件"
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.stringValue = openDetailText()
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        body.addSubview(progressIndicator)
        body.addSubview(statusLabel)
        body.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            progressIndicator.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: body.centerYAnchor, constant: -34),

            statusLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 18),

            detailLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            detailLabel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            detailLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8)
        ])
        return body
    }

    private func openDetailText() -> String {
        switch mode {
        case .textEditor:
            return "读取远端内容后会在 Stacio 编辑器中打开"
        case .mediaPreview:
            return "读取远端内容后会在 Stacio 编辑器标签页中打开"
        case .chooseApplication, .defaultApplication:
            return "下载完成后会按选择的打开方式处理"
        }
    }

    @objc private func closeButtonPressed(_ sender: Any?) {
        onCloseRequested?()
    }
}

private final class RemoteFilesShortcutRootView: NSView {
    var onToggleFilesSidebar: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        StacioDesignSystem.refreshDynamicLayerColors(in: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "b"
        {
            onToggleFilesSidebar?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
