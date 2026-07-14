import AppKit
import StacioCoreBindings
import UniformTypeIdentifiers

public struct SessionSidebarMoveDestination: Equatable {
    public let folderID: String?

    public init(folderID: String?) {
        self.folderID = folderID
    }
}

@MainActor
public protocol SessionSidebarPingProgressPresenting: AnyObject {
    func setCancelHandler(_ handler: @escaping @MainActor () -> Void)
    func setCloseHandler(_ handler: @escaping @MainActor () -> Void)
    func appendOutput(_ text: String)
    func finish(_ result: SessionSidebarPingResult)
    func fail(_ error: Error)
}

@MainActor
public protocol SessionSidebarOperationsPresenting {
    func chooseMoveDestination(
        for session: SessionRecord,
        folders: [SessionFolder],
        parentWindow: NSWindow?
    ) -> SessionSidebarMoveDestination?

    func promptCreateFolder(parentFolder: SessionFolder?, parentWindow: NSWindow?) -> String?
    func promptRenameFolder(_ folder: SessionFolder, parentWindow: NSWindow?) -> String?
    func confirmDeleteFolder(_ folder: SessionFolder, parentWindow: NSWindow?) -> Bool
    func chooseFolderExportDestination(folder: SessionFolder, parentWindow: NSWindow?) -> URL?
    func chooseExportDestination(suggestedName: String, parentWindow: NSWindow?) -> URL?
    func presentExportComplete(destinationURL: URL, parentWindow: NSWindow?)
    func promptConnectAsUsername(for session: SessionRecord, parentWindow: NSWindow?) -> String?
    func presentPingResult(_ result: SessionSidebarPingResult, parentWindow: NSWindow?)
    func presentPingProgress(host: String, parentWindow: NSWindow?) -> SessionSidebarPingProgressPresenting
    func promptRenameSession(_ session: SessionRecord, parentWindow: NSWindow?) -> String?
    func chooseSingleSessionExportDestination(session: SessionRecord, parentWindow: NSWindow?) -> URL?
    func chooseDesktopShortcutDestination(session: SessionRecord, parentWindow: NSWindow?) -> URL?
    func presentShortcutCreated(destinationURL: URL, parentWindow: NSWindow?)
    func presentDefaultPresetSaved(session: SessionRecord, parentWindow: NSWindow?)
    func presentSettingsCopied(parentWindow: NSWindow?)
}

@MainActor
public final class AppKitSessionSidebarOperationsPresenter: SessionSidebarOperationsPresenting {
    public init() {}

