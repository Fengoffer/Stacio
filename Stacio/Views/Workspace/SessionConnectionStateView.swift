import AppKit
import QuartzCore

public enum SessionConnectionPhase: Equatable {
    case connecting
    case reconnecting
    case failed(message: String)

    var statusText: String {
        switch self {
        case .connecting:
            return L10n.TerminalLifecycle.connecting
        case .reconnecting:
            return L10n.TerminalLifecycle.reconnecting
        case let .failed(message):
            return message
        }
    }

    var isInProgress: Bool {
        switch self {
        case .connecting, .reconnecting:
            return true
        case .failed:
            return false
        }
    }

    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

public final class SessionConnectionStateView: NSView {
    private let progressIndicator = NSProgressIndicator()
    private let failureIconView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let endpointLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(
        title: L10n.TerminalLifecycle.reconnect,
        target: nil,
        action: nil
    )
    private var endpointPreferredWidthConstraint: NSLayoutConstraint?
    private var presentationGeneration: UInt64 = 0
    private var retryAction: (() -> Void)?

    public private(set) var phase: SessionConnectionPhase
    public private(set) var protocolName: String
    public private(set) var endpoint: String

    public init(
        protocolName: String,
        endpoint: String,
        phase: SessionConnectionPhase = .connecting
    ) {
        self.protocolName = protocolName
        self.endpoint = endpoint
        self.phase = phase
        super.init(frame: .zero)
        configureView()
        updateLabels()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        StacioDesignSystem.refreshDynamicLayerColors(in: self)
    }

    public func update(
        phase: SessionConnectionPhase,
        protocolName: String? = nil,
        endpoint: String? = nil
    ) {
        self.phase = phase
        if let protocolName {
            self.protocolName = protocolName
        }
        if let endpoint {
            self.endpoint = endpoint
        }
        updateLabels()
    }

    public func setRetryAction(
        title: String,
        action: (() -> Void)?
    ) {
        retryAction = action
        retryButton.title = title
        retryButton.setAccessibilityLabel(title)
        retryButton.invalidateIntrinsicContentSize()
        updatePhasePresentation()
    }

    public func setPresented(_ presented: Bool, animated: Bool) {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let shouldAnimate = animated && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false

        if presented {
            isHidden = false
            updatePhasePresentation()
            guard shouldAnimate else {
                alphaValue = 1
                return
            }
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = StacioDesignSystem.theme.standardAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
            return
        }

        guard shouldAnimate, isHidden == false else {
            alphaValue = 0
            isHidden = true
            progressIndicator.stopAnimation(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = StacioDesignSystem.theme.standardAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.isHidden = true
            self.progressIndicator.stopAnimation(nil)
            self.updatePhasePresentation()
        }
    }

    public var visibleTextForTesting: String {
        guard isHidden == false else { return "" }
        return [statusLabel.stringValue, endpointLabel.stringValue]
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    public var progressIndicatorSizeForTesting: NSSize {
        progressIndicator.frame.size
    }

    public var isRetryButtonVisibleForTesting: Bool {
        retryButton.isHidden == false
    }

    public var failureIconVisibleForTesting: Bool {
        failureIconView.isHidden == false
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(self)
        setAccessibilityIdentifier("Stacio.ConnectionState")
        isHidden = true
        alphaValue = 0

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.isIndeterminate = true
        progressIndicator.usesThreadedAnimation = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        failureIconView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: L10n.TerminalLifecycle.connectionFailed
        )
        failureIconView.contentTintColor = StacioDesignSystem.theme.dangerColor
        failureIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
        failureIconView.imageScaling = .scaleProportionallyDown
        failureIconView.isHidden = true
        failureIconView.translatesAutoresizingMaskIntoConstraints = false
        failureIconView.setAccessibilityIdentifier("Stacio.ConnectionState.failureIcon")

        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 560
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityIdentifier("Stacio.ConnectionState.status")

        endpointLabel.alignment = .center
        endpointLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        endpointLabel.textColor = .secondaryLabelColor
        endpointLabel.lineBreakMode = .byTruncatingMiddle
        endpointLabel.maximumNumberOfLines = 1
        endpointLabel.translatesAutoresizingMaskIntoConstraints = false
        endpointLabel.setAccessibilityIdentifier("Stacio.ConnectionState.endpoint")

        retryButton.target = self
        retryButton.action = #selector(retryButtonPressed)
        retryButton.bezelStyle = .rounded
        retryButton.isBordered = false
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setAccessibilityIdentifier("Stacio.ConnectionState.retry")
        retryButton.setAccessibilityLabel(L10n.TerminalLifecycle.reconnect)
        StacioDesignSystem.stylePrimaryButton(retryButton)

        let textStack = NSStackView(views: [statusLabel, endpointLabel])
        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [progressIndicator, failureIconView, textStack, retryButton])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)
        let endpointPreferredWidth = endpointLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        endpointPreferredWidth.priority = .defaultHigh
        endpointPreferredWidthConstraint = endpointPreferredWidth
        NSLayoutConstraint.activate([
            progressIndicator.widthAnchor.constraint(equalToConstant: 32),
            progressIndicator.heightAnchor.constraint(equalToConstant: 32),
            failureIconView.widthAnchor.constraint(equalToConstant: 32),
            failureIconView.heightAnchor.constraint(equalToConstant: 32),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            endpointLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            retryButton.heightAnchor.constraint(equalToConstant: 30),
            endpointPreferredWidth,
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func updateLabels() {
        statusLabel.stringValue = phase.statusText
        updatePhasePresentation()
        let trimmedProtocol = protocolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedProtocol.isEmpty, trimmedEndpoint.isEmpty) {
        case (false, false):
            endpointLabel.stringValue = "\(trimmedProtocol) · \(trimmedEndpoint)"
        case (false, true):
            endpointLabel.stringValue = trimmedProtocol
        case (true, false):
            endpointLabel.stringValue = trimmedEndpoint
        case (true, true):
            endpointLabel.stringValue = ""
        }
        endpointLabel.isHidden = endpointLabel.stringValue.isEmpty
        endpointLabel.invalidateIntrinsicContentSize()
        let naturalEndpointWidth = endpointLabel.cell?.cellSize.width ?? endpointLabel.fittingSize.width
        endpointPreferredWidthConstraint?.constant = endpointLabel.isHidden
            ? 0
            : min(520, ceil(naturalEndpointWidth) + 1)
        setAccessibilityLabel(
            endpointLabel.stringValue.isEmpty
                ? statusLabel.stringValue
                : "\(statusLabel.stringValue)，\(endpointLabel.stringValue)"
        )
    }

    private func updatePhasePresentation() {
        let inProgress = phase.isInProgress
        let isFailure = phase.isFailure
        progressIndicator.isHidden = !inProgress
        failureIconView.isHidden = !isFailure
        retryButton.isHidden = !isFailure || retryAction == nil
        if inProgress, isHidden == false {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        statusLabel.textColor = isFailure
            ? StacioDesignSystem.theme.primaryTextColor
            : .labelColor
    }

    @objc
    private func retryButtonPressed() {
        retryAction?()
    }
}
