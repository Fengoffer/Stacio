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
    private let fingerprintProvider: StacioDeviceFingerprintProvider
    private let offlineConfigurationStore: OfflineLicenseConfigurationStore
    private let offlineStatusRefresher: OfflineLicenseStatusRefreshing
    private let nowProvider: () -> Date
    private let persistedStateProvider: (() -> LicenseState)?
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusNoteLabel = NSTextField(labelWithString: "")
    private let statusHeadlineLabel = NSTextField(labelWithString: "")
    private let planBadgeLabel = NSTextField(labelWithString: "")
    private let userValueLabel = NSTextField(labelWithString: "-")
    private let emailValueLabel = NSTextField(labelWithString: "-")
    private let expiresValueLabel = NSTextField(labelWithString: "-")
    private let licenseKeyField = NSSecureTextField()
    private let usernameField = NSTextField()
    private let emailField = NSTextField()
    private let actionStatusLabel = NSTextField(labelWithString: "")
    private let validateButton = NSButton(title: L10n.ProductOps.validateOnline, target: nil, action: nil)
    private let activationFormStack = NSStackView()
    private let licenseActionStack = NSStackView()
    private let managementActionStack = NSStackView()
    private let refreshLicenseButton = NSButton(title: "同步许可", target: nil, action: nil)
    private let reimportLicenseButton = NSButton(title: "重新导入许可", target: nil, action: nil)
    private weak var contentStack: NSStackView?
    private var onlineValidationTask: Task<Void, Never>?
    private var onlineValidationRunID: UUID?
    private var activationRecordPresenceTask: Task<Void, Never>?
    private var licenseAuthorizationObserver: NSObjectProtocol?
    private var hasPersistedActivationRecord = false
    private var isReimporting = false

    public init(
        configuration: ProductOpsConfiguration = ProductOpsConfigurationStore().load(),
        service: LicenseService = LicenseService(),
        onlineValidator: LicenseOnlineValidating? = nil,
        activationStore: LicenseActivationRecordStoring = LicenseKeychainStore(),
        deviceIDStore: AnonymousDeviceIdentifierStore = .shared,
        fingerprintProvider: StacioDeviceFingerprintProvider = StacioDeviceFingerprintProvider(),
        offlineConfigurationStore: OfflineLicenseConfigurationStore = OfflineLicenseConfigurationStore(),
        offlineStatusRefresher: OfflineLicenseStatusRefreshing? = nil,
        persistedStateProvider: (() -> LicenseState)? = nil,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.service = service
        self.onlineValidator = onlineValidator ?? LicenseOnlineValidationService(configuration: configuration)
        self.activationStore = activationStore
        self.deviceIDStore = deviceIDStore
        self.fingerprintProvider = fingerprintProvider
        self.offlineConfigurationStore = offlineConfigurationStore
        self.offlineStatusRefresher = offlineStatusRefresher
            ?? OfflineLicenseStatusService(configuration: configuration)
        self.persistedStateProvider = persistedStateProvider
        self.nowProvider = nowProvider
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.ProductOps.licenseTitle
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 340)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
        observePersistedAuthorizationIfNeeded()
        loadActivationRecordPresenceIfNeeded()
        refreshStatus()
        resizeWindowToContent()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func importOfflineLicenseFilePressed(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.ProductOps.importOfflineLicenseFile
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importOfflineLicenseFile(at: url)
        }
    }

    func importOfflineLicenseFileForTesting(_ data: Data) async {
        await importOfflineLicenseData(data)
    }

    @objc private func exportDeviceFingerprintPressed(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = L10n.ProductOps.exportDeviceFingerprint
        panel.nameFieldStringValue = "Stacio-offline-request.stacio-offline-request"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    let configuration = try await OfflineLicenseConfigurationService(
                        apiBaseURL: self.configuration.apiBaseURL,
                        store: self.offlineConfigurationStore
                    ).fetch()
                    let exported = try OfflineLicenseFileCodec.exportDeviceFingerprint(
                        configuration: configuration,
                        fingerprintProvider: self.fingerprintProvider,
                        now: self.nowProvider()
                    )
                    try exported.data.write(to: url, options: .atomic)
                    StacioLogStore.shared.append(level: .info, category: "License",
                        message: "offline.fingerprint.exported fingerprintSource=\(exported.fingerprint.source.rawValue)")
                    self.actionStatusLabel.textColor = StacioDesignSystem.theme.successColor
                    self.actionStatusLabel.stringValue = L10n.ProductOps.deviceFingerprintExported(
                        source: exported.fingerprint.source.displayName)
                } catch { self.renderLicenseActionFailure(error.localizedDescription) }
            }
        }
    }

    @objc private func validateOnlinePressed(_ sender: Any?) {
        let licenseKey = licenseKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard licenseKey.isEmpty == false, username.isEmpty == false, email.isEmpty == false else {
            renderOnlineValidationFailure(L10n.ProductOps.licenseMissingIdentity)
            return
        }
        actionStatusLabel.isHidden = false
        actionStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        actionStatusLabel.stringValue = L10n.ProductOps.licenseValidatingOnline
        validateButton.isEnabled = false
        refreshLicenseButton.isEnabled = false
        resizeWindowToContent(hasAuthorization: managementActionStack.isHidden == false)
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
                let state = try await persistOnlineValidation(response, request: request)
                guard isCurrentOnlineValidationRun(runID) else { return }
                let completionColor: NSColor
                let completionMessage: String
                if state.status == .active || state.status == .trial {
                    completionColor = StacioDesignSystem.theme.successColor
                    completionMessage = L10n.ProductOps.licenseOnlineValidated
                } else {
                    completionColor = StacioDesignSystem.theme.dangerColor
                    completionMessage = L10n.ProductOps.licenseOnlineCompleted(
                        status: state.status.displayName
                    )
                }
                renderStatus(state)
                actionStatusLabel.isHidden = false
                actionStatusLabel.textColor = completionColor
                actionStatusLabel.stringValue = completionMessage
                resizeWindowToContent(hasAuthorization: shouldShowManagement(for: state))
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentOnlineValidationRun(runID) else { return }
                renderOnlineValidationFailure(error.localizedDescription)
            }
        }
    }

    @objc private func refreshLicensePressed(_ sender: Any?) {
        let state = persistedStateProvider?() ?? service.loadState(now: nowProvider())
        if let errorCode = state.lastAuthorizationSyncErrorCode,
           errorCode.isEmpty == false {
            actionStatusLabel.isHidden = false
            actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
            actionStatusLabel.stringValue = "授权已停止（\(errorCode)），请重新导入许可。"
            return
        }
        if let authorization = state.offlineDeviceAuthorization {
            refreshOfflineAuthorization(authorization)
            return
        }
        loadOnlineActivationForRefresh()
    }

    private func loadOnlineActivationForRefresh() {
        actionStatusLabel.isHidden = false
        actionStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        actionStatusLabel.stringValue = "正在读取本机许可..."
        refreshLicenseButton.isEnabled = false
        onlineValidationTask?.cancel()

        let activationStore = self.activationStore
        onlineValidationTask = Task { [weak self] in
            let readTask = Task.detached(priority: .userInitiated) {
                try activationStore.loadActivationRecord()
            }
            do {
                let record = try await withTaskCancellationHandler {
                    try await readTask.value
                } onCancel: {
                    readTask.cancel()
                }
                try Task.checkCancellation()
                guard let self else { return }
                onlineValidationTask = nil
                refreshLicenseButton.isEnabled = true
                guard let record else {
                    actionStatusLabel.textColor = StacioDesignSystem.theme.warningColor
                    actionStatusLabel.stringValue = "当前没有可同步的许可，请重新导入许可。"
                    return
                }
                licenseKeyField.stringValue = record.licenseKey
                usernameField.stringValue = record.username
                emailField.stringValue = record.email
                validateOnlinePressed(nil)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                onlineValidationTask = nil
                refreshLicenseButton.isEnabled = true
                actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
                actionStatusLabel.stringValue = "许可读取失败：\(error.localizedDescription)"
            }
        }
    }

    private func persistOnlineValidation(
        _ response: LicenseValidationResponse,
        request: LicenseValidationRequest
    ) async throws -> LicenseState {
        let service = self.service
        let activationStore = self.activationStore
        let now = nowProvider()
        let persistenceTask = Task.detached(priority: .userInitiated) {
            try service.state(
                applyingOnlineValidation: response,
                expected: request,
                activationStore: activationStore,
                now: now
            )
        }
        return try await withTaskCancellationHandler {
            try await persistenceTask.value
        } onCancel: {
            persistenceTask.cancel()
        }
    }

    private func persistOfflineAuthorization(
        _ authorization: OfflineDeviceAuthorization,
        expectedUsername: String,
        expectedEmail: String
    ) async throws -> LicenseState {
        let service = self.service
        let activationStore = self.activationStore
        let now = nowProvider()
        let persistenceTask = Task.detached(priority: .userInitiated) {
            try service.state(
                applyingOfflineDeviceAuthorization: authorization,
                expectedUsername: expectedUsername,
                expectedEmail: expectedEmail,
                activationStore: activationStore,
                now: now
            )
        }
        return try await withTaskCancellationHandler {
            try await persistenceTask.value
        } onCancel: {
            persistenceTask.cancel()
        }
    }

    private func refreshOfflineAuthorization(_ authorization: OfflineDeviceAuthorization) {
        actionStatusLabel.isHidden = false
        actionStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        actionStatusLabel.stringValue = "正在同步离线授权状态..."
        refreshLicenseButton.isEnabled = false
        onlineValidationTask?.cancel()
        onlineValidationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshLicenseButton.isEnabled = true
                onlineValidationTask = nil
            }
            do {
                let refreshed = try await offlineStatusRefresher.refresh(
                    authorization: authorization,
                    appVersion: StacioAppMetadata.displayVersion,
                    buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
                )
                try Task.checkCancellation()
                let state = try await persistOfflineAuthorization(
                    refreshed,
                    expectedUsername: authorization.username,
                    expectedEmail: authorization.email
                )
                renderStatus(state)
                actionStatusLabel.isHidden = false
                actionStatusLabel.textColor = StacioDesignSystem.theme.successColor
                actionStatusLabel.stringValue = "离线授权状态已同步。"
                resizeWindowToContent(hasAuthorization: true)
            } catch is CancellationError {
                return
            } catch {
                let classified = ProductOpsError.classify(error)
                if classified.offlineLicenseStatusErrorCode != nil {
                    do {
                        let state = try await persistOfflineStatusFailure(classified)
                        renderStatus(state)
                        actionStatusLabel.isHidden = false
                        actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
                        actionStatusLabel.stringValue = "离线授权已停止：\(state.status.displayName)。请重新导入许可。"
                        resizeWindowToContent(hasAuthorization: false)
                        return
                    } catch is CancellationError {
                        return
                    } catch {
                        actionStatusLabel.isHidden = false
                        actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
                        actionStatusLabel.stringValue = "离线授权同步失败：\(error.localizedDescription)"
                        return
                    }
                }
                actionStatusLabel.isHidden = false
                actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
                actionStatusLabel.stringValue = "离线授权同步失败：\(error.localizedDescription)"
            }
        }
    }

    private func persistOfflineStatusFailure(_ error: ProductOpsError) async throws -> LicenseState {
        let service = self.service
        let now = nowProvider()
        let persistenceTask = Task.detached(priority: .userInitiated) {
            try service.state(applyingOfflineStatusError: error, now: now)
        }
        return try await withTaskCancellationHandler {
            try await persistenceTask.value
        } onCancel: {
            persistenceTask.cancel()
        }
    }

    @objc private func reimportLicensePressed(_ sender: Any?) {
        cancelOnlineValidation()
        isReimporting = true
        refreshStatus()
        licenseKeyField.stringValue = ""
        actionStatusLabel.isHidden = false
        actionStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        actionStatusLabel.stringValue = "请输入在线 License，或选择离线授权文件导入。"
    }

    private func isCurrentOnlineValidationRun(_ runID: UUID) -> Bool {
        onlineValidationRunID == runID && Task.isCancelled == false
    }

    private func finishOnlineValidationRun(_ runID: UUID) {
        guard onlineValidationRunID == runID else { return }
        onlineValidationRunID = nil
        onlineValidationTask = nil
        validateButton.isEnabled = true
        refreshLicenseButton.isEnabled = true
    }

    private func cancelOnlineValidation() {
        onlineValidationRunID = nil
        onlineValidationTask?.cancel()
        onlineValidationTask = nil
        validateButton.isEnabled = true
        refreshLicenseButton.isEnabled = true
    }

    private func renderOnlineValidationFailure(_ message: String) {
        actionStatusLabel.isHidden = false
        actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
        actionStatusLabel.stringValue = L10n.ProductOps.licenseOnlineFailedPrefix + message
        resizeWindowToContent(hasAuthorization: managementActionStack.isHidden == false)
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
        actionStatusLabel.isHidden = false
        actionStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        actionStatusLabel.stringValue = "正在导入离线授权..."
        onlineValidationTask?.cancel()
        onlineValidationTask = Task { [weak self] in
            let readTask = Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }
            do {
                let data = try await withTaskCancellationHandler {
                    try await readTask.value
                } onCancel: {
                    readTask.cancel()
                }
                guard let self else { return }
                await importOfflineLicenseData(data)
                onlineValidationTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                onlineValidationTask = nil
                renderLicenseFileImportFailure(error.localizedDescription)
            }
        }
    }

    private func importOfflineLicenseData(_ data: Data) async {
        do {
            let state = try await applyOfflineLicenseData(data)
            if state.status == .revoked {
                actionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
                actionStatusLabel.stringValue = L10n.ProductOps.licenseRevocationApplied
            } else {
                actionStatusLabel.textColor = StacioDesignSystem.theme.successColor
                actionStatusLabel.stringValue = L10n.ProductOps.licenseTokenApplied
            }
            renderStatus(state)
        } catch {
            renderLicenseFileImportFailure(error.localizedDescription)
        }
    }

    private func applyOfflineLicenseData(_ data: Data) async throws -> LicenseState {
        let configuration = self.configuration
        let offlineConfigurationStore = self.offlineConfigurationStore
        let fingerprintProvider = self.fingerprintProvider
        let now = nowProvider()
        let expectedUsername = usernameField.stringValue
        let expectedEmail = emailField.stringValue
        let verificationTask = Task.detached(priority: .userInitiated) {
            let protocolConfiguration = OfflineLicenseConfigurationService(
                apiBaseURL: configuration.apiBaseURL,
                store: offlineConfigurationStore
            ).cachedOrBundled(configuration.offlineLicenseProtocolConfiguration)
            return try OfflineLicenseFileCodec.importAuthorization(
                data,
                configuration: protocolConfiguration,
                fingerprintProvider: fingerprintProvider,
                now: now
            )
        }
        let authorization = try await withTaskCancellationHandler {
            try await verificationTask.value
        } onCancel: {
            verificationTask.cancel()
        }
        return try await persistOfflineAuthorization(
            authorization,
            expectedUsername: expectedUsername,
            expectedEmail: expectedEmail
        )
    }

    private func refreshStatus() {
        let state = persistedStateProvider?() ?? service.loadState(now: nowProvider())
        renderStatus(state)
    }

    private func renderStatus(_ state: LicenseState) {
        let hasAuthorization = [.active, .trial, .offlineActive, .offlineGrace].contains(state.status)
        let showsManagement = shouldShowManagement(for: state)
        let planDisplay = Self.displayPlan(state.plan)
        statusHeadlineLabel.stringValue = state.status.displayName
        statusHeadlineLabel.textColor = hasAuthorization
            ? StacioDesignSystem.theme.successColor
            : StacioDesignSystem.theme.dangerColor
        planBadgeLabel.stringValue = planDisplay
        userValueLabel.stringValue = state.username.isEmpty ? "-" : state.username
        emailValueLabel.stringValue = state.email.isEmpty ? "-" : state.email
        expiresValueLabel.stringValue = state.expiresAt.map(Self.dateFormatter.string(from:)) ?? "-"
        var accessibilityLines = [
            "\(L10n.ProductOps.licenseStatus)：\(state.status.displayName)",
            "\(L10n.ProductOps.licenseUser)：\(state.username.isEmpty ? "-" : state.username)",
            "\(L10n.ProductOps.licenseEmail)：\(state.email.isEmpty ? "-" : state.email)",
            "\(L10n.ProductOps.licensePlan)：\(planDisplay)"
        ]
        if let expiresAt = state.expiresAt {
            accessibilityLines.append("\(L10n.ProductOps.licenseExpires)：\(Self.dateFormatter.string(from: expiresAt))")
        }
        if let graceUntil = state.graceUntil {
            accessibilityLines.append("\(L10n.ProductOps.licenseGraceUntil)：\(Self.dateFormatter.string(from: graceUntil))")
        }
        statusLabel.stringValue = accessibilityLines.joined(separator: "\n")
        if hasAuthorization {
            statusNoteLabel.stringValue = "授权信息已在本机验证；后台私钥不会进入客户端。"
        } else if showsManagement {
            statusNoteLabel.stringValue = "许可信息已保存在本机，可更新状态或重新导入。"
        } else {
            statusNoteLabel.stringValue = "尚未激活 License；可选择在线激活或导入离线授权文件。"
        }
        activationFormStack.isHidden = showsManagement
        licenseActionStack.isHidden = showsManagement
        actionStatusLabel.isHidden = showsManagement
        managementActionStack.isHidden = !showsManagement
        if usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            usernameField.stringValue = state.username
        }
        if emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emailField.stringValue = state.email
        }
        resizeWindowToContent(hasAuthorization: showsManagement)
    }

    private func shouldShowManagement(for state: LicenseState) -> Bool {
        guard isReimporting == false else { return false }
        if [.active, .trial, .offlineActive, .offlineGrace].contains(state.status) {
            return true
        }
        if state.offlineDeviceAuthorization != nil {
            return true
        }
        if persistedStateProvider != nil {
            return hasPersistedActivationRecord
        }
        return (try? activationStore.loadActivationRecord()) != nil
    }

    private func observePersistedAuthorizationIfNeeded() {
        guard persistedStateProvider != nil else { return }
        licenseAuthorizationObserver = NotificationCenter.default.addObserver(
            forName: .stacioLicenseAuthorizationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatus()
            }
        }
    }

    private func loadActivationRecordPresenceIfNeeded() {
        guard persistedStateProvider != nil else { return }
        let activationStore = self.activationStore
        activationRecordPresenceTask = Task { [weak self] in
            let readTask = Task.detached(priority: .utility) {
                try activationStore.loadActivationRecord() != nil
            }
            let hasActivation = (try? await readTask.value) ?? false
            guard Task.isCancelled == false, let self else { return }
            hasPersistedActivationRecord = hasActivation
            refreshStatus()
        }
    }

    private static func displayPlan(_ plan: String) -> String {
        switch plan.lowercased() {
        case "enterprise", "team", "internal": return "企业版"
        case "professional", "pro": return "专业版"
        case "trial": return "试用版"
        default: return plan.isEmpty ? "免费版" : plan
        }
    }

    private func resizeWindowToContent(hasAuthorization: Bool = false) {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let measuredHeight = contentStack?.fittingSize.height ?? (hasAuthorization ? 280 : 500)
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let targetHeight = ceil(measuredHeight + 52 + titlebarHeight)
        var frame = window.frame
        frame.size = NSSize(width: 600, height: targetHeight)
        frame.origin.y = window.frame.maxY - targetHeight
        window.setFrame(frame, display: true, animate: false)
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
        contentStack = stack
        root.addSubview(stack)

        stack.addArrangedSubview(licenseHeader())
        statusLabel.setAccessibilityIdentifier("Stacio.License.status")
        statusLabel.maximumNumberOfLines = 0
        statusLabel.isHidden = true
        statusNoteLabel.maximumNumberOfLines = 1
        statusNoteLabel.font = .systemFont(ofSize: 11)
        statusNoteLabel.lineBreakMode = .byTruncatingTail
        statusNoteLabel.textColor = StacioDesignSystem.theme.secondaryTextColor

        statusHeadlineLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusHeadlineLabel.setAccessibilityIdentifier("Stacio.License.statusHeadline")
        planBadgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        planBadgeLabel.alignment = .center
        planBadgeLabel.wantsLayer = true
        planBadgeLabel.layer?.cornerRadius = 6
        planBadgeLabel.layer?.cornerCurve = .continuous
        planBadgeLabel.layer?.backgroundColor = StacioDesignSystem.theme.accentColor.withAlphaComponent(0.14).cgColor
        planBadgeLabel.textColor = StacioDesignSystem.theme.accentColor
        planBadgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        planBadgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let statusRow = NSStackView(views: [statusHeadlineLabel, planBadgeLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10
        let detailGrid = NSGridView(views: [
            [formLabel("用户名"), userValueLabel, formLabel("邮箱"), emailValueLabel],
            [formLabel("到期时间"), expiresValueLabel, NSView(), NSView()]
        ])
        detailGrid.column(at: 0).width = 70
        detailGrid.column(at: 2).width = 55
        detailGrid.column(at: 1).xPlacement = .leading
        detailGrid.column(at: 3).xPlacement = .leading
        detailGrid.row(at: 0).yPlacement = .center
        detailGrid.row(at: 1).yPlacement = .center
        for label in [userValueLabel, emailValueLabel, expiresValueLabel] {
            label.font = .systemFont(ofSize: 13)
            label.textColor = StacioDesignSystem.theme.primaryTextColor
            label.lineBreakMode = .byTruncatingTail
        }
        let statusStack = NSStackView(views: [statusRow, detailGrid, statusNoteLabel, statusLabel])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 10
        let statusCard = roundedLicensePanel(content: statusStack)
        statusCard.setAccessibilityIdentifier("Stacio.License.statusCard")
        stack.addArrangedSubview(statusCard)
        statusCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        activationFormStack.orientation = .vertical
        activationFormStack.alignment = .leading
        activationFormStack.spacing = 14
        activationFormStack.translatesAutoresizingMaskIntoConstraints = false
        activationFormStack.setAccessibilityIdentifier("Stacio.License.activationForm")
        stack.addArrangedSubview(activationFormStack)
        activationFormStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        licenseKeyField.placeholderString = "STACIO-..."
        licenseKeyField.setAccessibilityIdentifier("Stacio.License.licenseKey")
        StacioDesignSystem.styleTextField(licenseKeyField)
        activationFormStack.addArrangedSubview(formRow(label: L10n.ProductOps.licenseKey, control: licenseKeyField))

        usernameField.placeholderString = "用户名"
        usernameField.setAccessibilityIdentifier("Stacio.License.username")
        StacioDesignSystem.styleTextField(usernameField)
        activationFormStack.addArrangedSubview(formRow(label: L10n.ProductOps.licenseUser, control: usernameField))

        emailField.placeholderString = "name@example.com"
        emailField.setAccessibilityIdentifier("Stacio.License.email")
        StacioDesignSystem.styleTextField(emailField)
        activationFormStack.addArrangedSubview(formRow(label: L10n.ProductOps.licenseEmail, control: emailField))

        let exchangeAddress = configuration.offlineLicenseExchangeURL?.absoluteString
            ?? L10n.ProductOps.offlineExchangeAddressPlaceholder
        let exchangeAddressLabel = NSTextField(wrappingLabelWithString: "\(L10n.ProductOps.offlineExchangeAddress)：\(exchangeAddress)")
        exchangeAddressLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        exchangeAddressLabel.maximumNumberOfLines = 0
        activationFormStack.addArrangedSubview(exchangeAddressLabel)

        actionStatusLabel.setAccessibilityIdentifier("Stacio.License.actionStatus")
        actionStatusLabel.maximumNumberOfLines = 0
        actionStatusLabel.stringValue = L10n.ProductOps.licenseOnlineReserved
        actionStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        stack.addArrangedSubview(actionStatusLabel)

        licenseActionStack.orientation = .horizontal
        licenseActionStack.spacing = 8
        licenseActionStack.alignment = .centerY
        licenseActionStack.setAccessibilityIdentifier("Stacio.License.actions")
        validateButton.target = self
        validateButton.action = #selector(validateOnlinePressed(_:))
        validateButton.setAccessibilityIdentifier("Stacio.License.validateOnline")
        StacioDesignSystem.styleSheetButton(validateButton)
        let exportButton = NSButton(
            title: L10n.ProductOps.exportDeviceFingerprint,
            target: self,
            action: #selector(exportDeviceFingerprintPressed(_:))
        )
        exportButton.setAccessibilityIdentifier("Stacio.License.exportDeviceFingerprint")
        StacioDesignSystem.styleSheetButton(exportButton)
        let importButton = NSButton(
            title: L10n.ProductOps.importOfflineLicenseFile,
            target: self,
            action: #selector(importOfflineLicenseFilePressed(_:))
        )
        importButton.setAccessibilityIdentifier("Stacio.License.importOfflineLicenseFile")
        StacioDesignSystem.styleSheetButton(importButton)
        licenseActionStack.addArrangedSubview(NSView())
        licenseActionStack.addArrangedSubview(validateButton)
        licenseActionStack.addArrangedSubview(exportButton)
        licenseActionStack.addArrangedSubview(importButton)
        stack.addArrangedSubview(licenseActionStack)
        licenseActionStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        managementActionStack.orientation = .horizontal
        managementActionStack.spacing = 10
        managementActionStack.alignment = .centerY
        refreshLicenseButton.target = self
        refreshLicenseButton.action = #selector(refreshLicensePressed(_:))
        reimportLicenseButton.target = self
        reimportLicenseButton.action = #selector(reimportLicensePressed(_:))
        refreshLicenseButton.setAccessibilityIdentifier("Stacio.License.refresh")
        reimportLicenseButton.setAccessibilityIdentifier("Stacio.License.reimport")
        configureManagementButton(
            refreshLicenseButton,
            symbolName: "arrow.triangle.2.circlepath",
            minimumWidth: 140,
            isDefault: true
        )
        configureManagementButton(
            reimportLicenseButton,
            symbolName: "arrow.down.doc",
            minimumWidth: 168
        )
        managementActionStack.addArrangedSubview(refreshLicenseButton)
        managementActionStack.addArrangedSubview(reimportLicenseButton)
        stack.addArrangedSubview(managementActionStack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24)
        ])
        return root
    }

    private func configureManagementButton(
        _ button: NSButton,
        symbolName: String,
        minimumWidth: CGFloat,
        isDefault: Bool = false
    ) {
        StacioDesignSystem.styleSheetButton(button, isDefault: isDefault)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: button.title)
        button.imagePosition = .imageLeading
        button.controlSize = .large
        button.cell?.controlSize = .large
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth),
            button.heightAnchor.constraint(equalToConstant: 36)
        ])
    }
}