    public func chooseMoveDestination(
        for session: SessionRecord,
        folders: [SessionFolder],
        parentWindow: NSWindow?
    ) -> SessionSidebarMoveDestination? {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28), pullsDown: false)
        popup.addItem(withTitle: L10n.Sidebar.rootFolder)
        popup.lastItem?.representedObject = Optional<String>.none as Any
        for folder in folders {
            popup.addItem(withTitle: folder.name)
            popup.lastItem?.representedObject = folder.id
        }
        if let currentFolderID = session.folderId,
           let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == currentFolderID }) {
            popup.selectItem(at: index)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.Sidebar.moveSessionTitle
        alert.informativeText = String(format: L10n.Sidebar.moveSessionMessage, session.name)
        alert.accessoryView = popup
        alert.addButton(withTitle: L10n.Sidebar.moveSession)
        alert.addButton(withTitle: L10n.Common.cancel)

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        return SessionSidebarMoveDestination(folderID: popup.selectedItem?.representedObject as? String)
    }

    public func promptCreateFolder(parentFolder: SessionFolder?, parentWindow: NSWindow?) -> String? {
        promptTextField(
            title: L10n.Sidebar.createGroupTitle,
            message: parentFolder
                .map { String(format: L10n.Sidebar.createChildGroupMessage, $0.name) }
                ?? L10n.Sidebar.createRootGroupMessage,
            initialValue: "",
            confirmTitle: L10n.Sidebar.createGroupConfirm
        )
    }

    public func promptRenameFolder(_ folder: SessionFolder, parentWindow: NSWindow?) -> String? {
        promptTextField(
            title: L10n.Sidebar.renameGroup,
            message: String(format: L10n.Sidebar.renameGroupMessage, folder.name),
            initialValue: folder.name,
            confirmTitle: L10n.Sidebar.renameGroupConfirm
        )
    }

    public func confirmDeleteFolder(_ folder: SessionFolder, parentWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.DeleteFolder.title
        alert.informativeText = L10n.DeleteFolder.message(folder.name)
        alert.addButton(withTitle: L10n.Common.delete)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func chooseFolderExportDestination(folder: SessionFolder, parentWindow: NSWindow?) -> URL? {
        chooseJSONDestination(
            suggestedName: String(
                format: L10n.Sidebar.exportGroupSessionsSuggestedName,
                safeFileName(folder.name, fallback: "Stacio Group")
            ),
            title: L10n.Sidebar.exportGroupSessions
        )
    }

    public func chooseExportDestination(suggestedName: String, parentWindow: NSWindow?) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.title = L10n.Sidebar.exportSessions

        // This presenter exposes a synchronous API so the sidebar can keep its
        // operation flow simple. Using runModal avoids blocking the main thread
        // on a semaphore while a sheet callback is waiting for the same thread.
        _ = parentWindow
        return panel.runModal() == .OK ? panel.url : nil
    }

    public func presentExportComplete(destinationURL: URL, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.Sidebar.exportCompleteTitle
        alert.informativeText = destinationURL.path
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }

    public func promptConnectAsUsername(for session: SessionRecord, parentWindow: NSWindow?) -> String? {
        promptTextField(
            title: L10n.Sidebar.connectAsTitle,
            message: String(format: L10n.Sidebar.connectAsMessage, session.name),
            initialValue: session.username ?? NSUserName(),
            confirmTitle: L10n.Sidebar.connectAs
        )
    }

    public func presentPingResult(_ result: SessionSidebarPingResult, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = result.reachable ? .informational : .warning
        alert.messageText = result.reachable
            ? L10n.Sidebar.pingSuccessTitle
            : L10n.Sidebar.pingFailedTitle
        alert.informativeText = result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.host
            : result.output
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }

    public func presentPingProgress(host: String, parentWindow: NSWindow?) -> SessionSidebarPingProgressPresenting {
        AppKitSessionSidebarPingProgressPresenter(host: host, parentWindow: parentWindow)
    }

    public func promptRenameSession(_ session: SessionRecord, parentWindow: NSWindow?) -> String? {
        promptTextField(
            title: L10n.Sidebar.renameSession,
            message: String(format: L10n.Sidebar.renameSessionMessage, session.name),
            initialValue: session.name,
            confirmTitle: L10n.Sidebar.renameSessionConfirm
        )
    }

    public func chooseSingleSessionExportDestination(session: SessionRecord, parentWindow: NSWindow?) -> URL? {
        chooseJSONDestination(
            suggestedName: "\(safeFileName(session.name, fallback: "Stacio Session")).json",
            title: L10n.Sidebar.saveSessionToFile
        )
    }

    public func chooseDesktopShortcutDestination(session: SessionRecord, parentWindow: NSWindow?) -> URL? {
        let suggestedName = "\(safeFileName(session.name, fallback: "Stacio Session")).webloc"
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = desktopURL
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.internetLocation]
        panel.title = L10n.Sidebar.createDesktopShortcut
        _ = parentWindow
        return panel.runModal() == .OK ? panel.url : nil
    }

    public func presentShortcutCreated(destinationURL: URL, parentWindow: NSWindow?) {
        presentSimpleInfo(
            title: L10n.Sidebar.shortcutCreatedTitle,
            message: destinationURL.path,
            parentWindow: parentWindow
        )
    }

    public func presentDefaultPresetSaved(session: SessionRecord, parentWindow: NSWindow?) {
        presentSimpleInfo(
            title: L10n.Sidebar.defaultPresetSavedTitle,
            message: String(format: L10n.Sidebar.defaultPresetSavedMessage, session.name),
            parentWindow: parentWindow
        )
    }

    public func presentSettingsCopied(parentWindow: NSWindow?) {
        presentSimpleInfo(
            title: L10n.Sidebar.settingsCopiedTitle,
            message: L10n.Sidebar.settingsCopiedMessage,
            parentWindow: parentWindow
        )
    }

    private func chooseJSONDestination(suggestedName: String, title: String) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.title = title
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func promptTextField(
        title: String,
        message: String,
        initialValue: String,
        confirmTitle: String
    ) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initialValue
        field.placeholderString = initialValue

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L10n.Common.cancel)

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func presentSimpleInfo(title: String, message: String, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.Common.ok)
        if let parentWindow {
            alert.beginSheetModal(for: parentWindow)
        } else {
            alert.runModal()
        }
    }

    private func safeFileName(_ rawName: String, fallback: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback : trimmed
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = base
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }
}

