import AppKit

public struct GraphicsSessionDiagnostic: Equatable {
    public let protocolName: String
    public let host: String
    public let port: UInt16
    public let adapterPath: String?
    public let launchArguments: [String]
    public let status: String
    public let presentation: GraphicsRuntimePresentation

    public init(
        protocolName: String,
        host: String,
        port: UInt16,
        adapterPath: String?,
        launchArguments: [String],
        status: String,
        presentation: GraphicsRuntimePresentation = .diagnostic
    ) {
        self.protocolName = protocolName
        self.host = host
        self.port = port
        self.adapterPath = adapterPath
        self.launchArguments = launchArguments
        self.status = status
        self.presentation = presentation
    }
}

private final class GraphicsClipboardSyncOwnership {
    static let shared = GraphicsClipboardSyncOwnership()

    private let lock = NSLock()
    private weak var activeSessionObject: AnyObject?

    func activate(_ session: any EmbeddedGraphicsSessionLifecycle) {
        let sessionObject = session as AnyObject
        lock.lock()
        defer { lock.unlock() }
        guard activeSessionObject !== sessionObject else { return }
        (activeSessionObject as? any EmbeddedGraphicsSessionLifecycle)?
            .setClipboardSynchronizationEnabled(false)
        activeSessionObject = sessionObject
        session.setClipboardSynchronizationEnabled(true)
    }

    func deactivate(_ session: any EmbeddedGraphicsSessionLifecycle) {
        let sessionObject = session as AnyObject
        lock.lock()
        defer { lock.unlock() }
        guard activeSessionObject === sessionObject else { return }
        activeSessionObject = nil
        session.setClipboardSynchronizationEnabled(false)
    }

    func isActive(_ session: any EmbeddedGraphicsSessionLifecycle) -> Bool {
        let sessionObject = session as AnyObject
        lock.lock()
        defer { lock.unlock() }
        return activeSessionObject === sessionObject
    }
}

public final class GraphicsSessionPaneViewController: NSViewController {
    public private(set) var runtimeID: String
    public private(set) var diagnostic: GraphicsSessionDiagnostic
    private var onClose: ((String) -> Void)?
    private var attachment: GraphicsRuntimeAttachment?
    private var attachmentGeneration: UInt64 = 1
    private var isConnecting = false
    private var connectionFailureMessage: String?
    private var didCloseRuntime = false
    private var copiedDiagnosticSummary = ""
    private var renderSurfaceView: GraphicsRenderSurfaceView?
    private let frameDeliveryLock = NSLock()
    private var pendingFrameDelivery: (
        frame: GraphicsFrame,
        generation: UInt64,
        surface: GraphicsRenderSurfaceView
    )?
    private var frameDeliveryScheduled = false
    private var observesWindowKeyState = false
    /// 文件拖传回调。外部（WorkspaceViewController）注入以复用 FilesCoordinator 上传到远端 /tmp/。
    /// 为 nil 时提示用户先连接 SSH 会话。
    public var fileUploadHandler: (([String], @escaping (Result<[String], Error>) -> Void) -> Void)?
    private var retryAction: (() -> Void)?
    private let connectionStateView: SessionConnectionStateView

    private let titleLabel = NSTextField(labelWithString: L10n.Graphics.title)
    private let engineLabel: NSTextField
    private let statusIconView = NSImageView()
    private let summaryLabel: NSTextField
    private let endpointValue: NSTextField
    private let adapterValue: NSTextField
    private let statusValue: NSTextField
    private let argumentsValue: NSTextField
    private let copyButton = StacioHoverButton(title: L10n.Graphics.copyDiagnostic, target: nil, action: nil)

    public var visibleTextSnapshotForTesting: String {
        _ = view
        if connectionStateView.isHidden == false, presentsConnectionState {
            return connectionStateView.visibleTextForTesting
        }
        return [
            visibleText(titleLabel),
            visibleText(engineLabel),
            visibleText(summaryLabel),
            visibleText(endpointValue).map { "\(L10n.Graphics.endpointDetail)：\($0)" },
            visibleText(adapterValue).map { "\(L10n.Graphics.adapterPath)：\($0)" },
            visibleText(statusValue).map { "\(L10n.Graphics.runtimeStatus)：\($0)" },
            visibleText(argumentsValue).map { "\(L10n.Graphics.launchArguments)：\($0)" }
        ].compactMap { $0 }.joined(separator: "\n")
    }

