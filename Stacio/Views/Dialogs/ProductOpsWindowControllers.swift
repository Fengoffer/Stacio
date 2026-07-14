import AppKit

public enum FeedbackSubmissionState: Equatable {
    case draft
    case submitting
    case failed
    case succeeded
}

@MainActor
public final class FeedbackWindowController: NSWindowController {
    private let configuration: ProductOpsConfiguration
    private let context: FeedbackDiagnosticContext
    private let submitter: FeedbackSubmitting
    private let idempotencyStore: FeedbackIdempotencyKeyStoring

    private let titleField = NSTextField()
    private let typePopup = NSPopUpButton()
    private let descriptionTextView = NSTextView()
    private let contactField = NSTextField()
    private let diagnosticsLabel = NSTextField(labelWithString: "")
    private let includeDiagnosticsCheckbox = NSButton(
        checkboxWithTitle: L10n.ProductOps.feedbackIncludeDiagnostics,
        target: nil,
        action: nil
    )
    private let previewDiagnosticsButton = NSButton(
        title: L10n.ProductOps.feedbackPreviewDiagnostics,
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyErrorButton = NSButton(title: L10n.ProductOps.copyError, target: nil, action: nil)
    private let submitButton = NSButton(title: L10n.ProductOps.submitFeedback, target: nil, action: nil)
    private var lastErrorDescription = ""
    public private(set) var submissionState: FeedbackSubmissionState = .draft

    public var shouldReuseAfterClose: Bool {
        submissionState != .succeeded
    }

    public init(
        configuration: ProductOpsConfiguration,
        context: FeedbackDiagnosticContext,
        submitter: FeedbackSubmitting? = nil,
        idempotencyStore: FeedbackIdempotencyKeyStoring = FeedbackIdempotencyKeyStore()
    ) {
        self.configuration = configuration
        self.context = context
        self.submitter = submitter ?? FeedbackSubmissionService(configuration: configuration)
        self.idempotencyStore = idempotencyStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.ProductOps.feedbackTitle
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = makeContentView()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func submitPressed(_ sender: Any?) {
        submitCurrentReport(requiresConfirmation: true)
    }

    func submitCurrentReportForTesting() {
        submitCurrentReport(requiresConfirmation: false)
    }

    private func submitCurrentReport(requiresConfirmation: Bool) {
        guard submissionState != .submitting,
              submissionState != .succeeded
        else {
            return
        }
        let report = currentReport()
        let validationErrors = report.validationErrors
        guard validationErrors.isEmpty else {
            renderSubmissionFailure(validationErrors.map(\.displayName).joined(separator: "；"))
            return
        }
        guard requiresConfirmation == false || confirmSubmission() else {
            return
        }
        let idempotencyKey = idempotencyStore.key(for: report, context: context)
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.stringValue = L10n.ProductOps.feedbackSubmitting
        submitButton.isEnabled = false
        copyErrorButton.isHidden = true
        submissionState = .submitting

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await submitter.submit(
                    report: report,
                    context: context,
                    idempotencyKey: idempotencyKey
                )
                idempotencyStore.clearKey(for: report, context: context, matching: idempotencyKey)
                submissionState = .succeeded
                statusLabel.textColor = StacioDesignSystem.theme.successColor
                statusLabel.stringValue = L10n.ProductOps.feedbackSubmitted
            } catch {
                renderSubmissionFailure(error.localizedDescription)
            }
            if submissionState != .succeeded {
                submitButton.isEnabled = true
            }
        }
    }