extension LicenseWindowController: NSWindowDelegate {
    public func windowDidBecomeKey(_ notification: Notification) {
        let state = persistedStateProvider?() ?? service.loadState(now: nowProvider())
        resizeWindowToContent(hasAuthorization: shouldShowManagement(for: state))
    }

    public func windowWillClose(_ notification: Notification) {
        cancelOnlineValidation()
        activationRecordPresenceTask?.cancel()
        activationRecordPresenceTask = nil
        if let licenseAuthorizationObserver {
            NotificationCenter.default.removeObserver(licenseAuthorizationObserver)
            self.licenseAuthorizationObserver = nil
        }
    }
}

private struct FreePlanFeatureRow {
    let group: String?
    let feature: String
    let freeIncluded: Bool
    let professionalIncluded: Bool

    static func group(_ title: String) -> FreePlanFeatureRow {
        FreePlanFeatureRow(group: title, feature: title, freeIncluded: false, professionalIncluded: false)
    }

    static func feature(
        _ title: String,
        freeIncluded: Bool,
        professionalIncluded: Bool
    ) -> FreePlanFeatureRow {
        FreePlanFeatureRow(
            group: nil,
            feature: title,
            freeIncluded: freeIncluded,
            professionalIncluded: professionalIncluded
        )
    }
}

