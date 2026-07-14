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

public final class GraphicsSessionPaneViewController: NSViewController {
    public let runtimeID: String
    public let diagnostic: GraphicsSessionDiagnostic
    private let onClose: ((String) -> Void)?
    private let attachment: GraphicsRuntimeAttachment?
    private var didCloseRuntime = false
    private var copiedDiagnosticSummary = ""
    private var renderSurfaceView: GraphicsRenderSurfaceView?

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

    public func closeGraphicsRuntime() {
        guard !didCloseRuntime else { return }
        didCloseRuntime = true
        onClose?(runtimeID)
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

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(container)

        if let attachment {
            let surface = makeRenderSurface(for: attachment)
            container.addSubview(surface)
            renderSurfaceView = surface
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                surface.topAnchor.constraint(equalTo: container.topAnchor),
                surface.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            view = container
            return
        }

        if case .externalClient = diagnostic.presentation {
            configureExternalClientLayout(in: container)
            view = container
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

        view = container
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

    private func makeRenderSurface(for attachment: GraphicsRuntimeAttachment) -> GraphicsRenderSurfaceView {
        let surface = GraphicsRenderSurfaceView(frame: .zero)
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.inputHandler = { [weak session = attachment.session] event in
            session?.sendInput(event)
        }
        attachment.session.onFrame = { [weak surface] frame in
            if Thread.isMainThread {
                surface?.display(frame)
            } else {
                DispatchQueue.main.async {
                    surface?.display(frame)
                }
            }
        }
        attachment.session.onPointerPosition = { [weak surface] x, y in
            if Thread.isMainThread {
                surface?.updateRemotePointerPosition(x: x, y: y)
            } else {
                DispatchQueue.main.async {
                    surface?.updateRemotePointerPosition(x: x, y: y)
                }
            }
        }
        attachment.session.onPointerVisibilityChanged = { [weak surface] isVisible in
            if Thread.isMainThread {
                surface?.setRemotePointerVisible(isVisible)
            } else {
                DispatchQueue.main.async {
                    surface?.setRemotePointerVisible(isVisible)
                }
            }
        }
        attachment.session.onPointerBitmap = { [weak surface] bitmap in
            if Thread.isMainThread {
                surface?.setRemotePointerBitmap(bitmap)
            } else {
                DispatchQueue.main.async {
                    surface?.setRemotePointerBitmap(bitmap)
                }
            }
        }
        return surface
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