    @objc private func copyErrorPressed(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastErrorDescription, forType: .string)
    }

    @objc private func previewDiagnosticsPressed(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.ProductOps.feedbackDiagnosticsPreviewTitle
        alert.informativeText = context.visibleSummary
        alert.addButton(withTitle: L10n.Common.ok)
        alert.runModal()
    }

    func renderSubmissionFailureForTesting(_ message: String) {
        renderSubmissionFailure(message)
    }

    private func renderSubmissionFailure(_ message: String) {
        lastErrorDescription = message
        submissionState = .failed
        statusLabel.textColor = StacioDesignSystem.theme.dangerColor
        statusLabel.stringValue = L10n.ProductOps.feedbackFailedPrefix + message
        copyErrorButton.isHidden = false
        submitButton.isEnabled = true
    }

    private func currentReport() -> FeedbackReport {
        FeedbackReport(
            title: titleField.stringValue,
            type: FeedbackType.allCases[safe: typePopup.indexOfSelectedItem] ?? .other,
            description: descriptionTextView.string,
            contact: contactField.stringValue,
            includeDiagnostics: includeDiagnosticsCheckbox.state == .on
        )
    }

    private func confirmSubmission() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.ProductOps.feedbackConfirmTitle
        alert.informativeText = L10n.ProductOps.feedbackConfirmMessage
        alert.addButton(withTitle: L10n.ProductOps.submitFeedback)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func makeContentView() -> NSView {
        let root = StacioAppearanceRefreshView()
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(root)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        stack.addArrangedSubview(header(title: L10n.ProductOps.feedbackTitle, subtitle: L10n.ProductOps.feedbackSubtitle))
        stack.addArrangedSubview(formRow(label: L10n.ProductOps.feedbackTitleField, control: titleField))
        titleField.placeholderString = "例如：连接后状态没有刷新"
        titleField.setAccessibilityIdentifier("Stacio.Feedback.title")
        StacioDesignSystem.styleTextField(titleField)

        typePopup.addItems(withTitles: FeedbackType.allCases.map(\.displayName))
        typePopup.setAccessibilityIdentifier("Stacio.Feedback.type")
        StacioDesignSystem.stylePopupButton(typePopup)
        stack.addArrangedSubview(formRow(label: L10n.ProductOps.feedbackType, control: typePopup))

        let descriptionScroll = NSScrollView()
        descriptionScroll.hasVerticalScroller = true
        descriptionScroll.borderType = .bezelBorder
        descriptionScroll.translatesAutoresizingMaskIntoConstraints = false
        descriptionScroll.setAccessibilityIdentifier("Stacio.Feedback.description")
        descriptionTextView.minSize = NSSize(width: 0, height: 140)
        descriptionTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        descriptionTextView.isVerticallyResizable = true
        descriptionTextView.isHorizontallyResizable = false
        descriptionTextView.autoresizingMask = [.width]
        descriptionTextView.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        descriptionTextView.textContainer?.widthTracksTextView = true
        descriptionTextView.font = .systemFont(ofSize: NSFont.systemFontSize)
        descriptionTextView.textColor = StacioDesignSystem.theme.primaryTextColor
        descriptionScroll.documentView = descriptionTextView
        NSLayoutConstraint.activate([
            descriptionScroll.widthAnchor.constraint(equalToConstant: 520),
            descriptionScroll.heightAnchor.constraint(equalToConstant: 150)
        ])
        stack.addArrangedSubview(labeledBlock(label: L10n.ProductOps.feedbackDescription, control: descriptionScroll))

        contactField.placeholderString = "邮箱，选填"
        contactField.setAccessibilityIdentifier("Stacio.Feedback.contact")
        StacioDesignSystem.styleTextField(contactField)
        stack.addArrangedSubview(formRow(label: L10n.ProductOps.feedbackContact, control: contactField))

        diagnosticsLabel.stringValue = context.visibleSummary
        diagnosticsLabel.setAccessibilityIdentifier("Stacio.Feedback.diagnostics")
        diagnosticsLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        diagnosticsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        diagnosticsLabel.maximumNumberOfLines = 0
        includeDiagnosticsCheckbox.setAccessibilityIdentifier("Stacio.Feedback.includeDiagnostics")
        includeDiagnosticsCheckbox.font = .systemFont(ofSize: NSFont.systemFontSize)
        previewDiagnosticsButton.target = self
        previewDiagnosticsButton.action = #selector(previewDiagnosticsPressed(_:))
        previewDiagnosticsButton.setAccessibilityIdentifier("Stacio.Feedback.previewDiagnostics")
        StacioDesignSystem.styleSheetButton(previewDiagnosticsButton)
        let diagnosticsControls = NSStackView()
        diagnosticsControls.orientation = .horizontal
        diagnosticsControls.spacing = 8
        diagnosticsControls.alignment = .centerY
        diagnosticsControls.addArrangedSubview(includeDiagnosticsCheckbox)
        diagnosticsControls.addArrangedSubview(previewDiagnosticsButton)
        let diagnosticsStack = NSStackView()
        diagnosticsStack.orientation = .vertical
        diagnosticsStack.alignment = .leading
        diagnosticsStack.spacing = 8
        diagnosticsStack.addArrangedSubview(diagnosticsControls)
        diagnosticsStack.addArrangedSubview(diagnosticsLabel)
        stack.addArrangedSubview(labeledBlock(label: L10n.ProductOps.feedbackDiagnostics, control: diagnosticsStack))

        statusLabel.setAccessibilityIdentifier("Stacio.Feedback.status")
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(statusLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        copyErrorButton.target = self
        copyErrorButton.action = #selector(copyErrorPressed(_:))
        copyErrorButton.isHidden = true
        copyErrorButton.setAccessibilityIdentifier("Stacio.Feedback.copyError")
        StacioDesignSystem.styleSheetButton(copyErrorButton)
        submitButton.target = self
        submitButton.action = #selector(submitPressed(_:))
        submitButton.setAccessibilityIdentifier("Stacio.Feedback.submit")
        StacioDesignSystem.styleSheetButton(submitButton, isDefault: true)
        buttons.addArrangedSubview(copyErrorButton)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(submitButton)
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24)
        ])
        return root
    }
}

