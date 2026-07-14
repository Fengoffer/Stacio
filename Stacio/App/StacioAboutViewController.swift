import AppKit

@MainActor
public protocol StacioURLOpening {
    func open(_ url: URL)
}

@MainActor
public struct WorkspaceURLOpener: StacioURLOpening {
    public init() {}

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
public struct StacioAboutContent {
    public let applicationName: String
    public let displayVersion: String
    public let repositoryURL: URL
    public let weChatQRCodeImage: NSImage?

    public var githubAccessibilityLabel: String { "GitHub" }
    public var weChatAccessibilityLabel: String { "微信公众号" }

    public init(
        applicationName: String,
        displayVersion: String,
        repositoryURL: URL,
        weChatQRCodeImage: NSImage?
    ) {
        self.applicationName = applicationName
        self.displayVersion = displayVersion
        self.repositoryURL = repositoryURL
        self.weChatQRCodeImage = weChatQRCodeImage
    }

    public static func current() -> StacioAboutContent {
        StacioAboutContent(
            applicationName: StacioAppMetadata.applicationName,
            displayVersion: StacioAppMetadata.displayVersion,
            repositoryURL: URL(string: StacioAppMetadata.repositoryURL)!,
            weChatQRCodeImage: loadWeChatQRCodeImage()
        )
    }

    private static func loadWeChatQRCodeImage() -> NSImage? {
        if let image = loadWeChatQRCodeImage(from: .main) {
            return image
        }

        #if DEBUG
        return loadWeChatQRCodeImage(from: .module)
        #else
        return nil
        #endif
    }

    private static func loadWeChatQRCodeImage(from bundle: Bundle) -> NSImage? {
        let subdirectories: [String?] = ["About", nil]
        for subdirectory in subdirectories {
            if let url = bundle.url(
                forResource: "wechat-qrcode",
                withExtension: "jpg",
                subdirectory: subdirectory
            ) {
                return NSImage(contentsOf: url)
            }
        }
        return nil
    }
}

@MainActor
public final class StacioAboutWindowPresenter: AboutPanelPresenting {
    public static let shared = StacioAboutWindowPresenter()

    private var windowController: NSWindowController?
    private let urlOpener: StacioURLOpening

    public init(urlOpener: StacioURLOpening? = nil) {
        self.urlOpener = urlOpener ?? WorkspaceURLOpener()
    }

    public func showAboutPanel(content: StacioAboutContent) {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewController = StacioAboutViewController(content: content, urlOpener: urlOpener)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 248),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.Menu.about
        window.contentViewController = viewController
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
public final class StacioAboutViewController: NSViewController {
    private static let actionIconSize = NSSize(width: 18, height: 18)

    public private(set) var githubButtonForTesting: NSButton?
    public private(set) var weChatButtonForTesting: NSButton?
    public private(set) var weChatQRCodeImageForTesting: NSImage?

    private let content: StacioAboutContent
    private let urlOpener: StacioURLOpening

    public init(content: StacioAboutContent, urlOpener: StacioURLOpening? = nil) {
        self.content = content
        self.urlOpener = urlOpener ?? WorkspaceURLOpener()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func loadView() {
        let rootView = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 420, height: 248))
        rootView.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(rootView, color: NSColor.windowBackgroundColor)

        let appIconView = NSImageView(image: NSApp.applicationIconImage)
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: content.applicationName)
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let versionLabel = NSTextField(labelWithString: content.displayVersion)
        versionLabel.font = .systemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let githubButton = NSButton(
            title: "GitHub",
            target: self,
            action: #selector(openGitHub(_:))
        )
        githubButton.bezelStyle = .inline
        githubButton.isBordered = false
        githubButton.image = Self.makeGitHubIcon()
        githubButton.imagePosition = .imageLeading
        githubButton.contentTintColor = .linkColor
        githubButton.font = .systemFont(ofSize: 13, weight: .medium)
        githubButton.toolTip = content.githubAccessibilityLabel
        githubButton.setAccessibilityLabel(content.githubAccessibilityLabel)
        githubButton.translatesAutoresizingMaskIntoConstraints = false
        githubButtonForTesting = githubButton