    public var copiedDiagnosticSummaryForTesting: String {
        copiedDiagnosticSummary
    }

    public var hasEmbeddedRenderSurfaceForTesting: Bool {
        _ = view
        return renderSurfaceView != nil
    }

    public var isConnectionStateVisibleForTesting: Bool {
        _ = view
        return presentsConnectionState && connectionStateView.isHidden == false
    }

    public var hasExternalClientPresentationForTesting: Bool {
        if case .externalClient = diagnostic.presentation {
            return true
        }
        return false
    }

    public var renderedFrameSizeForTesting: CGSize? {
        _ = view
        return renderSurfaceView?.renderedFrameSizeForTesting
    }

    public var hasRenderedImageForTesting: Bool {
        _ = view
        return renderSurfaceView?.hasRenderedImageForTesting ?? false
    }

    public var renderSurfaceFrameForTesting: NSRect? {
        _ = view
        return renderSurfaceView?.frame
    }

    public var remotePointerPositionForTesting: CGPoint? {
        _ = view
        return renderSurfaceView?.remotePointerPositionForTesting
    }

    public var isRemotePointerVisibleForTesting: Bool {
        _ = view
        return renderSurfaceView?.isRemotePointerVisibleForTesting ?? false
    }

    public var remotePointerBitmapSizeForTesting: CGSize? {
        _ = view
        return renderSurfaceView?.remotePointerBitmapSizeForTesting
    }

    public var remotePointerAnchorPointForTesting: CGPoint? {
        _ = view
        return renderSurfaceView?.remotePointerAnchorPointForTesting
    }

    public var statusToastTextForTesting: String? {
        _ = view
        return renderSurfaceView?.statusToastTextForTesting
    }

    public var isStatusToastVisibleForTesting: Bool {
        _ = view
        return renderSurfaceView?.isStatusToastVisibleForTesting ?? false
    }

    public var hasVisibleDiagnosticChromeForTesting: Bool {
        _ = view
        return [
            titleLabel,
            engineLabel,
            statusIconView,
            summaryLabel,
            endpointValue,
            adapterValue,
            statusValue,
            argumentsValue,
            copyButton
        ].contains { isEffectivelyVisible($0) }
    }

    public init(
        runtimeID: String,
        title: String,
        diagnostic: GraphicsSessionDiagnostic,
        attachment: GraphicsRuntimeAttachment? = nil,
        onClose: ((String) -> Void)? = nil
    ) {
        self.runtimeID = runtimeID
        self.diagnostic = diagnostic
        self.attachment = attachment
        self.onClose = onClose
        self.connectionStateView = SessionConnectionStateView(
            protocolName: diagnostic.protocolName,
            endpoint: "\(diagnostic.host):\(diagnostic.port)"
        )
        self.engineLabel = NSTextField(labelWithString: Self.engineText(for: diagnostic))
        self.summaryLabel = NSTextField(labelWithString: Self.summaryText(for: diagnostic))
        self.endpointValue = NSTextField(labelWithString: "\(diagnostic.host):\(diagnostic.port)")
        self.adapterValue = NSTextField(labelWithString: diagnostic.adapterPath ?? L10n.Graphics.missingAdapter)
        self.statusValue = NSTextField(labelWithString: diagnostic.status)
        self.argumentsValue = NSTextField(
            labelWithString: diagnostic.launchArguments.isEmpty ? "-" : diagnostic.launchArguments.joined(separator: " ")
        )
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        deactivateClipboardSynchronization()
    }