@MainActor
public final class UpdatePromptWindowController: NSWindowController {
    private let configuration: ProductOpsConfiguration?
    private let checker: UpdateChecking?
    private let urlOpener: ProductOpsURLOpening
    private let sparkleChecker: SparkleUpdateChecking?
    private weak var actionHandler: SparkleUpdateActionHandling?

    private let statusLabel = NSTextField(labelWithString: "")
    private let detailsLabel = NSTextField(labelWithString: "")
    private let releaseNotesView = NSTextView()
    private let checkButton = NSButton(title: L10n.ProductOps.checkUpdates, target: nil, action: nil)
    private let downloadButton = NSButton(title: L10n.ProductOps.openDownloadPage, target: nil, action: nil)
    private let laterButton = NSButton(title: L10n.ProductOps.updateLater, target: nil, action: nil)
    private let skipButton = NSButton(title: L10n.ProductOps.updateSkipVersion, target: nil, action: nil)
    private var pendingDownloadURL: URL?
    private var pendingSparkleUpdate: SparkleUpdatePromptInfo?

    public convenience init(
        configuration: ProductOpsConfiguration,
        checker: UpdateChecking? = nil,
        urlOpener: ProductOpsURLOpening? = nil
    ) {
        self.init(
            configuration: configuration,
            checker: checker ?? UpdateCheckService(configuration: configuration),
            urlOpener: urlOpener ?? WorkspaceProductOpsURLOpener(),
            sparkleChecker: nil,
            actionHandler: nil
        )
    }

    public convenience init(
        sparkleChecker: SparkleUpdateChecking,
        actionHandler: SparkleUpdateActionHandling?
    ) {
        self.init(
            configuration: nil,
            checker: nil,
            urlOpener: WorkspaceProductOpsURLOpener(),
            sparkleChecker: sparkleChecker,
            actionHandler: actionHandler
        )
    }