private final class FreePlanNoticeTableRowView: NSTableRowView {
    private let isGroup: Bool

    init(isGroup: Bool) {
        self.isGroup = isGroup
        super.init(frame: .zero)
        selectionHighlightStyle = .none
        isEmphasized = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isGroup else { return }

        // macOS 27 uses a low-contrast section wash instead of a boxed group.
        NSColor.controlBackgroundColor.withAlphaComponent(0.28).setFill()
        bounds.fill()
    }
}

@MainActor
public final class FreePlanNoticeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    public static let pricingURL = URL(string: "https://www.stacio.cn/pricing.html")!

    // Keep this snapshot aligned with the feature table on stacio.cn/pricing.html.
    private static let featureRows: [FreePlanFeatureRow] = [
        .group("基础远程工作流"),
        .feature("SSH、Telnet、VNC、FTP、SCP、串口和本地终端", freeIncluded: true, professionalIncluded: true),
        .feature("会话保存、分组、标签页和基础分屏", freeIncluded: true, professionalIncluded: true),
        .feature("Keychain 凭据保存与敏感信息脱敏", freeIncluded: true, professionalIncluded: true),
        .feature("远程目录浏览、单文件上传下载、文本编辑和预览", freeIncluded: true, professionalIncluded: true),
        .feature("基础终端查找、命令历史和输出保存", freeIncluded: true, professionalIncluded: true),
        .feature("基础 AI 对话、终端上下文解释和命令建议", freeIncluded: true, professionalIncluded: true),
        .group("协作、自动化与连接"),
        .feature("多终端批量执行与输入广播", freeIncluded: false, professionalIncluded: true),
        .feature("AI Agent 多步骤计划、Goal 模式和连续执行", freeIncluded: false, professionalIncluded: true),
        .feature("SSH 隧道管理与端口转发", freeIncluded: false, professionalIncluded: true),
        .feature("堡垒机/跳板机导入", freeIncluded: false, professionalIncluded: true),
        .feature("ProxyJump 多级跳转", freeIncluded: false, professionalIncluded: true),
        .group("监控、文件与工作区"),
        .feature("设备监控历史曲线、阈值告警和通知", freeIncluded: false, professionalIncluded: true),
        .feature("远程文件比较、编辑同步、批量传输和断点恢复", freeIncluded: false, professionalIncluded: true),
        .feature("会话批量导入、导出、迁移和去重", freeIncluded: false, professionalIncluded: true),
        .feature("AI 执行审计、长期归档和报告导出", freeIncluded: false, professionalIncluded: true),
        .feature("高级网格工作区、独立窗口和工作区模板", freeIncluded: false, professionalIncluded: true)
    ]

    private let urlOpener: ProductOpsURLOpening
    private let tableView = NSTableView()
    private let rows = FreePlanNoticeWindowController.featureRows
    private let getLicenseButton = NSButton(title: L10n.ProductOps.freePlanNoticeGetLicense, target: nil, action: nil)

    public init(urlOpener: ProductOpsURLOpening? = nil) {
        self.urlOpener = urlOpener ?? WorkspaceProductOpsURLOpener()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // The visible title lives in the content header. An empty native title
        // prevents AppKit from drawing a second copy in the titlebar.
        window.title = ""
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 620)
        window.appearance = nil
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        let titlebarToolbar = NSToolbar(identifier: NSToolbar.Identifier("Stacio.FreePlan.titlebar"))
        titlebarToolbar.displayMode = .iconOnly
        titlebarToolbar.showsBaselineSeparator = false
        window.toolbar = titlebarToolbar
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.center()
        super.init(window: window)
        // AppKit may restore the titlebar's default visibility during setup.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.contentView = makeContentView()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
        window?.toolbarStyle = .unifiedCompact
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else {
            return nil
        }
        let item = rows[row]
        let columnID = tableColumn.identifier.rawValue
        if item.group != nil {
            return makeTableCell(
                text: columnID == "feature" ? item.feature : "",
                alignment: columnID == "feature" ? .left : .center,
                font: .systemFont(ofSize: 13, weight: .semibold),
                textColor: StacioDesignSystem.theme.secondaryTextColor,
                accessibilityIdentifier: columnID == "feature" ? "Stacio.FreePlan.featureGroup.\(row)" : nil
            )
        }

        return makeTableCell(
            text: statusText(for: item, columnID: columnID),
            alignment: columnID == "feature" ? .left : .center,
            font: .systemFont(ofSize: 13, weight: columnID == "feature" ? .medium : .regular),
            textColor: columnID == "feature"
            ? StacioDesignSystem.theme.primaryTextColor
            : statusColor(for: item, columnID: columnID),
            accessibilityIdentifier: "Stacio.FreePlan.feature.\(row).\(columnID)"
        )
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        // Render section rows as normal view-based rows for current AppKit.
        false
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows.indices.contains(row) && rows[row].group != nil ? 26 : 30
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FreePlanNoticeTableRowView(isGroup: rows.indices.contains(row) && rows[row].group != nil)
    }

    @objc
    private func getLicensePressed(_ sender: Any?) {
        urlOpener.open(Self.pricingURL)
    }

    private func statusText(for row: FreePlanFeatureRow, columnID: String) -> String {
        switch columnID {
        case "free":
            return row.freeIncluded ? L10n.ProductOps.freePlanNoticeIncluded : L10n.ProductOps.freePlanNoticeUnavailable
        case "professional":
            return row.professionalIncluded ? L10n.ProductOps.freePlanNoticeIncluded : L10n.ProductOps.freePlanNoticeUnavailable
        default:
            return row.feature
        }
    }

    private func statusColor(for row: FreePlanFeatureRow, columnID: String) -> NSColor {
        let included = columnID == "free" ? row.freeIncluded : row.professionalIncluded
        return included ? StacioDesignSystem.theme.successColor : StacioDesignSystem.theme.secondaryTextColor
    }

    private func makeTableCell(
        text: String,
        alignment: NSTextAlignment,
        font: NSFont,
        textColor: NSColor,
        accessibilityIdentifier: String?
    ) -> NSTableCellView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.alignment = alignment
        label.font = font
        label.textColor = textColor
        label.maximumNumberOfLines = 1
        label.lineBreakMode = alignment == .left ? .byTruncatingTail : .byClipping
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        if let accessibilityIdentifier {
            label.setAccessibilityIdentifier(accessibilityIdentifier)
        }

        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor)
        ])
        return cell
    }

    private func makeContentView() -> NSView {
        let root = StacioAppearanceRefreshView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        let materialView = NSVisualEffectView()
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.isEmphasized = false
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 16
        materialView.layer?.cornerCurve = .continuous
        materialView.layer?.masksToBounds = true
        materialView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(materialView)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        materialView.addSubview(stack)

        let planHeader = freePlanHeader()
        stack.addArrangedSubview(planHeader)
        planHeader.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let comparisonHelp = NSTextField(labelWithString: L10n.ProductOps.freePlanNoticeComparisonHelp)
        comparisonHelp.font = .systemFont(ofSize: 13)
        comparisonHelp.textColor = StacioDesignSystem.theme.secondaryTextColor
        comparisonHelp.maximumNumberOfLines = 0
        comparisonHelp.lineBreakMode = .byWordWrapping
        comparisonHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(comparisonHelp)
        comparisonHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let comparisonTitle = NSTextField(labelWithString: L10n.ProductOps.freePlanNoticeComparisonTitle)
        comparisonTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        comparisonTitle.textColor = StacioDesignSystem.theme.primaryTextColor
        comparisonTitle.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(comparisonTitle)

        let tableSurface = NSVisualEffectView()
        tableSurface.material = .underWindowBackground
        tableSurface.blendingMode = .withinWindow
        tableSurface.state = .active
        tableSurface.wantsLayer = true
        tableSurface.layer?.cornerRadius = 12
        tableSurface.layer?.cornerCurve = .continuous
        tableSurface.layer?.masksToBounds = true
        tableSurface.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        configureTableView()
        scrollView.documentView = tableView
        tableSurface.addSubview(scrollView)
        stack.addArrangedSubview(tableSurface)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        getLicenseButton.target = self
        getLicenseButton.action = #selector(getLicensePressed(_:))
        getLicenseButton.setAccessibilityIdentifier("Stacio.FreePlan.getLicense")
        StacioDesignSystem.styleSheetButton(getLicenseButton, isDefault: true)
        getLicenseButton.setContentHuggingPriority(.required, for: .horizontal)
        let closeButton = NSButton(title: L10n.ProductOps.freePlanNoticeClose, target: self, action: #selector(closeWindowPressed(_:)))
        closeButton.setAccessibilityIdentifier("Stacio.FreePlan.close")
        StacioDesignSystem.styleSheetButton(closeButton)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(buttonSpacer)
        buttons.addArrangedSubview(closeButton)
        buttons.addArrangedSubview(getLicenseButton)
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: root.topAnchor),
            materialView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -24),
            // Keep the content below the traffic-light controls in full-size mode.
            stack.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 56),
            stack.bottomAnchor.constraint(equalTo: materialView.bottomAnchor, constant: -18),
            scrollView.leadingAnchor.constraint(equalTo: tableSurface.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tableSurface.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: tableSurface.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tableSurface.bottomAnchor),
            tableSurface.heightAnchor.constraint(equalToConstant: 438)
        ])
        return root
    }

    private func configureTableView() {
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.gridColor = StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.22)
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("Stacio.FreePlan.comparison")

        let featureColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("feature"))
        featureColumn.title = L10n.ProductOps.freePlanNoticeFeature
        featureColumn.width = 430
        featureColumn.headerCell = freePlanHeaderCell(title: featureColumn.title, alignment: .left)
        let freeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("free"))
        freeColumn.title = L10n.ProductOps.freePlanNoticeFree
        freeColumn.width = 96
        freeColumn.headerCell = freePlanHeaderCell(title: freeColumn.title, alignment: .center)
        let professionalColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("professional"))
        professionalColumn.title = L10n.ProductOps.freePlanNoticeProfessional
        professionalColumn.width = 112
        professionalColumn.headerCell = freePlanHeaderCell(title: professionalColumn.title, alignment: .center)
        tableView.addTableColumn(featureColumn)
        tableView.addTableColumn(freeColumn)
        tableView.addTableColumn(professionalColumn)
    }

    private func freePlanHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: "lock.open.fill",
            accessibilityDescription: L10n.ProductOps.freePlanNoticeTitle
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        iconView.contentTintColor = StacioDesignSystem.theme.accentColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: L10n.ProductOps.freePlanNoticeTitle)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.alignment = .left
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("Stacio.FreePlan.title")

        let subtitleLabel = NSTextField(labelWithString: L10n.ProductOps.freePlanNoticeSubtitle)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        subtitleLabel.alignment = .left
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        header.addSubview(iconView)
        header.addSubview(titleLabel)
        header.addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: header.topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 59)
        ])
        return header
    }

    private func freePlanHeaderCell(title: String, alignment: NSTextAlignment) -> NSTableHeaderCell {
        let cell = NSTableHeaderCell(textCell: title)
        cell.font = .systemFont(ofSize: 13, weight: .semibold)
        cell.textColor = StacioDesignSystem.theme.primaryTextColor
        cell.alignment = alignment
        return cell
    }

    @objc
    private func closeWindowPressed(_ sender: Any?) {
        close()
    }
}

private func licenseHeader() -> NSView {
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: "License")
    icon.contentTintColor = StacioDesignSystem.theme.accentColor
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 30).isActive = true

    let title = NSTextField(labelWithString: "License")
    title.font = .systemFont(ofSize: 24, weight: .bold)
    title.textColor = StacioDesignSystem.theme.primaryTextColor
    let subtitle = NSTextField(labelWithString: "管理在线激活与离线授权")
    subtitle.font = .systemFont(ofSize: 13)
    subtitle.textColor = StacioDesignSystem.theme.secondaryTextColor
    let text = NSStackView(views: [title, subtitle])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3

    let header = NSStackView(views: [icon, text])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 12
    return header
}

private func roundedLicensePanel(content: NSView) -> NSView {
    let panel = NSView()
    panel.wantsLayer = true
    panel.layer?.cornerRadius = 10
    panel.layer?.cornerCurve = .continuous
    panel.layer?.backgroundColor = StacioDesignSystem.theme.panelBackgroundColor.cgColor
    panel.layer?.borderColor = StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.55).cgColor
    panel.layer?.borderWidth = 1
    content.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
        content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
        content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
        content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14)
    ])
    return panel
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