@MainActor
private final class AppKitSessionSidebarPingProgressPresenter: NSObject, SessionSidebarPingProgressPresenting, NSWindowDelegate {
    private enum Layout {
        static let panelSize = NSSize(width: 600, height: 376)
        static let contentInset: CGFloat = 22
        static let headerIconSize: CGFloat = 30
        static let outputHeight: CGFloat = 218
    }

    private let panel = NSPanel(
        contentRect: NSRect(origin: .zero, size: Layout.panelSize),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let titleLabel = NSTextField(labelWithString: L10n.Sidebar.pingProgressTitle)
    private let statusLabel: NSTextField
    private let statusPill = NSView()
    private let statusDot = NSView()
    private let statusTextLabel = NSTextField(labelWithString: L10n.Sidebar.pingLiveStatus)
    private let outputTextView = NSTextView()
    private let outputScrollView = NSScrollView()
    private let emptyOutputLabel = NSTextField(labelWithString: L10n.Sidebar.pingWaitingForOutput)
    private let progressIndicator = NSProgressIndicator()
    private let actionButton = NSButton(title: L10n.Common.stop, target: nil, action: nil)
    private var cancelHandler: (@MainActor () -> Void)?
    private var closeHandler: (@MainActor () -> Void)?
    private var isFinished = false
    private var isStopping = false
    private var didNotifyClose = false

    init(host: String, parentWindow: NSWindow?) {
        statusLabel = NSTextField(labelWithString: String(format: L10n.Sidebar.pingProgressMessage, host))
        super.init()
        configurePanel(host: host, parentWindow: parentWindow)
    }

    func setCancelHandler(_ handler: @escaping @MainActor () -> Void) {
        cancelHandler = handler
    }

    func setCloseHandler(_ handler: @escaping @MainActor () -> Void) {
        closeHandler = handler
    }

    func appendOutput(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        ensureOutputTextViewFrame()
        emptyOutputLabel.isHidden = true
        outputTextView.textStorage?.append(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: StacioDesignSystem.theme.primaryTextColor
                ]
            )
        )
        outputTextView.scrollRangeToVisible(NSRange(location: outputTextView.string.count, length: 0))
    }

    func finish(_ result: SessionSidebarPingResult) {
        isFinished = true
        isStopping = false
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusDot.isHidden = false
        configureStatusPill(
            text: result.reachable ? L10n.Sidebar.pingReachableStatus : L10n.Sidebar.pingUnreachableStatus,
            color: result.reachable ? StacioDesignSystem.theme.successColor : StacioDesignSystem.theme.dangerColor
        )
        titleLabel.stringValue = result.reachable
            ? L10n.Sidebar.pingSuccessTitle
            : L10n.Sidebar.pingFailedTitle
        statusLabel.stringValue = String(
            format: result.reachable ? L10n.Sidebar.pingSuccessMessage : L10n.Sidebar.pingFailedMessage,
            result.host
        )
        actionButton.title = L10n.Common.close
        actionButton.isEnabled = true
        if outputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendOutput(result.output)
        }
    }

    func fail(_ error: Error) {
        isFinished = true
        isStopping = false
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusDot.isHidden = false
        configureStatusPill(text: L10n.Sidebar.pingUnreachableStatus, color: StacioDesignSystem.theme.dangerColor)
        titleLabel.stringValue = L10n.Sidebar.pingFailedTitle
        statusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
        actionButton.title = L10n.Common.close
        actionButton.isEnabled = true
    }

    private func configurePanel(host: String, parentWindow: NSWindow?) {
        panel.title = L10n.Sidebar.pingHost
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.animationBehavior = .none
        panel.level = parentWindow == nil ? .floating : .normal
        panel.contentView = makeContentView()
        panel.setAccessibilityIdentifier("Stacio.Sidebar.pingProgressPanel")

        actionButton.target = self
        actionButton.action = #selector(actionButtonPressed(_:))

        if let parentWindow {
            panel.level = parentWindow.level
            parentWindow.addChildWindow(panel, ordered: .above)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
        progressIndicator.startAnimation(nil)
    }

    private func makeContentView() -> NSView {
        let root = StacioAppearanceRefreshView(frame: NSRect(origin: .zero, size: Layout.panelSize))
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.setLayerBackgroundColor(root, color: StacioDesignSystem.theme.windowBackgroundColor)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let header = makeHeaderView()
        let outputContainer = makeOutputContainerView()
        let footer = makeFooterView()

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(outputContainer)
        stack.addArrangedSubview(footer)

        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Layout.contentInset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Layout.contentInset),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),

            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            outputContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            outputContainer.heightAnchor.constraint(equalToConstant: Layout.outputHeight),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return root
    }

    private func makeHeaderView() -> NSView {
        let iconContainer = makeHeaderIconView()

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [titleLabel, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureStatusPill(text: L10n.Sidebar.pingLiveStatus, color: StacioDesignSystem.theme.accentColor)
        statusDot.isHidden = true

        let header = NSStackView(views: [iconContainer, titleStack, spacer, statusPill])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        return header
    }

    private func makeHeaderIconView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.setLayerBackgroundColor(
            container,
            color: StacioDesignSystem.theme.accentColor.withAlphaComponent(0.12)
        )
        container.layer?.cornerRadius = 8
        container.layer?.cornerCurve = .continuous

        let image = NSImage(
            systemSymbolName: "dot.radiowaves.left.and.right",
            accessibilityDescription: L10n.Sidebar.pingHost
        ) ?? NSImage(systemSymbolName: "network", accessibilityDescription: L10n.Sidebar.pingHost) ?? NSImage()
        let imageView = NSImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        imageView.contentTintColor = StacioDesignSystem.theme.accentColor

        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Layout.headerIconSize),
            container.heightAnchor.constraint(equalToConstant: Layout.headerIconSize),
            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 17),
            imageView.heightAnchor.constraint(equalToConstant: 17)
        ])
        return container
    }

    private func configureStatusPill(text: String, color: NSColor) {
        if statusPill.subviews.isEmpty {
            statusPill.translatesAutoresizingMaskIntoConstraints = false
            statusPill.setAccessibilityIdentifier("Stacio.Sidebar.pingProgressStatus")
            StacioDesignSystem.setLayerBackgroundColor(
                statusPill,
                color: StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.72)
            )
            StacioDesignSystem.setLayerBorderColor(
                statusPill,
                color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.34)
            )
            statusPill.layer?.borderWidth = 1
            statusPill.layer?.cornerRadius = 12
            statusPill.layer?.cornerCurve = .continuous

            progressIndicator.style = .spinning
            progressIndicator.controlSize = .small
            progressIndicator.translatesAutoresizingMaskIntoConstraints = false

            statusDot.translatesAutoresizingMaskIntoConstraints = false
            statusDot.wantsLayer = true
            statusDot.layer?.cornerRadius = 3.5
            statusDot.layer?.cornerCurve = .continuous

            statusTextLabel.font = .systemFont(ofSize: 12, weight: .medium)
            statusTextLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
            statusTextLabel.translatesAutoresizingMaskIntoConstraints = false

            let pillStack = NSStackView(views: [progressIndicator, statusDot, statusTextLabel])
            pillStack.translatesAutoresizingMaskIntoConstraints = false
            pillStack.orientation = .horizontal
            pillStack.alignment = .centerY
            pillStack.spacing = 6

            statusPill.addSubview(pillStack)
            NSLayoutConstraint.activate([
                pillStack.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 9),
                pillStack.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -10),
                pillStack.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 5),
                pillStack.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -5),
                progressIndicator.widthAnchor.constraint(equalToConstant: 14),
                progressIndicator.heightAnchor.constraint(equalToConstant: 14),
                statusDot.widthAnchor.constraint(equalToConstant: 7),
                statusDot.heightAnchor.constraint(equalToConstant: 7)
            ])
        }
        statusTextLabel.stringValue = text
        StacioDesignSystem.setLayerBackgroundColor(statusDot, color: color)
    }

    private func makeOutputContainerView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setAccessibilityIdentifier("Stacio.Sidebar.pingProgressOutputContainer")
        StacioDesignSystem.setLayerBackgroundColor(
            container,
            color: StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.72)
        )
        StacioDesignSystem.setLayerBorderColor(
            container,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.34)
        )
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 8
        container.layer?.cornerCurve = .continuous

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.drawsBackground = false
        outputTextView.minSize = NSSize(width: 0, height: 0)
        outputTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputTextView.isVerticallyResizable = true
        outputTextView.isHorizontallyResizable = false
        outputTextView.autoresizingMask = [.width]
        outputTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputTextView.textColor = StacioDesignSystem.theme.primaryTextColor
        outputTextView.textContainerInset = NSSize(width: 12, height: 10)
        outputTextView.textContainer?.lineFragmentPadding = 0
        outputTextView.textContainer?.containerSize = NSSize(
            width: max(1, Layout.panelSize.width - Layout.contentInset * 2 - 26),
            height: CGFloat.greatestFiniteMagnitude
        )
        outputTextView.textContainer?.widthTracksTextView = true
        outputTextView.setAccessibilityIdentifier("Stacio.Sidebar.pingProgressOutput")

        outputScrollView.contentView.postsBoundsChangedNotifications = true
        outputScrollView.documentView = outputTextView
        outputScrollView.hasVerticalScroller = true
        outputScrollView.hasHorizontalScroller = false
        outputScrollView.autohidesScrollers = true
        outputScrollView.drawsBackground = false
        outputScrollView.borderType = .noBorder
        outputScrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyOutputLabel.font = .systemFont(ofSize: 12, weight: .regular)
        emptyOutputLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyOutputLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyOutputLabel.setAccessibilityIdentifier("Stacio.Sidebar.pingProgressEmptyOutput")

        container.addSubview(outputScrollView)
        container.addSubview(emptyOutputLabel)
        NSLayoutConstraint.activate([
            outputScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 1),
            outputScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -1),
            outputScrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            outputScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            emptyOutputLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 13),
            emptyOutputLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 11)
        ])
        ensureOutputTextViewFrame()
        return container
    }

    private func ensureOutputTextViewFrame() {
        outputScrollView.layoutSubtreeIfNeeded()
        let visibleBounds = outputScrollView.contentView.bounds
        let targetSize = NSSize(
            width: max(visibleBounds.width, 1),
            height: max(visibleBounds.height, outputTextView.frame.height, 1)
        )
        if outputTextView.frame.size != targetSize {
            outputTextView.frame = NSRect(origin: .zero, size: targetSize)
        }
        outputTextView.textContainer?.containerSize = NSSize(
            width: max(targetSize.width - outputTextView.textContainerInset.width * 2, 1),
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func makeFooterView() -> NSView {
        StacioDesignSystem.styleSheetButton(actionButton)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.setAccessibilityIdentifier("Stacio.Sidebar.pingProgressAction")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [spacer, actionButton])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        NSLayoutConstraint.activate([
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 84)
        ])
        return footer
    }

    @objc private func actionButtonPressed(_ sender: NSButton) {
        if isFinished {
            closePanel()
        } else {
            requestStop()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isFinished {
            closePanel()
            return false
        }
        requestStop()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let parentWindow = panel.parent {
            parentWindow.removeChildWindow(panel)
        }
        notifyClosedIfNeeded()
    }

    private func requestStop() {
        guard !isStopping else {
            return
        }
        isStopping = true
        statusLabel.stringValue = L10n.Sidebar.pingStopping
        actionButton.isEnabled = false
        cancelHandler?()
    }

    private func closePanel() {
        notifyClosedIfNeeded()
        if let parentWindow = panel.parent {
            parentWindow.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }

    private func notifyClosedIfNeeded() {
        guard !didNotifyClose else {
            return
        }
        didNotifyClose = true
        closeHandler?()
    }
}