    private init(
        configuration: ProductOpsConfiguration?,
        checker: UpdateChecking?,
        urlOpener: ProductOpsURLOpening,
        sparkleChecker: SparkleUpdateChecking?,
        actionHandler: SparkleUpdateActionHandling?
    ) {
        self.configuration = configuration
        self.checker = checker
        self.urlOpener = urlOpener
        self.sparkleChecker = sparkleChecker
        self.actionHandler = actionHandler
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.ProductOps.updateTitle
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = makeContentView()
        renderInitialState()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func renderStatusForTesting(_ status: UpdateCheckStatus) {
        render(status)
    }

    func renderFailureForTesting(_ message: String) {
        renderFailure(message)
    }

    func renderManualStateForTesting(_ state: SparkleManualUpdateCheckState) {
        renderManualState(state)
    }

    public func beginManualCheck(_ sender: Any?) {
        guard let sparkleChecker else {
            checkPressed(sender)
            return
        }
        sparkleChecker.checkForUpdateInformation(sender) { [weak self] state in
            self?.renderManualState(state)
        }
    }

    @objc private func checkPressed(_ sender: Any?) {
        if sparkleChecker != nil {
            beginManualCheck(sender)
            return
        }
        guard let checker else {
            renderFailure("更新检查器不可用。")
            return
        }
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.stringValue = L10n.ProductOps.updateChecking
        checkButton.isEnabled = false
        downloadButton.isHidden = true
        pendingDownloadURL = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await checker.checkForUpdates()
                render(status)
            } catch {
                renderFailure(error.localizedDescription)
            }
            checkButton.isEnabled = true
        }
    }

    @objc private func downloadPressed(_ sender: Any?) {
        if let pendingSparkleUpdate {
            actionHandler?.downloadUpdate(pendingSparkleUpdate)
            close()
            return
        }
        guard let pendingDownloadURL else {
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.ProductOps.updateConfirmTitle
        alert.informativeText = L10n.ProductOps.updateConfirmMessage
        alert.addButton(withTitle: L10n.ProductOps.openDownloadPage)
        alert.addButton(withTitle: L10n.Common.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        urlOpener.open(pendingDownloadURL)
    }

    @objc private func laterPressed(_ sender: Any?) {
        guard let pendingSparkleUpdate else {
            return
        }
        actionHandler?.remindLater(pendingSparkleUpdate)
        close()
    }

    @objc private func skipPressed(_ sender: Any?) {
        guard let pendingSparkleUpdate else {
            return
        }
        actionHandler?.skip(pendingSparkleUpdate)
        close()
    }

    private func renderInitialState() {
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        if let configuration {
            statusLabel.stringValue = "\(L10n.ProductOps.updateInitial)\n通道：\(configuration.effectiveUpdateChannel.displayName)"
        } else {
            statusLabel.stringValue = L10n.ProductOps.updateInitial
        }
        detailsLabel.stringValue = ""
        releaseNotesView.string = ""
        downloadButton.isHidden = true
        laterButton.isHidden = true
        skipButton.isHidden = true
        pendingDownloadURL = nil
        pendingSparkleUpdate = nil
    }

    private func render(_ status: UpdateCheckStatus) {
        switch status {
        case .upToDate:
            statusLabel.textColor = StacioDesignSystem.theme.successColor
            statusLabel.stringValue = L10n.ProductOps.updateUpToDate
            releaseNotesView.string = ""
            downloadButton.isHidden = true
            laterButton.isHidden = true
            skipButton.isHidden = true
            pendingDownloadURL = nil
        case .updateAvailable(let update):
            statusLabel.textColor = StacioDesignSystem.theme.warningColor
            statusLabel.stringValue = L10n.ProductOps.updateAvailable(version: update.version, build: update.build)
            releaseNotesView.string = update.releaseNotes
            pendingDownloadURL = update.artifactURL
            downloadButton.isHidden = update.artifactURL == nil
        case .appcastUnavailable(let message):
            renderFailure("Appcast 不可用：\(message)")
        case .noVersionInAppcast:
            renderFailure("Appcast 未包含可用版本。")
        case .signatureFailure(let message):
            renderFailure("更新签名校验失败：\(message)")
        case .downloadFailure(let message):
            renderFailure("更新下载失败：\(message)")
        }
    }

    private func renderManualState(_ state: SparkleManualUpdateCheckState) {
        pendingDownloadURL = nil
        switch state {
        case .checking:
            statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
            statusLabel.stringValue = L10n.ProductOps.updateChecking
            detailsLabel.stringValue = ""
            releaseNotesView.string = ""
            pendingSparkleUpdate = nil
            setSparkleActionButtonsHidden(true)
            checkButton.isEnabled = false
        case .upToDate:
            statusLabel.textColor = StacioDesignSystem.theme.successColor
            statusLabel.stringValue = L10n.ProductOps.updateUpToDate
            detailsLabel.stringValue = ""
            releaseNotesView.string = ""
            pendingSparkleUpdate = nil
            setSparkleActionButtonsHidden(true)
            checkButton.isEnabled = true
        case .available(let update):
            statusLabel.textColor = StacioDesignSystem.theme.warningColor
            statusLabel.stringValue = L10n.ProductOps.updateAvailable(version: update.version, build: update.build)
            detailsLabel.stringValue = Self.updateDetailsText(update)
            releaseNotesView.string = update.releaseNotes.isEmpty
                ? L10n.ProductOps.updateReleaseNotesUnavailable
                : update.releaseNotes.stacioPlainReleaseNotesForDisplay()
            pendingSparkleUpdate = update
            downloadButton.title = L10n.ProductOps.updateDownload
            setSparkleActionButtonsHidden(false)
            checkButton.isEnabled = true
        case .failed(let message):
            statusLabel.textColor = StacioDesignSystem.theme.dangerColor
            statusLabel.stringValue = L10n.ProductOps.updateFailedPrefix + message
            detailsLabel.stringValue = ""
            releaseNotesView.string = ""
            pendingSparkleUpdate = nil
            setSparkleActionButtonsHidden(true)
            checkButton.isEnabled = true
        }
    }

    private func setSparkleActionButtonsHidden(_ hidden: Bool) {
        downloadButton.isHidden = hidden
        laterButton.isHidden = hidden
        skipButton.isHidden = hidden
    }

    private static func updateDetailsText(_ update: SparkleUpdatePromptInfo) -> String {
        var parts = ["Version \(update.version)", "Build \(update.build)"]
        if let packageSize = update.packageSize {
            let clampedSize = Int64(min(packageSize, UInt64(Int64.max)))
            parts.append(ByteCountFormatter.string(fromByteCount: clampedSize, countStyle: .file))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func renderFailure(_ message: String) {
        statusLabel.textColor = StacioDesignSystem.theme.dangerColor
        statusLabel.stringValue = L10n.ProductOps.updateFailedPrefix + message
        detailsLabel.stringValue = ""
        releaseNotesView.string = ""
        downloadButton.isHidden = true
        laterButton.isHidden = true
        skipButton.isHidden = true
        pendingDownloadURL = nil
        pendingSparkleUpdate = nil
    }

    private func makeContentView() -> NSView {
        let root = StacioAppearanceRefreshView()
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(root)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        stack.addArrangedSubview(header(title: L10n.ProductOps.updateTitle, subtitle: L10n.ProductOps.updateInitial))
        statusLabel.setAccessibilityIdentifier("Stacio.Update.status")
        statusLabel.maximumNumberOfLines = 0
        stack.addArrangedSubview(statusLabel)

        detailsLabel.setAccessibilityIdentifier("Stacio.Update.details")
        detailsLabel.maximumNumberOfLines = 0
        detailsLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        stack.addArrangedSubview(detailsLabel)

        let notesScroll = NSScrollView()
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .bezelBorder
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        releaseNotesView.isEditable = false
        releaseNotesView.font = .systemFont(ofSize: NSFont.systemFontSize)
        releaseNotesView.textColor = StacioDesignSystem.theme.primaryTextColor
        releaseNotesView.setAccessibilityIdentifier("Stacio.Update.releaseNotes")
        notesScroll.documentView = releaseNotesView
        stack.addArrangedSubview(labeledBlock(label: L10n.ProductOps.releaseNotes, control: notesScroll))
        NSLayoutConstraint.activate([
            notesScroll.widthAnchor.constraint(equalToConstant: 500),
            notesScroll.heightAnchor.constraint(equalToConstant: 180)
        ])

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        checkButton.target = self
        checkButton.action = #selector(checkPressed(_:))
        checkButton.setAccessibilityIdentifier("Stacio.Update.check")
        StacioDesignSystem.styleSheetButton(checkButton, isDefault: true)
        downloadButton.target = self
        downloadButton.action = #selector(downloadPressed(_:))
        downloadButton.setAccessibilityIdentifier("Stacio.Update.download")
        StacioDesignSystem.styleSheetButton(downloadButton)
        laterButton.target = self
        laterButton.action = #selector(laterPressed(_:))
        laterButton.setAccessibilityIdentifier("Stacio.Update.later")
        StacioDesignSystem.styleSheetButton(laterButton)
        skipButton.target = self
        skipButton.action = #selector(skipPressed(_:))
        skipButton.setAccessibilityIdentifier("Stacio.Update.skip")
        StacioDesignSystem.styleSheetButton(skipButton)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(skipButton)
        buttons.addArrangedSubview(laterButton)
        buttons.addArrangedSubview(downloadButton)
        buttons.addArrangedSubview(checkButton)
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24)
        ])
        return root
    }
}