        let qrImage = content.weChatQRCodeImage ?? Self.makeQRCodePlaceholderImage()
        let weChatButton = QRCodeHoverButton(
            title: content.weChatAccessibilityLabel,
            icon: Self.makeWeChatIcon(),
            popupImage: qrImage,
            accessibilityLabel: content.weChatAccessibilityLabel
        )
        weChatButton.bezelStyle = .inline
        weChatButton.isBordered = false
        weChatButton.imagePosition = .imageLeading
        weChatButton.contentTintColor = .linkColor
        weChatButton.font = .systemFont(ofSize: 13, weight: .medium)
        weChatButton.translatesAutoresizingMaskIntoConstraints = false
        weChatButtonForTesting = weChatButton
        weChatQRCodeImageForTesting = qrImage

        let actionStack = NSStackView(views: [githubButton, weChatButton])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.distribution = .gravityAreas
        actionStack.spacing = 22
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(appIconView)
        rootView.addSubview(titleLabel)
        rootView.addSubview(versionLabel)
        rootView.addSubview(actionStack)

        NSLayoutConstraint.activate([
            appIconView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 24),
            appIconView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 64),
            appIconView.heightAnchor.constraint(equalToConstant: 64),

            titleLabel.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 36),
            titleLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -36),

            versionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            versionLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 36),
            versionLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -36),

            actionStack.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 22),
            actionStack.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            actionStack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -22)
        ])

        view = rootView
    }

    public func openGitHubForTesting() {
        openGitHub()
    }

    @objc
    private func openGitHub(_ sender: Any? = nil) {
        openGitHub()
    }

    private func openGitHub() {
        urlOpener.open(content.repositoryURL)
    }

    private static func makeGitHubIcon() -> NSImage {
        let image = loadGitHubIcon() ?? NSImage(size: actionIconSize)
        image.size = actionIconSize
        image.isTemplate = true
        return image
    }

    private static func loadGitHubIcon() -> NSImage? {
        if let image = loadGitHubIcon(from: .main) {
            return image
        }

        #if DEBUG
        return loadGitHubIcon(from: .module)
        #else
        return nil
        #endif
    }

    private static func loadGitHubIcon(from bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(forResource: "github", withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private static func makeWeChatIcon() -> NSImage {
        let image = loadWeChatIcon() ?? NSImage(size: actionIconSize)
        image.size = actionIconSize
        image.isTemplate = true
        return image
    }

    private static func loadWeChatIcon() -> NSImage? {
        if let image = loadWeChatIcon(from: .main) {
            return image
        }

        #if DEBUG
        return loadWeChatIcon(from: .module)
        #else
        return nil
        #endif
    }

    private static func loadWeChatIcon(from bundle: Bundle) -> NSImage? {
        let subdirectories: [String?] = ["About", nil]
        for subdirectory in subdirectories {
            if let url = bundle.url(
                forResource: "wechat-official-account",
                withExtension: "svg",
                subdirectory: subdirectory
            ) {
                return NSImage(contentsOf: url)
            }
        }
        return nil
    }

    private static func makeQRCodePlaceholderImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 44, height: 44))
        image.lockFocus()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 44, height: 44), xRadius: 6, yRadius: 6).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 43, height: 43), xRadius: 6, yRadius: 6).stroke()
        image.unlockFocus()
        return image
    }
}

@MainActor
private final class QRCodeHoverButton: NSButton {
    private let popupImage: NSImage
    private var trackingArea: NSTrackingArea?
    private var popover: NSPopover?

    init(title: String, icon: NSImage, popupImage: NSImage, accessibilityLabel: String) {
        self.popupImage = popupImage
        super.init(frame: .zero)
        self.title = title
        image = icon
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        showPopover()
    }

    override func mouseExited(with event: NSEvent) {
        popover?.performClose(nil)
        popover = nil
    }

    private func showPopover() {
        guard popover == nil else { return }

        let imageView = NSImageView(image: popupImage)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 236, height: 236))
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        let contentController = NSViewController()
        contentController.view = container

        let popover = NSPopover()
        popover.contentViewController = contentController
        popover.behavior = .transient
        popover.animates = true
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
}