    public init(
        connectingRuntimeID runtimeID: String,
        title: String,
        protocolName: String,
        host: String,
        port: UInt16
    ) {
        let diagnostic = GraphicsSessionDiagnostic(
            protocolName: protocolName,
            host: host,
            port: port,
            adapterPath: nil,
            launchArguments: [],
            status: L10n.TerminalLifecycle.connecting
        )
        self.runtimeID = runtimeID
        self.diagnostic = diagnostic
        self.attachment = nil
        self.onClose = nil
        self.isConnecting = true
        self.connectionStateView = SessionConnectionStateView(
            protocolName: protocolName,
            endpoint: "\(host):\(port)"
        )
        self.engineLabel = NSTextField(labelWithString: Self.engineText(for: diagnostic))
        self.summaryLabel = NSTextField(labelWithString: Self.summaryText(for: diagnostic))
        self.endpointValue = NSTextField(labelWithString: "\(host):\(port)")
        self.adapterValue = NSTextField(labelWithString: L10n.Graphics.missingAdapter)
        self.statusValue = NSTextField(labelWithString: L10n.TerminalLifecycle.connecting)
        self.argumentsValue = NSTextField(labelWithString: "-")
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    public func closeGraphicsRuntime() {
        guard !didCloseRuntime else { return }
        didCloseRuntime = true
        let closingRuntimeID = runtimeID
        advanceAttachmentGeneration()
        attachment = nil
        setRetryAction(nil)
        onClose?(closingRuntimeID)
        onClose = nil
    }

    public func setRetryAction(_ action: (() -> Void)?) {
        retryAction = action
        connectionStateView.setRetryAction(
            title: L10n.TerminalLifecycle.reconnect,
            action: action == nil ? nil : { [weak self] in
                self?.retryFromConnectionState()
            }
        )
    }

    @discardableResult
    public func attachRuntime(
        runtimeID: String,
        diagnostic: GraphicsSessionDiagnostic,
        attachment: GraphicsRuntimeAttachment?,
        onClose: ((String) -> Void)?
    ) -> Bool {
        guard didCloseRuntime == false else {
            onClose?(runtimeID)
            return false
        }
        self.runtimeID = runtimeID
        self.diagnostic = diagnostic
        advanceAttachmentGeneration()
        self.attachment = attachment
        self.onClose = onClose
        isConnecting = false
        connectionFailureMessage = nil
        refreshDiagnosticLabels()
        if isViewLoaded {
            rebuildPresentation(animated: view.window != nil)
        }
        return true
    }

    public func displayConnectionFailure(_ diagnostic: GraphicsSessionDiagnostic) {
        guard didCloseRuntime == false else { return }
        self.diagnostic = diagnostic
        advanceAttachmentGeneration()
        attachment = nil
        onClose = nil
        isConnecting = false
        let message = RuntimeDiagnosticFormatter.userMessage(diagnostic.status)
        connectionFailureMessage = message.hasPrefix(L10n.TerminalLifecycle.connectionFailed)
            ? message
            : L10n.TerminalLifecycle.connectionFailedMessage(message)
        connectionStateView.update(
            phase: .failed(message: connectionFailureMessage ?? L10n.TerminalLifecycle.connectionFailed),
            protocolName: diagnostic.protocolName,
            endpoint: "\(diagnostic.host):\(diagnostic.port)"
        )
        refreshDiagnosticLabels()
        if isViewLoaded {
            rebuildPresentation(animated: view.window != nil)
        }
    }

    public func copyDiagnosticSummary() {
        let summary = diagnosticSummary()
        copiedDiagnosticSummary = summary
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    public func simulateEmbeddedGraphicsInputForTesting(_ event: GraphicsInputEvent) {
        _ = view
        renderSurfaceView?.sendInputForTesting(event)
    }

    public func simulateEmbeddedFileDropForTesting(paths: [String], at point: NSPoint) {
        _ = view
        renderSurfaceView?.simulateFileDropForTesting(paths: paths, at: point)
    }

    public func simulateRegisteredFileDropForTesting(paths: [String], at point: NSPoint) {
        _ = view
        renderSurfaceView?.simulateRegisteredFileDropForTesting(paths: paths, at: point)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(container)
        view = container
        installCurrentPresentation(in: container)
        observeWindowKeyStateIfNeeded()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        updateClipboardSynchronizationForWindowState()
    }

    public override func viewDidDisappear() {
        deactivateClipboardSynchronization()
        super.viewDidDisappear()
    }

    private func installCurrentPresentation(in container: NSView) {
        renderSurfaceView = nil
        if presentsConnectionState {
            if let connectionFailureMessage {
                connectionStateView.update(phase: .failed(message: connectionFailureMessage))
            } else {
                connectionStateView.update(phase: .connecting)
            }
            container.addSubview(connectionStateView)
            NSLayoutConstraint.activate([
                connectionStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                connectionStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                connectionStateView.topAnchor.constraint(equalTo: container.topAnchor),
                connectionStateView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            connectionStateView.setPresented(true, animated: false)
            return
        }

        if let attachment {
            let surface = makeRenderSurface(
                for: attachment,
                generation: attachmentGeneration
            )
            container.addSubview(surface)
            renderSurfaceView = surface
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                surface.topAnchor.constraint(equalTo: container.topAnchor),
                surface.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            return
        }

        if case .externalClient = diagnostic.presentation {
            configureExternalClientLayout(in: container)
            return
        }

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        engineLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        engineLabel.textColor = .secondaryLabelColor
        engineLabel.translatesAutoresizingMaskIntoConstraints = false

        statusIconView.image = Self.statusImage(for: diagnostic)
        statusIconView.contentTintColor = Self.statusColor(for: diagnostic)
        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        statusIconView.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        summaryLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        copyButton.target = self
        copyButton.action = #selector(copyDiagnosticButtonPressed)
        copyButton.bezelStyle = .rounded
        copyButton.setAccessibilityIdentifier("Stacio.Graphics.copyDiagnostic")
        copyButton.setAccessibilityLabel(L10n.Graphics.copyDiagnostic)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(copyButton)

        let summaryHeader = NSStackView(views: [statusIconView, summaryLabel])
        summaryHeader.orientation = .horizontal
        summaryHeader.alignment = .centerY
        summaryHeader.spacing = 10
        summaryHeader.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        for row in [
            makeRow(label: L10n.Graphics.endpointDetail, value: endpointValue),
            makeRow(label: L10n.Graphics.runtimeStatus, value: statusValue),
            makeRow(label: L10n.Graphics.adapterPath, value: adapterValue),
            makeRow(label: L10n.Graphics.launchArguments, value: argumentsValue)
        ] {
            stack.addArrangedSubview(row)
        }

        container.addSubview(titleLabel)
        container.addSubview(engineLabel)
        container.addSubview(summaryHeader)
        container.addSubview(stack)
        container.addSubview(copyButton)

        var constraints = [
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),

            engineLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            engineLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            summaryHeader.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryHeader.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            summaryHeader.topAnchor.constraint(equalTo: engineLabel.bottomAnchor, constant: 22),
            statusIconView.widthAnchor.constraint(equalToConstant: 28),
            statusIconView.heightAnchor.constraint(equalToConstant: 28),

            stack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            copyButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 96),
            copyButton.heightAnchor.constraint(equalToConstant: 30)
        ]

        constraints.append(contentsOf: [
            stack.topAnchor.constraint(equalTo: summaryHeader.bottomAnchor, constant: 18),
            copyButton.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 20)
        ])

        NSLayoutConstraint.activate(constraints)

    }

    private func rebuildPresentation(animated: Bool) {
        let container = view
        connectionStateView.setPresented(false, animated: false)
        container.subviews.forEach { $0.removeFromSuperview() }
        installCurrentPresentation(in: container)
        guard animated,
              NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
        else {
            container.alphaValue = 1
            return
        }
        StacioDesignSystem.fadeIn(container)
    }

    private func refreshDiagnosticLabels() {
        engineLabel.stringValue = Self.engineText(for: diagnostic)
        summaryLabel.stringValue = Self.summaryText(for: diagnostic)
        endpointValue.stringValue = "\(diagnostic.host):\(diagnostic.port)"
        adapterValue.stringValue = diagnostic.adapterPath ?? L10n.Graphics.missingAdapter
        statusValue.stringValue = diagnostic.status
        argumentsValue.stringValue = diagnostic.launchArguments.isEmpty
            ? "-"
            : diagnostic.launchArguments.joined(separator: " ")
    }

    private var presentsConnectionState: Bool {
        isConnecting || connectionFailureMessage != nil
    }

    private func retryFromConnectionState() {
        guard didCloseRuntime == false,
              connectionFailureMessage != nil,
              let retryAction
        else { return }

        connectionFailureMessage = nil
        advanceAttachmentGeneration()
        attachment = nil
        onClose = nil
        isConnecting = true
        diagnostic = GraphicsSessionDiagnostic(
            protocolName: diagnostic.protocolName,
            host: diagnostic.host,
            port: diagnostic.port,
            adapterPath: diagnostic.adapterPath,
            launchArguments: diagnostic.launchArguments,
            status: L10n.TerminalLifecycle.connecting,
            presentation: diagnostic.presentation
        )
        connectionStateView.update(
            phase: .connecting,
            protocolName: diagnostic.protocolName,
            endpoint: "\(diagnostic.host):\(diagnostic.port)"
        )
        refreshDiagnosticLabels()
        if isViewLoaded {
            rebuildPresentation(animated: view.window != nil)
        }
        retryAction()
    }

    private func configureExternalClientLayout(in container: NSView) {
        titleLabel.stringValue = title ?? L10n.Graphics.title
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        engineLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        engineLabel.textColor = .secondaryLabelColor
        engineLabel.translatesAutoresizingMaskIntoConstraints = false

        statusIconView.image = NSImage(systemSymbolName: "display.and.arrow.down", accessibilityDescription: L10n.Graphics.status)
        statusIconView.contentTintColor = StacioDesignSystem.theme.accentColor
        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        statusIconView.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 15, weight: .medium)
        summaryLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        summaryLabel.maximumNumberOfLines = 3
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, engineLabel, summaryLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [statusIconView, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            row.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -28),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusIconView.widthAnchor.constraint(equalToConstant: 32),
            statusIconView.heightAnchor.constraint(equalToConstant: 32),
            summaryLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        ])
    }

    private func makeRenderSurface(
        for attachment: GraphicsRuntimeAttachment,
        generation: UInt64
    ) -> GraphicsRenderSurfaceView {
        let surface = GraphicsRenderSurfaceView(frame: .zero)
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.inputHandler = { [weak self, weak session = attachment.session] event in
            guard self?.isCurrentAttachment(generation: generation) == true else { return }
            if Self.inputClaimsClipboardSynchronization(event),
               let lifecycle = session as? any EmbeddedGraphicsSessionLifecycle {
                GraphicsClipboardSyncOwnership.shared.activate(lifecycle)
            }
            session?.sendInput(event)
        }
        attachment.session.onFrame = { [weak self, weak surface] frame in
            guard let surface else { return }
            self?.enqueueLatestFrame(frame, generation: generation, surface: surface)
        }
        if let latestFrame = (attachment.session as? EmbeddedGraphicsSessionLifecycle)?.latestFrame {
            // A cached frame is part of the initial view state. Render it
            // before returning from view construction so reconnects do not
            // briefly show a blank surface while waiting for another frame.
            let renderInitialFrame = { [weak self, weak surface] in
                guard let self,
                      let surface,
                      self.isCurrentAttachment(generation: generation) else { return }
                surface.display(latestFrame)
            }
            if Thread.isMainThread {
                renderInitialFrame()
            } else {
                DispatchQueue.main.sync(execute: renderInitialFrame)
            }
        }
        attachment.session.onPointerPosition = { [weak self, weak surface] x, y in
            if Thread.isMainThread {
                guard self?.isCurrentAttachment(generation: generation) == true else { return }
                surface?.updateRemotePointerPosition(x: x, y: y)
            } else {
                DispatchQueue.main.async { [weak self, weak surface] in
                    guard self?.isCurrentAttachment(generation: generation) == true else { return }
                    surface?.updateRemotePointerPosition(x: x, y: y)
                }
            }
        }
        attachment.session.onPointerVisibilityChanged = { [weak self, weak surface] isVisible in
            if Thread.isMainThread {
                guard self?.isCurrentAttachment(generation: generation) == true else { return }
                surface?.setRemotePointerVisible(isVisible)
            } else {
                DispatchQueue.main.async { [weak self, weak surface] in
                    guard self?.isCurrentAttachment(generation: generation) == true else { return }
                    surface?.setRemotePointerVisible(isVisible)
                }
            }
        }
        attachment.session.onPointerBitmap = { [weak self, weak surface] bitmap in
            if Thread.isMainThread {
                guard self?.isCurrentAttachment(generation: generation) == true else { return }
                surface?.setRemotePointerBitmap(bitmap)
            } else {
                DispatchQueue.main.async { [weak self, weak surface] in
                    guard self?.isCurrentAttachment(generation: generation) == true else { return }
                    surface?.setRemotePointerBitmap(bitmap)
                }
            }
        }
        // VNC/RDP lifecycle 回调
        if let lifecycle = attachment.session as? EmbeddedGraphicsSessionLifecycle {
            let connectedHandler: (Int, Int, String) -> Void = { [weak self] width, height, name in
                DispatchQueue.main.async {
                    guard self?.isCurrentAttachment(generation: generation) == true else { return }
                    self?.handleVNCGraphicsConnected(width: width, height: height, name: name)
                }
            }
            let disconnectedHandler: (String) -> Void = { [weak self] reason in
                DispatchQueue.main.async {
                    guard self?.isCurrentAttachment(generation: generation) == true else { return }
                    self?.handleVNCGraphicsDisconnected(
                        reason: reason,
                        generation: generation
                    )
                }
            }
            lifecycle.onConnected = connectedHandler
            lifecycle.onDisconnected = disconnectedHandler
            lifecycle.onClipboard = { [weak self, weak lifecycle] text in
                let updatePasteboard = { [weak self, weak lifecycle] in
                    guard self?.isCurrentAttachment(generation: generation) == true,
                          let lifecycle,
                          GraphicsClipboardSyncOwnership.shared.isActive(lifecycle) else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
                if Thread.isMainThread {
                    updatePasteboard()
                } else {
                    DispatchQueue.main.async(execute: updatePasteboard)
                }
            }
            lifecycle.onNetworkStatus = { [weak self] rttMs, mode in
                DispatchQueue.main.async {
                    guard self?.isCurrentAttachment(generation: generation) == true else { return }
                    self?.handleNetworkStatusChanged(rttMs: rttMs, mode: mode)
                }
            }
            lifecycle.onError = { [weak self] message in
                DispatchQueue.main.async {
                    guard self?.isCurrentAttachment(generation: generation) == true else { return }
                    self?.renderSurfaceView?.showStatusToast("远程桌面错误：\(message)", duration: 5.0)
                }
            }
            if let latestError = lifecycle.latestError {
                lifecycle.onError?(latestError)
            }
            switch lifecycle.lifecycleState {
            case .connecting:
                break
            case let .connected(width, height, name):
                connectedHandler(width, height, name)
            case let .disconnected(reason):
                disconnectedHandler(reason)
            }
        }
        surface.onFileDrop = { [weak self] paths in
            guard self?.isCurrentAttachment(generation: generation) == true else { return }
            self?.handleFileDrop(paths: paths, generation: generation)
        }
        return surface
    }

    private func handleFileDrop(paths: [String], generation: UInt64) {
        guard let handler = fileUploadHandler else {
            renderSurfaceView?.showStatusToast("请先连接同一主机的 SSH 会话以使用文件传输", duration: 4.0)
            return
        }
        let count = paths.count
        renderSurfaceView?.showStatusToast("正在上传 \(count) 个文件到远端 /tmp/...", duration: 60.0)
        handler(paths) { [weak self] result in
            DispatchQueue.main.async {
                guard self?.isCurrentAttachment(generation: generation) == true else { return }
                switch result {
                case .success(let uploadedRemotePaths):
                    let message = uploadedRemotePaths.isEmpty
                        ? "已上传到远端 /tmp/"
                        : "已上传到远端 \(uploadedRemotePaths.joined(separator: ", "))"
                    self?.renderSurfaceView?.showStatusToast(message, duration: 3.0)
                case .failure(let error):
                    self?.renderSurfaceView?.showStatusToast("上传失败：\(error.localizedDescription)", duration: 5.0)
                }
            }
        }
    }

    private func handleVNCGraphicsConnected(width: Int, height: Int, name: String) {
        // 连接成功——确保渲染层已安装
        if renderSurfaceView == nil {
            rebuildPresentation(animated: view.window != nil)
        }
        renderSurfaceView?.setStatusBarVisible(true)
    }

    private func handleVNCGraphicsDisconnected(reason: String, generation: UInt64) {
        guard isCurrentAttachment(generation: generation) else { return }
        // 断线时恢复诊断面板
        renderSurfaceView?.setStatusBarVisible(false)
        let message = RuntimeDiagnosticFormatter.userMessage(reason)
        connectionFailureMessage = message.hasPrefix(L10n.TerminalLifecycle.connectionFailed)
            ? message
            : L10n.TerminalLifecycle.connectionFailedMessage(message)
        advanceAttachmentGeneration()
        attachment = nil
        refreshDiagnosticLabels()
        if isViewLoaded {
            rebuildPresentation(animated: view.window != nil)
        }
    }

    // MARK: - PERF-1：网络状态 + 自适应质量

    private func handleNetworkStatusChanged(rttMs: Int, mode: String) {
        renderSurfaceView?.updateNetworkStatus(rttMs: rttMs, mode: mode)
        // VNC/RDP 会话各自在协议层应用网络策略。Pane 只展示状态，
        // 避免第二套控制器覆盖用户选择的目标画质。
    }

    private func enqueueLatestFrame(
        _ frame: GraphicsFrame,
        generation: UInt64,
        surface: GraphicsRenderSurfaceView
    ) {
        frameDeliveryLock.lock()
        pendingFrameDelivery = (frame, generation, surface)
        let shouldSchedule = frameDeliveryScheduled == false
        if shouldSchedule {
            frameDeliveryScheduled = true
        }
        frameDeliveryLock.unlock()

        // A callback produced on the main thread is already serialized with
        // AppKit rendering. Deliver it immediately so a first frame is not
        // left waiting behind another run-loop turn. Frames produced by the
        // graphics worker remain coalesced onto the main queue.
        if Thread.isMainThread {
            deliverLatestFrame()
        } else if shouldSchedule {
            DispatchQueue.main.async { [weak self] in
                self?.deliverLatestFrame()
            }
        }
    }

    private func deliverLatestFrame() {
        frameDeliveryLock.lock()
        let delivery = pendingFrameDelivery
        pendingFrameDelivery = nil
        frameDeliveryScheduled = false
        frameDeliveryLock.unlock()

        guard let delivery,
              isCurrentAttachment(generation: delivery.generation),
              renderSurfaceView === delivery.surface else { return }
        delivery.surface.display(delivery.frame)
    }

    private func advanceAttachmentGeneration() {
        deactivateClipboardSynchronization()
        frameDeliveryLock.lock()
        pendingFrameDelivery = nil
        frameDeliveryLock.unlock()
        attachmentGeneration &+= 1
        if attachmentGeneration == 0 {
            attachmentGeneration = 1
        }
    }

    private static func inputClaimsClipboardSynchronization(_ event: GraphicsInputEvent) -> Bool {
        switch event {
        case .mouseButton, .scroll, .key, .unicodeText, .fileDrop, .clipboardTextPaste:
            return true
        case .resize, .mouseMoved, .quality, .close:
            return false
        }
    }

    private func observeWindowKeyStateIfNeeded() {
        guard observesWindowKeyState == false else { return }
        observesWindowKeyState = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(graphicsWindowKeyStateChanged(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(graphicsWindowKeyStateChanged(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(graphicsWindowKeyStateChanged(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func graphicsWindowKeyStateChanged(_ notification: Notification) {
        if let window = notification.object as? NSWindow,
           window !== view.window { return }
        if notification.name == NSWindow.didResignKeyNotification
            || notification.name == NSApplication.didResignActiveNotification {
            renderSurfaceView?.releaseActiveInputForFocusLoss()
        }
        updateClipboardSynchronizationForWindowState()
    }

    private func updateClipboardSynchronizationForWindowState() {
        guard view.window?.isKeyWindow == true,
              isPaneVisibleInWindow,
              presentsConnectionState == false,
              let lifecycle = attachment?.session as? any EmbeddedGraphicsSessionLifecycle else {
            deactivateClipboardSynchronization()
            return
        }
        GraphicsClipboardSyncOwnership.shared.activate(lifecycle)
    }

    private var isPaneVisibleInWindow: Bool {
        guard view.window != nil else { return false }
        var candidate: NSView? = view
        while let current = candidate {
            if current.isHidden { return false }
            candidate = current.superview
        }
        return true
    }

    private func deactivateClipboardSynchronization() {
        guard let lifecycle = attachment?.session as? any EmbeddedGraphicsSessionLifecycle else { return }
        GraphicsClipboardSyncOwnership.shared.deactivate(lifecycle)
    }

    private func isCurrentAttachment(generation: UInt64) -> Bool {
        didCloseRuntime == false
            && attachment != nil
            && attachmentGeneration == generation
    }

    private func makeRow(label: String, value: NSTextField) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        value.font = .systemFont(ofSize: NSFont.systemFontSize)
        value.lineBreakMode = .byTruncatingMiddle
        value.maximumNumberOfLines = 1
        value.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [title, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalToConstant: 82),
            title.heightAnchor.constraint(equalToConstant: 22),
            value.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            value.heightAnchor.constraint(equalToConstant: 22)
        ])

        return row
    }

    @objc private func copyDiagnosticButtonPressed() {
        copyDiagnosticSummary()
    }

    private func diagnosticSummary() -> String {
        [
            "\(L10n.Graphics.title)：\(diagnostic.protocolName)",
            "\(L10n.Graphics.endpointDetail)：\(diagnostic.host):\(diagnostic.port)",
            "\(L10n.Graphics.runtimeStatus)：\(diagnostic.status)",
            "\(L10n.Graphics.adapterPath)：\(diagnostic.adapterPath ?? L10n.Graphics.missingAdapter)",
            "\(L10n.Graphics.launchArguments)：\(argumentsValue.stringValue)"
        ].joined(separator: "\n")
    }

    private func visibleText(_ textField: NSTextField) -> String? {
        guard isEffectivelyVisible(textField) else { return nil }
        return textField.stringValue
    }

    private func isEffectivelyVisible(_ candidate: NSView) -> Bool {
        var current: NSView? = candidate
        while let view = current {
            if view.isHidden {
                return false
            }
            if view === self.view {
                return true
            }
            current = view.superview
        }
        return false
    }

    private static func summaryText(for diagnostic: GraphicsSessionDiagnostic) -> String {
        if case .externalClient = diagnostic.presentation {
            return diagnostic.status
        }
        if diagnostic.adapterPath == nil || diagnostic.status.contains("缺少") || diagnostic.status.contains("失败") {
            return "\(L10n.Graphics.missingAdapterSummary)：\(diagnostic.status)"
        }
        if diagnostic.status.contains("正在建立") || diagnostic.status.contains("已启动") || diagnostic.status.contains("已打开") {
            return "\(L10n.Graphics.runningSummary)：\(diagnostic.status)"
        }
        return "\(L10n.Graphics.diagnosticSummary)：\(diagnostic.status)"
    }

    private static func engineText(for diagnostic: GraphicsSessionDiagnostic) -> String {
        if case .externalClient(let clientName) = diagnostic.presentation {
            return L10n.Graphics.externalClientEngine(clientName)
        }
        return L10n.Graphics.engine(diagnostic.protocolName)
    }

    private static func statusImage(for diagnostic: GraphicsSessionDiagnostic) -> NSImage? {
        if diagnostic.adapterPath == nil || diagnostic.status.contains("缺少") || diagnostic.status.contains("无效") || diagnostic.status.contains("失败") {
            return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: L10n.Graphics.status)
        }
        if diagnostic.status.contains("正在建立") || diagnostic.status.contains("已启动") || diagnostic.status.contains("已打开") {
            return NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: L10n.Graphics.status)
        }
        return NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: L10n.Graphics.status)
    }

    private static func statusColor(for diagnostic: GraphicsSessionDiagnostic) -> NSColor {
        if diagnostic.adapterPath == nil || diagnostic.status.contains("缺少") || diagnostic.status.contains("无效") || diagnostic.status.contains("失败") {
            return StacioDesignSystem.theme.warningColor
        }
        if diagnostic.status.contains("正在建立") || diagnostic.status.contains("已启动") || diagnostic.status.contains("已打开") {
            return StacioDesignSystem.theme.accentColor
        }
        return StacioDesignSystem.theme.secondaryTextColor
    }
}