@MainActor
public final class LicenseWindowController: NSWindowController {
    private let configuration: ProductOpsConfiguration
    private let service: LicenseService
    private let onlineValidator: LicenseOnlineValidating
    private let activationStore: LicenseActivationRecordStoring
    private let deviceIDStore: AnonymousDeviceIdentifierStore
    private let nowProvider: () -> Date
    private let statusLabel = NSTextField(labelWithString: "")
    private let licenseKeyField = NSSecureTextField()
    private let usernameField = NSTextField()
    private let emailField = NSTextField()
    private let tokenTextView = NSTextView()
    private let actionStatusLabel = NSTextField(labelWithString: "")
    private let validateButton = NSButton(title: L10n.ProductOps.validateOnline, target: nil, action: nil)
    private var onlineValidationTask: Task<Void, Never>?
    private var onlineValidationRunID: UUID?

    public init(
        configuration: ProductOpsConfiguration = ProductOpsConfigurationStore().load(),
        service: LicenseService = LicenseService(),
        onlineValidator: LicenseOnlineValidating? = nil,
        activationStore: LicenseActivationRecordStoring = LicenseKeychainStore(),
        deviceIDStore: AnonymousDeviceIdentifierStore = .shared,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.service = service
        self.onlineValidator = onlineValidator ?? LicenseOnlineValidationService(configuration: configuration)
        self.activationStore = activationStore
        self.deviceIDStore = deviceIDStore
        self.nowProvider = nowProvider
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.ProductOps.licenseTitle
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
        refreshStatus()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func applyOfflineTokenPressed(_ sender: Any?) {
        guard let data = tokenTextView.string.data(using: .utf8) else {
            renderLicenseActionFailure(ProductOpsError.invalidOfflineLicenseToken.localizedDescription)
            return
        }
        do {
            _ = try applyOfflineLicenseData(data)
            actionStatusLabel.textColor = StacioDesignSystem.theme.successColor
            actionStatusLabel.stringValue = L10n.ProductOps.licenseTokenApplied
            refreshStatus()
        } catch {
            renderLicenseActionFailure(error.localizedDescription)
        }
    }

    @objc private func importOfflineLicenseFilePressed(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.ProductOps.importOfflineLicenseFile
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importOfflineLicenseFile(at: url)
        }
    }

    func importOfflineLicenseFileForTesting(_ data: Data) {
        importOfflineLicenseData(data)
    }

    @objc private func validateOnlinePressed(_ sender: Any?) {
        let licenseKey = licenseKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard licenseKey.isEmpty == false, username.isEmpty == false, email.isEmpty == false else {
            renderOnlineValidationFailure(L10n.ProductOps.licenseMissingIdentity)
            return
        }
        actionStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        actionStatusLabel.stringValue = L10n.ProductOps.licenseValidatingOnline
        validateButton.isEnabled = false
        let request = LicenseValidationRequest(
            licenseKey: licenseKey,
            username: username,
            email: email,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? StacioAppMetadata.displayVersion,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
            anonymousDeviceID: deviceIDStore.deviceID()
        )
        onlineValidationTask?.cancel()
        let runID = UUID()
        onlineValidationRunID = runID
        onlineValidationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                finishOnlineValidationRun(runID)
            }
            do {
                let response = try await onlineValidator.validate(request)
                try Task.checkCancellation()
                guard isCurrentOnlineValidationRun(runID) else { return }
                let state = try service.state(
                    applyingOnlineValidation: response,
                    expected: request,
                    activationStore: activationStore,
                    now: nowProvider()
                )
                guard isCurrentOnlineValidationRun(runID) else { return }
                if state.status == .active || state.status == .trial {
                    actionStatusLabel.textColor = StacioDesignSystem.theme.successColor
                    actionStatusLabel.stringValue = L10n.ProductOps.licenseOnlineValidated
                } else {
                    actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
                    actionStatusLabel.stringValue = L10n.ProductOps.licenseOnlineCompleted(
                        status: state.status.displayName
                    )
                }
                refreshStatus()
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentOnlineValidationRun(runID) else { return }
                renderOnlineValidationFailure(error.localizedDescription)
            }
        }
    }

    private func isCurrentOnlineValidationRun(_ runID: UUID) -> Bool {
        onlineValidationRunID == runID && Task.isCancelled == false
    }

    private func finishOnlineValidationRun(_ runID: UUID) {
        guard onlineValidationRunID == runID else { return }
        onlineValidationRunID = nil
        onlineValidationTask = nil
        validateButton.isEnabled = true
    }

    private func cancelOnlineValidation() {
        onlineValidationRunID = nil
        onlineValidationTask?.cancel()
        onlineValidationTask = nil
        validateButton.isEnabled = true
    }

    private func renderOnlineValidationFailure(_ message: String) {
        actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
        actionStatusLabel.stringValue = L10n.ProductOps.licenseOnlineFailedPrefix + message
    }

    private func renderLicenseActionFailure(_ message: String) {
        actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
        actionStatusLabel.stringValue = L10n.ProductOps.licenseTokenFailedPrefix + message
    }

    private func renderLicenseFileImportFailure(_ message: String) {
        actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
        actionStatusLabel.stringValue = L10n.ProductOps.licenseFileImportFailedPrefix + message
    }

    private func importOfflineLicenseFile(at url: URL) {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            importOfflineLicenseData(data)
        } catch {
            renderLicenseFileImportFailure(error.localizedDescription)
        }
    }

    private func importOfflineLicenseData(_ data: Data) {
        do {
            _ = try applyOfflineLicenseData(data)
            tokenTextView.string = String(data: data, encoding: .utf8) ?? ""
            actionStatusLabel.textColor = StacioDesignSystem.theme.successColor
            actionStatusLabel.stringValue = L10n.ProductOps.licenseTokenApplied
            refreshStatus()
        } catch {
            renderLicenseFileImportFailure(error.localizedDescription)
        }
    }

    private func applyOfflineLicenseData(_ data: Data) throws -> LicenseState {
        if let token = try? JSONDecoder.productOps.decode(OfflineLicenseToken.self, from: data) {
            return try service.state(
                applyingOfflineToken: token,
                expectedUsername: usernameField.stringValue,
                expectedEmail: emailField.stringValue,
                activationStore: activationStore,
                now: nowProvider()
            )
        }
        guard let signedLicenseToken = Self.signedOfflineLicenseToken(from: data) else {
            throw ProductOpsError.invalidOfflineLicenseToken
        }
        return try service.state(
            applyingOfflineSignedToken: signedLicenseToken,
            expectedUsername: usernameField.stringValue,
            expectedEmail: emailField.stringValue,
            activationStore: activationStore,
            now: nowProvider()
        )
    }

    private static func signedOfflineLicenseToken(from data: Data) -> String? {
        if let envelope = try? JSONDecoder.productOps.decode(SignedOfflineLicenseFileEnvelope.self, from: data) {
            let candidate = envelope.signedLicenseToken
                ?? envelope.token
                ?? envelope.data?.signedLicenseToken
                ?? envelope.data?.token
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty == false {
                return trimmed
            }
        }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.hasPrefix("v1.") ? raw : nil
    }

    private func refreshStatus() {
        let state = service.loadState(now: nowProvider())
        var lines = [
            "\(L10n.ProductOps.licenseStatus)：\(state.status.displayName)",
            "\(L10n.ProductOps.licenseUser)：\(state.username.isEmpty ? "-" : state.username)",
            "\(L10n.ProductOps.licenseEmail)：\(state.email.isEmpty ? "-" : state.email)",
            "\(L10n.ProductOps.licensePlan)：\(state.plan.isEmpty ? "-" : state.plan)"
        ]
        if let expiresAt = state.expiresAt {
            lines.append("\(L10n.ProductOps.licenseExpires)：\(Self.dateFormatter.string(from: expiresAt))")
        }
        if let graceUntil = state.graceUntil {
            lines.append("\(L10n.ProductOps.licenseGraceUntil)：\(Self.dateFormatter.string(from: graceUntil))")
        }
        lines.append(L10n.ProductOps.licenseNoPrivateKey)
        statusLabel.stringValue = lines.joined(separator: "\n")
        if usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            usernameField.stringValue = state.username
        }
        if emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emailField.stringValue = state.email
        }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func makeContentView() -> NSView {
        let root = StacioAppearanceRefreshView()
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(root)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        stack.addArrangedSubview(header(title: L10n.ProductOps.licenseTitle, subtitle: L10n.ProductOps.licenseSubtitle))
        statusLabel.setAccessibilityIdentifier("Stacio.License.status")
        statusLabel.maximumNumberOfLines = 0
        statusLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        stack.addArrangedSubview(labeledBlock(label: L10n.ProductOps.licenseStatus, control: statusLabel))

        licenseKeyField.placeholderString = "STACIO-..."
        licenseKeyField.setAccessibilityIdentifier("Stacio.License.licenseKey")
        StacioDesignSystem.styleTextField(licenseKeyField)
        stack.addArrangedSubview(formRow(label: L10n.ProductOps.licenseKey, control: licenseKeyField))

        usernameField.placeholderString = "用户名"
        usernameField.setAccessibilityIdentifier("Stacio.License.username")
        StacioDesignSystem.styleTextField(usernameField)
        stack.addArrangedSubview(formRow(label: L10n.ProductOps.licenseUser, control: usernameField))

        emailField.placeholderString = "name@example.com"
        emailField.setAccessibilityIdentifier("Stacio.License.email")
        StacioDesignSystem.styleTextField(emailField)
        stack.addArrangedSubview(formRow(label: L10n.ProductOps.licenseEmail, control: emailField))

        let tokenScroll = NSScrollView()
        tokenScroll.hasVerticalScroller = true
        tokenScroll.borderType = .bezelBorder
        tokenScroll.translatesAutoresizingMaskIntoConstraints = false
        tokenScroll.setAccessibilityIdentifier("Stacio.License.offlineToken")
        tokenTextView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tokenTextView.textColor = StacioDesignSystem.theme.primaryTextColor
        tokenTextView.isHorizontallyResizable = false
        tokenTextView.textContainer?.widthTracksTextView = true
        tokenScroll.documentView = tokenTextView
        stack.addArrangedSubview(labeledBlock(label: L10n.ProductOps.licenseOfflineToken, control: tokenScroll))
        NSLayoutConstraint.activate([
            tokenScroll.widthAnchor.constraint(equalToConstant: 540),
            tokenScroll.heightAnchor.constraint(equalToConstant: 160)
        ])

        actionStatusLabel.setAccessibilityIdentifier("Stacio.License.actionStatus")
        actionStatusLabel.maximumNumberOfLines = 0
        actionStatusLabel.stringValue = L10n.ProductOps.licenseOnlineReserved
        actionStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        stack.addArrangedSubview(actionStatusLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        validateButton.target = self
        validateButton.action = #selector(validateOnlinePressed(_:))
        validateButton.setAccessibilityIdentifier("Stacio.License.validateOnline")
        StacioDesignSystem.styleSheetButton(validateButton)
        let applyButton = NSButton(title: L10n.ProductOps.applyOfflineToken, target: self, action: #selector(applyOfflineTokenPressed(_:)))
        applyButton.setAccessibilityIdentifier("Stacio.License.applyOfflineToken")
        StacioDesignSystem.styleSheetButton(applyButton, isDefault: true)
        let importButton = NSButton(
            title: L10n.ProductOps.importOfflineLicenseFile,
            target: self,
            action: #selector(importOfflineLicenseFilePressed(_:))
        )
        importButton.setAccessibilityIdentifier("Stacio.License.importOfflineLicenseFile")
        StacioDesignSystem.styleSheetButton(importButton)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(validateButton)
        buttons.addArrangedSubview(importButton)
        buttons.addArrangedSubview(applyButton)
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24)
        ])
        return root
    }
}

extension LicenseWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        cancelOnlineValidation()
    }
}

private struct SignedOfflineLicenseFileEnvelope: Decodable {
    var signedLicenseToken: String?
    var token: String?
    var data: SignedOfflineLicenseFilePayload?
}

private struct SignedOfflineLicenseFilePayload: Decodable {
    var signedLicenseToken: String?
    var token: String?
}

private func header(title: String, subtitle: String) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
    titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
    let subtitleLabel = NSTextField(labelWithString: subtitle)
    subtitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
    subtitleLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
    subtitleLabel.maximumNumberOfLines = 0
    stack.addArrangedSubview(titleLabel)
    stack.addArrangedSubview(subtitleLabel)
    return stack
}

private func formRow(label: String, control: NSView) -> NSView {
    let grid = NSGridView(views: [[formLabel(label), control]])
    grid.column(at: 0).width = 150
    grid.column(at: 1).xPlacement = .leading
    grid.row(at: 0).yPlacement = .center
    control.translatesAutoresizingMaskIntoConstraints = false
    control.widthAnchor.constraint(equalToConstant: 360).isActive = true
    return grid
}

private func labeledBlock(label: String, control: NSView) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.addArrangedSubview(formLabel(label))
    stack.addArrangedSubview(control)
    return stack
}

private func formLabel(_ value: String) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    label.textColor = StacioDesignSystem.theme.primaryTextColor
    return label
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
