import AppKit
import StacioCoreBindings

enum SessionSettingsProtocol: Int, CaseIterable, Equatable, Hashable {
    case ssh
    case telnet
    case rsh
    case xdmcp
    case vnc
    case ftp
    case scp
    case serial
    case file
    case shell
    case browser
    case mosh
    case awsS3
    case wsl

    var label: String {
        switch self {
        case .ssh:
            return "SSH（安全 Shell）"
        case .telnet:
            return "Telnet（远程登录）"
        case .rsh:
            return "RSH（远程 Shell）"
        case .xdmcp:
            return "XDMCP（图形登录）"
        case .vnc:
            return "VNC（远程控制）"
        case .ftp:
            return "FTP（文件传输）"
        case .scp:
            return "SCP（安全复制）"
        case .serial:
            return "串口"
        case .file:
            return "本地文件"
        case .shell:
            return "本地终端"
        case .browser:
            return "浏览器"
        case .mosh:
            return "Mosh（移动 Shell）"
        case .awsS3:
            return "S3 对象存储"
        case .wsl:
            return "WSL（Linux 子系统）"
        }
    }

    var sourceListLabel: String {
        switch self {
        case .ssh:
            return "SSH"
        case .telnet:
            return "Telnet"
        case .rsh:
            return "RSH"
        case .xdmcp:
            return "XDMCP"
        case .vnc:
            return "VNC"
        case .ftp:
            return "FTP"
        case .scp:
            return "SCP"
        case .serial:
            return "串口"
        case .file:
            return "本地文件"
        case .shell:
            return "本地终端"
        case .browser:
            return "浏览器"
        case .mosh:
            return "Mosh"
        case .awsS3:
            return "S3"
        case .wsl:
            return "WSL"
        }
    }

    var storageKey: String {
        switch self {
        case .ssh:
            return "ssh"
        case .telnet:
            return "telnet"
        case .rsh:
            return "rsh"
        case .xdmcp:
            return "xdmcp"
        case .vnc:
            return "vnc"
        case .ftp:
            return "ftp"
        case .scp:
            return "scp"
        case .serial:
            return "serial"
        case .file:
            return "file"
        case .shell:
            return "shell"
        case .browser:
            return "browser"
        case .mosh:
            return "mosh"
        case .awsS3:
            return "aws_s3"
        case .wsl:
            return "wsl"
        }
    }

    var defaultPort: UInt16 {
        switch self {
        case .ssh, .scp:
            return 22
        case .telnet:
            return 23
        case .rsh:
            return 514
        case .xdmcp:
            return 177
        case .vnc:
            return 5900
        case .ftp:
            return 21
        case .serial:
            return 9600
        case .file, .shell, .wsl:
            return 1
        case .browser, .awsS3:
            return 443
        case .mosh:
            return 60000
        }
    }

    init?(storageKey: String) {
        switch storageKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ssh":
            self = .ssh
        case "telnet":
            self = .telnet
        case "rsh":
            self = .rsh
        case "xdmcp":
            self = .xdmcp
        case "vnc":
            self = .vnc
        case "ftp":
            self = .ftp
        case "scp":
            self = .scp
        case "serial":
            self = .serial
        case "file":
            self = .file
        case "shell":
            self = .shell
        case "browser":
            self = .browser
        case "mosh":
            self = .mosh
        case "aws_s3", "awss3":
            self = .awsS3
        case "wsl":
            self = .wsl
        default:
            return nil
        }
    }

    var systemSymbolName: String {
        switch self {
        case .ssh:
            return "key.fill"
        case .telnet:
            return "diamond.fill"
        case .rsh:
            return "gearshape.2.fill"
        case .xdmcp:
            return "display"
        case .vnc:
            return "rectangle.connected.to.line.below"
        case .ftp:
            return "globe"
        case .scp:
            return "arrow.left.arrow.right"
        case .serial:
            return "cable.connector"
        case .file:
            return "folder"
        case .shell:
            return "terminal"
        case .browser:
            return "safari"
        case .mosh:
            return "antenna.radiowaves.left.and.right"
        case .awsS3:
            return "shippingbox"
        case .wsl:
            return "display"
        }
    }

    var isAvailableForSaving: Bool {
        switch self {
        case .ssh, .telnet, .vnc, .ftp, .scp, .serial, .file, .shell, .browser:
            return true
        case .rsh, .xdmcp, .mosh, .awsS3, .wsl:
            return false
        }
    }

    var isOfferedInNewSessionSettings: Bool {
        switch self {
        case .file, .browser:
            return false
        default:
            return isAvailableForSaving
        }
    }

    static var selectableCases: [SessionSettingsProtocol] {
        allCases.filter(\.isOfferedInNewSessionSettings)
    }
}

private struct SerialAdvancedSessionConfig: Codable {
    let kind: String
    let devicePath: String
    let baudRate: UInt32?
    let dataBits: UInt8
    let stopBits: UInt8
    let parity: String
    let flowControl: String
    let backspaceMode: String?
    let deviceProfile: String?
    let tagStyle: TagStyleSessionConfig?

    init(
        kind: String = "serial",
        devicePath: String,
        baudRate: UInt32?,
        dataBits: UInt8,
        stopBits: UInt8,
        parity: String,
        flowControl: String,
        backspaceMode: String? = "del",
        deviceProfile: String? = nil,
        tagStyle: TagStyleSessionConfig? = nil
    ) {
        self.kind = kind
        self.devicePath = devicePath
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.stopBits = stopBits
        self.parity = parity
        self.flowControl = flowControl
        self.backspaceMode = backspaceMode
        self.deviceProfile = deviceProfile
        self.tagStyle = tagStyle
    }
}

private struct SerialAdvancedSelection: Equatable {
    let deviceProfile: String
    let dataBits: String
    let stopBits: String
    let parity: String
    let flowControl: String
    let backspaceMode: String
}

private struct SerialNetworkDeviceProfile: Equatable {
    let rawValue: String
    let title: String
    let baudRate: UInt32?
    let dataBits: String
    let stopBits: String
    let parityTitle: String
    let flowControlTitle: String

    var appliesPreset: Bool {
        baudRate != nil
    }

    static let generic9600 = SerialNetworkDeviceProfile(
        rawValue: "network-generic-9600",
        title: L10n.SessionSettings.serialProfileGeneric9600,
        baudRate: 9_600,
        dataBits: "8",
        stopBits: "1",
        parityTitle: L10n.SessionSettings.none,
        flowControlTitle: L10n.SessionSettings.none
    )

    static let generic115200 = SerialNetworkDeviceProfile(
        rawValue: "network-generic-115200",
        title: L10n.SessionSettings.serialProfileGeneric115200,
        baudRate: 115_200,
        dataBits: "8",
        stopBits: "1",
        parityTitle: L10n.SessionSettings.none,
        flowControlTitle: L10n.SessionSettings.none
    )

    static let custom = SerialNetworkDeviceProfile(
        rawValue: "custom",
        title: L10n.SessionSettings.serialProfileCustom,
        baudRate: nil,
        dataBits: "8",
        stopBits: "1",
        parityTitle: L10n.SessionSettings.none,
        flowControlTitle: L10n.SessionSettings.none
    )

    static let all: [SerialNetworkDeviceProfile] = [
        generic9600,
        vendor(rawValue: "inspur-network", title: L10n.SessionSettings.serialProfileInspur),
        vendor(rawValue: "yuanmai-network", title: L10n.SessionSettings.serialProfileYuanmai),
        vendor(rawValue: "cisco", title: L10n.SessionSettings.serialProfileCisco),
        vendor(rawValue: "huawei", title: L10n.SessionSettings.serialProfileHuawei),
        vendor(rawValue: "h3c", title: L10n.SessionSettings.serialProfileH3C),
        vendor(rawValue: "ruijie", title: L10n.SessionSettings.serialProfileRuijie),
        vendor(rawValue: "bdcom", title: L10n.SessionSettings.serialProfileBDCOM),
        generic115200,
        custom
    ]

    static func profile(forTitle title: String?) -> SerialNetworkDeviceProfile {
        all.first { $0.title == title } ?? generic9600
    }

    static func profile(forRawValue rawValue: String?) -> SerialNetworkDeviceProfile {
        guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              normalized.isEmpty == false
        else {
            return generic9600
        }
        return all.first { $0.rawValue == normalized } ?? custom
    }

    static func profileMatching(
        baudRate: UInt32,
        dataBits: String,
        stopBits: String,
        parityTitle: String,
        flowControlTitle: String
    ) -> SerialNetworkDeviceProfile {
        all.first {
            $0.appliesPreset
                && $0.baudRate == baudRate
                && $0.dataBits == dataBits
                && $0.stopBits == stopBits
                && $0.parityTitle == parityTitle
                && $0.flowControlTitle == flowControlTitle
        } ?? custom
    }

    private static func vendor(rawValue: String, title: String) -> SerialNetworkDeviceProfile {
        SerialNetworkDeviceProfile(
            rawValue: rawValue,
            title: title,
            baudRate: generic9600.baudRate,
            dataBits: generic9600.dataBits,
            stopBits: generic9600.stopBits,
            parityTitle: generic9600.parityTitle,
            flowControlTitle: generic9600.flowControlTitle
        )
    }
}

private struct SerialConnectionFields: Equatable {
    let devicePath: String
    let baudRate: UInt32
}

private struct TagStyleSessionConfig: Codable {
    let color: String
}

private struct NetworkSessionTagStyleConfig: Codable {
    let tagStyle: TagStyleSessionConfig?
    let environment: String?
    let aiExecutionPolicy: String?
    let startupCommand: String?
    let postConnectScript: String?
    let environmentVariables: [String]?
    let connectTimeoutMs: UInt32?
    let proxyJump: SSHProxyJumpSessionConfig?
}

private struct SessionAutomationSelection: Equatable {
    let environment: String
    let aiExecutionPolicy: String
    let startupCommand: String
    let postConnectScript: String
    let environmentVariables: [String]
    let connectTimeoutMs: UInt32?
}

private struct SessionProtocolFormSnapshot {
    let values: SessionSidebarSessionFormValues
    let automation: SessionAutomationSelection
    let proxyJump: SSHProxyJumpSelection
}

@MainActor
final class SessionSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let sshForm: SessionSidebarSessionForm
    private let protocolListView = NSTableView()
    private let unsupportedContainer = NSView()
    private let unsupportedLabel = NSTextField(labelWithString: "")
    private let serialAdvancedView = NSView()
    private let serialProfilePopup = NSPopUpButton()
    private let serialDataBitsPopup = NSPopUpButton()
    private let serialStopBitsPopup = NSPopUpButton()
    private let serialParityPopup = NSPopUpButton()
    private let serialFlowControlPopup = NSPopUpButton()
    private let serialBackspaceModePopup = NSPopUpButton()
    private let serialStorageHintLabel = NSTextField(labelWithString: L10n.SessionSettings.serialStorageHint)
    private let automationView = NSView()
    private let environmentPopup = NSPopUpButton()
    private let aiExecutionPolicyPopup = NSPopUpButton()
    private let automationHintLabel = NSTextField(labelWithString: L10n.SessionSettings.automationHint)
    private let startupActionsView = NSView()
    private let startupCommandField = NSTextField()
    private let postConnectScriptTextView = NSTextView()
    private let environmentVariablesTextView = NSTextView()
    private let connectTimeoutSecondsField = NSTextField()
    private let startupActionsHintLabel = NSTextField(labelWithString: L10n.SessionSettings.startupActionsHint)
    private let proxyJumpView = NSView()
    private let proxyJumpModePopup = NSPopUpButton()
    private let proxyJumpSessionIDField = NSTextField()
    private let proxyJumpHostField = NSTextField()
    private let proxyJumpPortField = NSTextField()
    private let proxyJumpUsernameField = NSTextField()
    private let proxyJumpCredentialIDField = NSTextField()
    private let proxyJumpPrivateKeyPathField = NSTextField()
    private let proxyJumpHintLabel = NSTextField(labelWithString: L10n.SessionSettings.proxyJumpHint)
    private let sessionIconView = NSView()
    private let sessionIconImageView = NSImageView()
    private let sessionIconNameLabel = NSTextField(labelWithString: "默认")
    private let sessionIconChooseButton = NSButton(title: "选择…", target: nil, action: nil)
    private var serialAdvancedHeightConstraint: NSLayoutConstraint?
    private var sessionIconHeightConstraint: NSLayoutConstraint?
    private var serialAdvancedLabels: [NSTextField] = []
    private let saveButton = NSButton(title: L10n.Common.save, target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.Common.cancel, target: nil, action: nil)
    private let footerSeparator = NSBox()
    private let existingSession: SessionRecord?
    private let existingSerialConfigJSON: String?
    private weak var testingSaveButton: NSButton?
    private var selectedProtocol: SessionSettingsProtocol = .ssh
    private var initialSerialAdvancedSelection: SerialAdvancedSelection?
    private var existingSerialConfigLoaded = false
    private var existingSerialConnectionFields: SerialConnectionFields?
    private var protocolFormSnapshots: [SessionSettingsProtocol: SessionProtocolFormSnapshot] = [:]
    private var isSyncingProtocolListSelection = false
    private var existingAutomationSelection = SessionAutomationSelection(
        environment: "development",
        aiExecutionPolicy: "inherit",
        startupCommand: "",
        postConnectScript: "",
        environmentVariables: [],
        connectTimeoutMs: nil
    )
    private var existingProxyJumpSelection: SSHProxyJumpSelection = .disabled
    private var selectedSessionIconID: String?
    private var sessionIconPickerWindow: NSWindow?

    var onSave: ((SessionDraft) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(
        existingSession: SessionRecord?,
        selectedFolderID: String?,
        draftFactory: SessionSidebarSessionDraftFactory,
        existingSerialConfigJSON: String? = nil,
        serialDevicePathProvider: @escaping () -> [String] = SerialConnectionSupport.defaultDevicePaths
    ) {
        self.existingSession = existingSession
        self.existingSerialConfigJSON = existingSerialConfigJSON
        selectedSessionIconID = SessionIconConfigCodec.iconID(from: existingSerialConfigJSON)
        sshForm = SessionSidebarSessionForm(
            existingSession: existingSession,
            selectedFolderID: selectedFolderID,
            draftFactory: draftFactory,
            serialDevicePathProvider: serialDevicePathProvider
        )
        if let existingSession,
           let existingProtocol = SessionSettingsProtocol(storageKey: existingSession.protocol)
        {
            selectedProtocol = existingProtocol
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installInitialFirstResponder(in: view.window)
    }

    override func loadView() {
        let container = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 704, height: 526))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(container, color: NSColor.windowBackgroundColor)
        container.layer?.cornerRadius = 0
        container.layer?.borderWidth = 0
        container.setAccessibilityIdentifier("Stacio.SessionSettings.surface")

        let title = NSTextField(labelWithString: L10n.SessionSettings.title)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        title.translatesAutoresizingMaskIntoConstraints = false

        protocolListView.addTableColumn(makeProtocolColumn())
        protocolListView.headerView = nil
        protocolListView.rowHeight = 28
        protocolListView.intercellSpacing = NSSize(width: 0, height: 1)
        protocolListView.style = .sourceList
        protocolListView.backgroundColor = .clear
        protocolListView.gridStyleMask = []
        protocolListView.selectionHighlightStyle = .regular
        protocolListView.usesAlternatingRowBackgroundColors = false
        protocolListView.dataSource = self
        protocolListView.delegate = self
        protocolListView.setAccessibilityIdentifier("Stacio.SessionSettings.protocolList")
        protocolListView.setAccessibilityLabel("协议")

        let protocolScrollView = NSScrollView()
        protocolScrollView.documentView = protocolListView
        protocolScrollView.hasHorizontalScroller = false
        protocolScrollView.hasVerticalScroller = false
        protocolScrollView.autohidesScrollers = true
        protocolScrollView.borderType = .noBorder
        protocolScrollView.drawsBackground = false
        protocolScrollView.translatesAutoresizingMaskIntoConstraints = false

        sshForm.view.setAccessibilityIdentifier("Stacio.SessionSettings.sshForm")
        sshForm.view.translatesAutoresizingMaskIntoConstraints = false
        sshForm.bind(saveButton: saveButton)
        configureSerialAdvancedView()
        configureSessionIconView()
        applyExistingSerialAdvancedConfigIfNeeded()
        initialSerialAdvancedSelection = currentSerialAdvancedSelection()
        configureAutomationView()
        configureStartupActionsView()
        configureProxyJumpView()
        applyExistingAutomationConfigIfNeeded()
        applyExistingProxyJumpConfigIfNeeded()

        unsupportedLabel.alignment = .center
        unsupportedLabel.font = .systemFont(ofSize: 14)
        unsupportedLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        unsupportedLabel.lineBreakMode = .byWordWrapping
        unsupportedLabel.maximumNumberOfLines = 3
        unsupportedLabel.translatesAutoresizingMaskIntoConstraints = false
        unsupportedLabel.setAccessibilityIdentifier("Stacio.SessionSettings.unsupportedMessage")
        unsupportedContainer.translatesAutoresizingMaskIntoConstraints = false
        unsupportedContainer.addSubview(unsupportedLabel)

        let detailContainer = NSView()
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(sshForm.view)
        detailContainer.addSubview(sessionIconView)
        detailContainer.addSubview(serialAdvancedView)
        detailContainer.addSubview(automationView)
        detailContainer.addSubview(startupActionsView)
        detailContainer.addSubview(proxyJumpView)
        detailContainer.addSubview(unsupportedContainer)
        let detailScrollView = NSScrollView()
        detailScrollView.documentView = detailContainer
        detailScrollView.hasVerticalScroller = true
        detailScrollView.hasHorizontalScroller = false
        detailScrollView.autohidesScrollers = true
        detailScrollView.borderType = .noBorder
        detailScrollView.drawsBackground = false
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailScrollView.setAccessibilityIdentifier("Stacio.SessionSettings.detailScrollView")
        let serialAdvancedHeightConstraint = serialAdvancedView.heightAnchor.constraint(equalToConstant: 0)
        self.serialAdvancedHeightConstraint = serialAdvancedHeightConstraint
        let sessionIconHeightConstraint = sessionIconView.heightAnchor.constraint(equalToConstant: 36)
        self.sessionIconHeightConstraint = sessionIconHeightConstraint

        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveButtonPressed(_:))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.setAccessibilityIdentifier("Stacio.SessionSettings.saveButton")
        if #available(macOS 12.0, *) {
            saveButton.hasDestructiveAction = false
        }
        StacioDesignSystem.styleSheetButton(saveButton, isDefault: true)

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelButtonPressed(_:))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setAccessibilityIdentifier("Stacio.SessionSettings.cancelButton")
        if #available(macOS 12.0, *) {
            cancelButton.hasDestructiveAction = false
        }
        StacioDesignSystem.styleSheetButton(cancelButton)

        let footer = NSStackView(views: [NSView(), cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.setAccessibilityIdentifier("Stacio.SessionSettings.footerSeparator")

        container.addSubview(title)
        container.addSubview(detailScrollView)
        container.addSubview(footerSeparator)
        container.addSubview(footer)
        container.addSubview(protocolScrollView)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),

            protocolScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            protocolScrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            protocolScrollView.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
            protocolScrollView.heightAnchor.constraint(equalToConstant: 292),
            protocolScrollView.widthAnchor.constraint(equalToConstant: 146),

            protocolListView.widthAnchor.constraint(equalTo: protocolScrollView.widthAnchor),

            detailScrollView.leadingAnchor.constraint(equalTo: protocolScrollView.trailingAnchor, constant: 24),
            detailScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            detailScrollView.topAnchor.constraint(equalTo: protocolScrollView.topAnchor),
            detailScrollView.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -14),
            detailScrollView.heightAnchor.constraint(equalToConstant: 360),
            detailContainer.leadingAnchor.constraint(equalTo: detailScrollView.contentView.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: detailScrollView.contentView.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: detailScrollView.contentView.topAnchor),
            detailContainer.widthAnchor.constraint(equalTo: detailScrollView.contentView.widthAnchor),

            sshForm.view.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            sshForm.view.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            sshForm.view.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor),
            sshForm.view.bottomAnchor.constraint(lessThanOrEqualTo: detailContainer.bottomAnchor),

            sessionIconView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            sessionIconView.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor),
            sessionIconView.topAnchor.constraint(equalTo: sshForm.view.bottomAnchor, constant: 12),
            sessionIconHeightConstraint,

            serialAdvancedView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            serialAdvancedView.topAnchor.constraint(equalTo: sessionIconView.bottomAnchor, constant: 12),
            serialAdvancedView.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor),
            serialAdvancedView.bottomAnchor.constraint(lessThanOrEqualTo: automationView.topAnchor, constant: -10),
            serialAdvancedHeightConstraint,

            automationView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            automationView.topAnchor.constraint(equalTo: serialAdvancedView.bottomAnchor, constant: 12),
            automationView.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor),
            automationView.bottomAnchor.constraint(lessThanOrEqualTo: startupActionsView.topAnchor, constant: -12),

            startupActionsView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            startupActionsView.topAnchor.constraint(equalTo: automationView.bottomAnchor, constant: 10),
            startupActionsView.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor),
            startupActionsView.bottomAnchor.constraint(lessThanOrEqualTo: proxyJumpView.topAnchor, constant: -12),

            proxyJumpView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            proxyJumpView.topAnchor.constraint(equalTo: startupActionsView.bottomAnchor, constant: 12),
            proxyJumpView.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor),
            proxyJumpView.bottomAnchor.constraint(lessThanOrEqualTo: detailContainer.bottomAnchor),

            unsupportedContainer.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            unsupportedContainer.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            unsupportedContainer.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            unsupportedContainer.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            unsupportedLabel.centerXAnchor.constraint(equalTo: unsupportedContainer.centerXAnchor),
            unsupportedLabel.centerYAnchor.constraint(equalTo: unsupportedContainer.centerYAnchor),
            unsupportedLabel.widthAnchor.constraint(lessThanOrEqualTo: unsupportedContainer.widthAnchor, multiplier: 0.72),

            footerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerSeparator.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            footer.heightAnchor.constraint(equalToConstant: 32),
            saveButton.widthAnchor.constraint(equalToConstant: 86),
            cancelButton.widthAnchor.constraint(equalToConstant: 86)
        ])

        view = container
        sshForm.applyMode(formMode(for: selectedProtocol))
        selectProtocolInList(selectedProtocol)
        refreshProtocolState()
    }

    func installInitialFirstResponder(in window: NSWindow?) {
        guard let window else {
            return
        }
        window.initialFirstResponder = sshForm.initialFirstResponder
        window.makeFirstResponder(sshForm.initialFirstResponder)
    }

    func draft() throws -> SessionDraft? {
        guard selectedProtocol.isAvailableForSaving else {
            return nil
        }
        guard let draft = try sshForm.draft() else {
            return nil
        }
        let serialConnectionFields = effectiveSerialConnectionFields(for: draft)
        return SessionDraft(
            folderId: draft.folderId,
            name: draft.name,
            protocol: selectedProtocol.storageKey,
            host: serialConnectionFields?.devicePath ?? draft.host,
            port: serialConnectionFields?.baudRate ?? draft.port,
            username: draft.username,
            privateKeyPath: draft.privateKeyPath,
            credentialId: draft.credentialId,
            tags: draft.tags,
            configJson: try SessionIconConfigCodec.updatingIconID(
                selectedProtocol == .ssh ? selectedSessionIconID : nil,
                in: configJSON(
                    for: selectedProtocol,
                    host: serialConnectionFields?.devicePath ?? draft.host,
                    port: serialConnectionFields?.baudRate ?? draft.port,
                    baseConfigJSON: draft.configJson
                )
            )
        )
    }

    private func effectiveSerialConnectionFields(for draft: SessionDraft) -> SerialConnectionFields? {
        guard selectedProtocol == .serial,
              let existingSession,
              let existingSerialConnectionFields,
              draft.host == existingSession.host,
              draft.port == existingSession.port
        else {
            return nil
        }
        return existingSerialConnectionFields
    }

    private func configJSON(
        for sessionProtocol: SessionSettingsProtocol,
        host: String,
        port: UInt32,
        baseConfigJSON: String?
    ) throws -> String? {
        if sessionProtocol != .serial {
            return try automationConfigJSON(baseConfigJSON: baseConfigJSON)
        }
        let currentSelection = currentSerialAdvancedSelection()
        if existingSession != nil,
           !existingSerialConfigLoaded,
           currentSelection == initialSerialAdvancedSelection,
           host == existingSession?.host,
           port == existingSession?.port {
            return try automationConfigJSON(baseConfigJSON: baseConfigJSON)
        }
        let config = SerialAdvancedSessionConfig(
            devicePath: host,
            baudRate: port == 0 ? nil : port,
            dataBits: UInt8(serialDataBitsPopup.titleOfSelectedItem ?? "8") ?? 8,
            stopBits: UInt8(serialStopBitsPopup.titleOfSelectedItem ?? "1") ?? 1,
            parity: serialParityValue(),
            flowControl: serialFlowControlValue(),
            backspaceMode: serialBackspaceModeValue(),
            deviceProfile: serialDeviceProfileValue(),
            tagStyle: tagStyle(from: baseConfigJSON)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let serialConfigJSON = String(data: try encoder.encode(config), encoding: .utf8)
        return try automationConfigJSON(baseConfigJSON: serialConfigJSON)
    }

    private func tagStyle(from configJSON: String?) -> TagStyleSessionConfig? {
        guard let configJSON,
              let data = configJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(NetworkSessionTagStyleConfig.self, from: data)
        else {
            return nil
        }
        return decoded.tagStyle
    }

    private func automationConfigJSON(baseConfigJSON: String?) throws -> String? {
        var object: [String: Any] = [:]
        if let baseConfigJSON,
           let data = baseConfigJSON.data(using: .utf8),
           let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = decoded
        }
        let automation = currentAutomationSelection()
        if let proxyJump = SSHProxyJumpConfigCodec.proxyObject(from: currentProxyJumpSelection()) {
            object["proxyJump"] = proxyJump
        } else if object.keys.contains("proxyJump") {
            object.removeValue(forKey: "proxyJump")
        }
        if automation.environment != "development" || object.keys.contains("environment") {
            object["environment"] = automation.environment
        }
        if automation.aiExecutionPolicy != "inherit" || object.keys.contains("aiExecutionPolicy") {
            object["aiExecutionPolicy"] = automation.aiExecutionPolicy
        }
        if automation.startupCommand.isEmpty == false || object.keys.contains("startupCommand") {
            object["startupCommand"] = automation.startupCommand
        }
        if automation.postConnectScript.isEmpty == false || object.keys.contains("postConnectScript") {
            object["postConnectScript"] = automation.postConnectScript
        }
        if automation.environmentVariables.isEmpty == false || object.keys.contains("environmentVariables") {
            object["environmentVariables"] = automation.environmentVariables
        }
        if let connectTimeoutMs = automation.connectTimeoutMs {
            if connectTimeoutMs != SSHConnectionDefaults.fastConnectTimeoutMs || object.keys.contains("connectTimeoutMs") {
                object["connectTimeoutMs"] = Int(connectTimeoutMs)
            }
        } else if object.keys.contains("connectTimeoutMs") {
            object["connectTimeoutMs"] = Int(SSHConnectionDefaults.fastConnectTimeoutMs)
        }
        guard object.isEmpty == false else {
            return nil
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)
    }

    private func applyExistingAutomationConfigIfNeeded() {
        guard let configJSON = existingSerialConfigJSON,
              let data = configJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(NetworkSessionTagStyleConfig.self, from: data)
        else {
            selectAutomation(
                environment: "development",
                aiExecutionPolicy: "inherit",
                startupCommand: "",
                postConnectScript: "",
                environmentVariables: [],
                connectTimeoutMs: nil
            )
            return
        }
        let environment = normalizedEnvironment(decoded.environment)
        let aiExecutionPolicy = normalizedAIPolicy(decoded.aiExecutionPolicy)
        let startupCommand = normalizedStartupCommand(decoded.startupCommand)
        let postConnectScript = normalizedPostConnectScript(decoded.postConnectScript)
        let environmentVariables = normalizedEnvironmentVariables(decoded.environmentVariables ?? [])
        let connectTimeoutMs = normalizedConnectTimeoutMs(decoded.connectTimeoutMs)
        existingAutomationSelection = SessionAutomationSelection(
            environment: environment,
            aiExecutionPolicy: aiExecutionPolicy,
            startupCommand: startupCommand,
            postConnectScript: postConnectScript,
            environmentVariables: environmentVariables,
            connectTimeoutMs: connectTimeoutMs
        )
        selectAutomation(
            environment: environment,
            aiExecutionPolicy: aiExecutionPolicy,
            startupCommand: startupCommand,
            postConnectScript: postConnectScript,
            environmentVariables: environmentVariables,
            connectTimeoutMs: connectTimeoutMs
        )
    }

    private func applyExistingProxyJumpConfigIfNeeded() {
        let selection = SSHProxyJumpConfigCodec.selection(from: existingSerialConfigJSON)
        existingProxyJumpSelection = selection
        selectProxyJump(selection)
    }

    private func applyExistingSerialAdvancedConfigIfNeeded() {
        guard selectedProtocol == .serial,
              let configJSON = existingSerialConfigJSON,
              let data = configJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SerialAdvancedSessionConfig.self, from: data),
              decoded.kind == "serial"
        else {
            return
        }
        configureSerialPopupSelections(
            deviceProfile: serialProfileTitle(
                for: decoded.deviceProfile,
                baudRate: decoded.baudRate ?? existingSession?.port ?? 0,
                dataBits: decoded.dataBits,
                stopBits: decoded.stopBits,
                parity: decoded.parity,
                flowControl: decoded.flowControl
            ),
            baudRate: decoded.baudRate ?? existingSession?.port ?? 0,
            dataBits: String(decoded.dataBits),
            stopBits: String(decoded.stopBits),
            parity: serialParityTitle(for: decoded.parity),
            flowControl: serialFlowControlTitle(for: decoded.flowControl),
            backspaceMode: serialBackspaceTitle(for: decoded.backspaceMode)
        )
        sshForm.setConnectionValues(
            devicePath: decoded.devicePath,
            baudRate: decoded.baudRate ?? existingSession?.port ?? 0
        )
        existingSerialConfigLoaded = true
        existingSerialConnectionFields = SerialConnectionFields(
            devicePath: decoded.devicePath,
            baudRate: decoded.baudRate ?? existingSession?.port ?? 0
        )
    }

    private func currentSerialAdvancedSelection() -> SerialAdvancedSelection {
        SerialAdvancedSelection(
            deviceProfile: serialProfilePopup.titleOfSelectedItem ?? "",
            dataBits: serialDataBitsPopup.titleOfSelectedItem ?? "",
            stopBits: serialStopBitsPopup.titleOfSelectedItem ?? "",
            parity: serialParityPopup.titleOfSelectedItem ?? "",
            flowControl: serialFlowControlPopup.titleOfSelectedItem ?? "",
            backspaceMode: serialBackspaceModePopup.titleOfSelectedItem ?? ""
        )
    }

    private func currentAutomationSelection() -> SessionAutomationSelection {
        SessionAutomationSelection(
            environment: environmentRawValue(for: environmentPopup.titleOfSelectedItem),
            aiExecutionPolicy: aiPolicyRawValue(for: aiExecutionPolicyPopup.titleOfSelectedItem),
            startupCommand: normalizedStartupCommand(startupCommandField.stringValue),
            postConnectScript: normalizedPostConnectScript(postConnectScriptTextView.string),
            environmentVariables: normalizedEnvironmentVariables(
                environmentVariablesTextView.string.components(separatedBy: .newlines)
            ),
            connectTimeoutMs: connectTimeoutMsFromSeconds(connectTimeoutSecondsField.stringValue)
        )
    }

    private func currentProxyJumpSelection() -> SSHProxyJumpSelection {
        switch proxyJumpModePopup.titleOfSelectedItem {
        case L10n.SessionSettings.proxyJumpSavedSession:
            let sessionID = normalizedStartupCommand(proxyJumpSessionIDField.stringValue)
            return sessionID.isEmpty ? .disabled : .session(id: sessionID)
        case L10n.SessionSettings.proxyJumpManual:
            guard let port = UInt16(proxyJumpPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  port > 0
            else {
                return .disabled
            }
            let host = normalizedStartupCommand(proxyJumpHostField.stringValue)
            let username = normalizedStartupCommand(proxyJumpUsernameField.stringValue)
            guard host.isEmpty == false, username.isEmpty == false else {
                return .disabled
            }
            return .manual(
                ManualSSHProxyJumpConfig(
                    host: host,
                    port: port,
                    username: username,
                    credentialID: optionalProxyJumpValue(proxyJumpCredentialIDField.stringValue),
                    privateKeyPath: optionalProxyJumpValue(proxyJumpPrivateKeyPathField.stringValue),
                    connectTimeoutMs: connectTimeoutMsFromSeconds(connectTimeoutSecondsField.stringValue)
                )
            )
        default:
            return .disabled
        }
    }

    private func serialParityValue() -> String {
        switch serialParityPopup.titleOfSelectedItem {
        case L10n.SessionSettings.oddParity:
            return "odd"
        case L10n.SessionSettings.evenParity:
            return "even"
        default:
            return "none"
        }
    }

    private func serialFlowControlValue() -> String {
        switch serialFlowControlPopup.titleOfSelectedItem {
        case "RTS/CTS":
            return "rtscts"
        case "XON/XOFF":
            return "xonxoff"
        default:
            return "none"
        }
    }

    private func serialBackspaceModeValue() -> String {
        switch serialBackspaceModePopup.titleOfSelectedItem {
        case L10n.SessionSettings.backspaceControlH:
            return "ctrl_h"
        default:
            return "del"
        }
    }

    private func serialDeviceProfileValue() -> String? {
        let profile = SerialNetworkDeviceProfile.profile(forTitle: serialProfilePopup.titleOfSelectedItem)
        guard profile != .custom,
              serialProfileMatchesCurrentParameters(profile)
        else {
            return nil
        }
        return profile.rawValue
    }

    private func serialProfileMatchesCurrentParameters(_ profile: SerialNetworkDeviceProfile) -> Bool {
        guard let baudRate = profile.baudRate,
              UInt32(sshForm.portValueForTesting.trimmingCharacters(in: .whitespacesAndNewlines)) == baudRate
        else {
            return false
        }
        return serialDataBitsPopup.titleOfSelectedItem == profile.dataBits
            && serialStopBitsPopup.titleOfSelectedItem == profile.stopBits
            && serialParityPopup.titleOfSelectedItem == profile.parityTitle
            && serialFlowControlPopup.titleOfSelectedItem == profile.flowControlTitle
    }

    private func serialParityTitle(for value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "odd":
            return L10n.SessionSettings.oddParity
        case "even":
            return L10n.SessionSettings.evenParity
        default:
            return L10n.SessionSettings.none
        }
    }

    private func serialProfileTitle(
        for rawValue: String?,
        baudRate: UInt32,
        dataBits: UInt8,
        stopBits: UInt8,
        parity: String,
        flowControl: String
    ) -> String {
        if let rawValue,
           rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return SerialNetworkDeviceProfile.profile(forRawValue: rawValue).title
        }
        return SerialNetworkDeviceProfile.profileMatching(
            baudRate: baudRate,
            dataBits: String(dataBits),
            stopBits: String(stopBits),
            parityTitle: serialParityTitle(for: parity),
            flowControlTitle: serialFlowControlTitle(for: flowControl)
        ).title
    }

    private func serialFlowControlTitle(for value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rtscts":
            return "RTS/CTS"
        case "xonxoff":
            return "XON/XOFF"
        default:
            return L10n.SessionSettings.none
        }
    }

    private func serialBackspaceTitle(for value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ctrl_h":
            return L10n.SessionSettings.backspaceControlH
        default:
            return L10n.SessionSettings.backspaceDelete
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        SessionSettingsProtocol.selectableCases.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingProtocolListSelection else {
            return
        }
        let selectedRow = protocolListView.selectedRow
        guard SessionSettingsProtocol.selectableCases.indices.contains(selectedRow) else {
            return
        }
        applySelectedProtocol(SessionSettingsProtocol.selectableCases[selectedRow])
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard SessionSettingsProtocol.selectableCases.indices.contains(row) else {
            return nil
        }
        let sessionProtocol = SessionSettingsProtocol.selectableCases[row]
        let identifier = NSUserInterfaceItemIdentifier("SessionSettingsProtocolCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier

        let imageView = cell.imageView ?? NSImageView()
        imageView.image = NSImage(
            systemSymbolName: sessionProtocol.systemSymbolName,
            accessibilityDescription: sessionProtocol.label
        )
        imageView.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        imageView.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = imageView

        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.stringValue = sessionProtocol.sourceListLabel
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.textColor = StacioDesignSystem.theme.primaryTextColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = textField

        if imageView.superview == nil {
            cell.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16)
            ])
        }
        if textField.superview == nil {
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }

    private func makeProtocolColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("protocol"))
        column.width = 146
        column.minWidth = 146
        column.maxWidth = 146
        column.resizingMask = []
        return column
    }

    @objc private func protocolSelectionChanged(_ sender: NSSegmentedControl) {
        let selectableProtocols = SessionSettingsProtocol.selectableCases
        let selectedIndex = sender.selectedSegment
        let sessionProtocol = selectableProtocols.indices.contains(selectedIndex)
            ? selectableProtocols[selectedIndex]
            : .ssh
        applySelectedProtocol(sessionProtocol)
    }

    private func applySelectedProtocol(_ sessionProtocol: SessionSettingsProtocol) {
        guard sessionProtocol != selectedProtocol else {
            selectProtocolInList(sessionProtocol)
            sshForm.applyMode(formMode(for: sessionProtocol))
            refreshProtocolState()
            return
        }
        storeCurrentProtocolFormSnapshot()
        selectedProtocol = sessionProtocol
        selectProtocolInList(sessionProtocol)
        sshForm.applyMode(formMode(for: sessionProtocol))
        restoreProtocolFormSnapshot(for: sessionProtocol)
        refreshProtocolState()
    }

    private func selectProtocolInList(_ sessionProtocol: SessionSettingsProtocol) {
        guard protocolListView.numberOfRows > 0,
              let index = SessionSettingsProtocol.selectableCases.firstIndex(of: sessionProtocol),
              protocolListView.selectedRow != index
        else {
            return
        }
        isSyncingProtocolListSelection = true
        defer {
            isSyncingProtocolListSelection = false
        }
        protocolListView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        protocolListView.scrollRowToVisible(index)
    }

    private func storeCurrentProtocolFormSnapshot() {
        guard selectedProtocol.isAvailableForSaving else {
            return
        }
        protocolFormSnapshots[selectedProtocol] = SessionProtocolFormSnapshot(
            values: sshForm.currentValues,
            automation: currentAutomationSelection(),
            proxyJump: currentProxyJumpSelection()
        )
    }

    private func restoreProtocolFormSnapshot(for sessionProtocol: SessionSettingsProtocol) {
        let snapshot = protocolFormSnapshots[sessionProtocol]
            ?? SessionProtocolFormSnapshot(
                values: defaultFormValues(for: sessionProtocol),
                automation: defaultAutomationSelection(),
                proxyJump: .disabled
            )
        sshForm.restoreValues(snapshot.values)
        selectAutomation(
            environment: snapshot.automation.environment,
            aiExecutionPolicy: snapshot.automation.aiExecutionPolicy,
            startupCommand: snapshot.automation.startupCommand,
            postConnectScript: snapshot.automation.postConnectScript,
            environmentVariables: snapshot.automation.environmentVariables,
            connectTimeoutMs: snapshot.automation.connectTimeoutMs
        )
        selectProxyJump(snapshot.proxyJump)
    }

    private func defaultFormValues(for sessionProtocol: SessionSettingsProtocol) -> SessionSidebarSessionFormValues {
        SessionSidebarSessionFormValues(
            name: "",
            host: "",
            port: String(sessionProtocol.defaultPort),
            username: "",
            authMode: .password,
            privateKeyPath: "",
            credentialSecret: "",
            tags: "",
            tagColorHex: nil,
            allowsZeroPort: formMode(for: sessionProtocol).allowsZeroPort
        )
    }

    private func defaultAutomationSelection() -> SessionAutomationSelection {
        SessionAutomationSelection(
            environment: "development",
            aiExecutionPolicy: "inherit",
            startupCommand: "",
            postConnectScript: "",
            environmentVariables: [],
            connectTimeoutMs: nil
        )
    }

    private func formMode(for sessionProtocol: SessionSettingsProtocol) -> SessionSidebarSessionFormMode {
        switch sessionProtocol {
        case .serial:
            return .serial
        case .ftp:
            return .ftp
        case .browser:
            return .browser
        case .file:
            return .file
        case .shell:
            return .shell
        default:
            return .network
        }
    }

    @objc private func saveButtonPressed(_ sender: NSButton) {
        do {
            guard let draft = try draft() else {
                return
            }
            onSave?(draft)
        } catch {
            onError?(error)
        }
    }

    @objc private func cancelButtonPressed(_ sender: NSButton) {
        onCancel?()
    }

    private func configureSessionIconView() {
        sessionIconView.translatesAutoresizingMaskIntoConstraints = false
        sessionIconView.setAccessibilityIdentifier("Stacio.SessionSettings.sessionIcon")

        let titleLabel = NSTextField(labelWithString: "会话图标")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        sessionIconImageView.imageScaling = .scaleProportionallyUpOrDown
        sessionIconImageView.translatesAutoresizingMaskIntoConstraints = false

        sessionIconNameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        sessionIconNameLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        sessionIconNameLabel.lineBreakMode = .byTruncatingTail
        sessionIconNameLabel.translatesAutoresizingMaskIntoConstraints = false

        sessionIconChooseButton.target = self
        sessionIconChooseButton.action = #selector(chooseSessionIcon(_:))
        sessionIconChooseButton.bezelStyle = .rounded
        sessionIconChooseButton.translatesAutoresizingMaskIntoConstraints = false
        sessionIconChooseButton.setAccessibilityIdentifier("Stacio.SessionSettings.sessionIconChoose")

        sessionIconView.addSubview(titleLabel)
        sessionIconView.addSubview(sessionIconImageView)
        sessionIconView.addSubview(sessionIconNameLabel)
        sessionIconView.addSubview(sessionIconChooseButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: sessionIconView.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: sessionIconView.centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 76),
            sessionIconImageView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            sessionIconImageView.centerYAnchor.constraint(equalTo: sessionIconView.centerYAnchor),
            sessionIconImageView.widthAnchor.constraint(equalToConstant: 24),
            sessionIconImageView.heightAnchor.constraint(equalToConstant: 24),
            sessionIconNameLabel.leadingAnchor.constraint(equalTo: sessionIconImageView.trailingAnchor, constant: 8),
            sessionIconNameLabel.centerYAnchor.constraint(equalTo: sessionIconView.centerYAnchor),
            sessionIconChooseButton.leadingAnchor.constraint(greaterThanOrEqualTo: sessionIconNameLabel.trailingAnchor, constant: 10),
            sessionIconChooseButton.trailingAnchor.constraint(equalTo: sessionIconView.trailingAnchor),
            sessionIconChooseButton.centerYAnchor.constraint(equalTo: sessionIconView.centerYAnchor),
            sessionIconChooseButton.widthAnchor.constraint(equalToConstant: 76)
        ])
        updateSessionIconPreview()
    }

    @objc private func chooseSessionIcon(_ sender: NSButton) {
        guard let parentWindow = view.window else { return }
        let picker = SessionIconPickerViewController(selectedIconID: selectedSessionIconID)
        let pickerWindow = NSWindow(contentViewController: picker)
        pickerWindow.title = "选择会话图标"
        pickerWindow.styleMask = [.titled, .closable, .resizable]
        pickerWindow.setContentSize(NSSize(width: 560, height: 460))
        pickerWindow.minSize = NSSize(width: 480, height: 400)
        sessionIconPickerWindow = pickerWindow

        picker.onConfirm = { [weak self, weak parentWindow, weak pickerWindow] iconID in
            guard let self, let parentWindow, let pickerWindow else { return }
            selectedSessionIconID = iconID
            updateSessionIconPreview()
            parentWindow.endSheet(pickerWindow)
            sessionIconPickerWindow = nil
        }
        picker.onCancel = { [weak self, weak parentWindow, weak pickerWindow] in
            guard let parentWindow, let pickerWindow else { return }
            parentWindow.endSheet(pickerWindow)
            self?.sessionIconPickerWindow = nil
        }
        parentWindow.beginSheet(pickerWindow)
    }

    private func updateSessionIconPreview() {
        if let definition = SessionIconCatalog.definition(id: selectedSessionIconID),
           let image = SessionIconCatalog.image(for: definition.id, size: NSSize(width: 24, height: 24)) {
            sessionIconImageView.image = image
            sessionIconNameLabel.stringValue = definition.displayName
        } else {
            sessionIconImageView.image = SessionTabIconDescriptor.sshDefault.image(size: NSSize(width: 24, height: 24))
            sessionIconNameLabel.stringValue = "默认"
        }
    }

    private func refreshProtocolState() {
        sshForm.view.isHidden = !selectedProtocol.isAvailableForSaving
        serialAdvancedView.isHidden = selectedProtocol != .serial
        serialAdvancedHeightConstraint?.isActive = selectedProtocol != .serial
        unsupportedContainer.isHidden = selectedProtocol.isAvailableForSaving
        unsupportedLabel.stringValue = selectedProtocol.isAvailableForSaving
            ? ""
            : L10n.SessionSettings.unsupportedProtocol(selectedProtocol.label)
        automationView.isHidden = !selectedProtocol.isAvailableForSaving
        proxyJumpView.isHidden = selectedProtocol != .ssh && selectedProtocol != .scp
        let showsSessionIcon = selectedProtocol == .ssh
        sessionIconView.isHidden = !showsSessionIcon
        sessionIconHeightConstraint?.constant = showsSessionIcon ? 36 : 0

        if selectedProtocol.isAvailableForSaving {
            saveButton.isEnabled = sshForm.isValidForSaving
            testingSaveButton?.isEnabled = sshForm.isValidForSaving
        } else {
            saveButton.isEnabled = false
            testingSaveButton?.isEnabled = false
        }
    }

    private func configureSerialAdvancedView() {
        serialAdvancedView.translatesAutoresizingMaskIntoConstraints = false
        serialAdvancedView.setAccessibilityIdentifier("Stacio.SessionSettings.serialAdvanced")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        serialAdvancedView.addSubview(stack)

        configureSerialPopup(
            serialProfilePopup,
            titles: SerialNetworkDeviceProfile.all.map(\.title),
            selectedTitle: SerialNetworkDeviceProfile.generic9600.title,
            width: 260
        )
        serialProfilePopup.setAccessibilityIdentifier("Stacio.SessionSettings.serialProfile")
        serialProfilePopup.target = self
        serialProfilePopup.action = #selector(serialProfileChanged(_:))
        configureSerialPopup(serialDataBitsPopup, titles: ["8", "7", "6", "5"], selectedTitle: "8")
        configureSerialPopup(serialStopBitsPopup, titles: ["1", "2"], selectedTitle: "1")
        configureSerialPopup(serialParityPopup, titles: [
            L10n.SessionSettings.none,
            L10n.SessionSettings.oddParity,
            L10n.SessionSettings.evenParity
        ], selectedTitle: L10n.SessionSettings.none)
        configureSerialPopup(serialFlowControlPopup, titles: [
            L10n.SessionSettings.none,
            "RTS/CTS",
            "XON/XOFF"
        ], selectedTitle: L10n.SessionSettings.none)
        configureSerialPopup(serialBackspaceModePopup, titles: [
            L10n.SessionSettings.backspaceDelete,
            L10n.SessionSettings.backspaceControlH
        ], selectedTitle: L10n.SessionSettings.backspaceDelete)

        let rows = [
            Self.serialRow(label: L10n.SessionSettings.serialDeviceProfile, field: serialProfilePopup),
            Self.serialRow(label: L10n.SessionSettings.dataBits, field: serialDataBitsPopup),
            Self.serialRow(label: L10n.SessionSettings.stopBits, field: serialStopBitsPopup),
            Self.serialRow(label: L10n.SessionSettings.parity, field: serialParityPopup),
            Self.serialRow(label: L10n.SessionSettings.flowControl, field: serialFlowControlPopup),
            Self.serialRow(label: L10n.SessionSettings.backspaceMode, field: serialBackspaceModePopup),
            Self.serialRow(label: L10n.SessionSettings.storageNote, field: serialStorageHintLabel)
        ]
        serialAdvancedLabels = rows.map(\.label)
        rows.map(\.container).forEach(stack.addArrangedSubview(_:))

        serialStorageHintLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        serialStorageHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        serialStorageHintLabel.lineBreakMode = .byWordWrapping
        serialStorageHintLabel.maximumNumberOfLines = 2
        serialStorageHintLabel.widthAnchor.constraint(equalToConstant: 250).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: serialAdvancedView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: serialAdvancedView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: serialAdvancedView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: serialAdvancedView.bottomAnchor)
        ])
    }

    private func configureAutomationView() {
        automationView.translatesAutoresizingMaskIntoConstraints = false
        automationView.setAccessibilityIdentifier("Stacio.SessionSettings.automation")

        configurePopup(
            environmentPopup,
            titles: [
                L10n.SessionSettings.environmentDevelopment,
                L10n.SessionSettings.environmentStaging,
                L10n.SessionSettings.environmentProduction
            ],
            selectedTitle: L10n.SessionSettings.environmentDevelopment
        )
        environmentPopup.setAccessibilityIdentifier("Stacio.SessionSettings.environment")
        configurePopup(
            aiExecutionPolicyPopup,
            titles: [
                L10n.SessionSettings.aiPolicyInherit,
                L10n.SessionSettings.aiPolicyDisabled,
                L10n.SessionSettings.aiPolicyCommandCard,
                L10n.SessionSettings.aiPolicyReadOnlyAuto,
                L10n.SessionSettings.aiPolicyRequireEveryCommand
            ],
            selectedTitle: L10n.SessionSettings.aiPolicyInherit
        )
        aiExecutionPolicyPopup.setAccessibilityIdentifier("Stacio.SessionSettings.aiExecutionPolicy")

        automationHintLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        automationHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        automationHintLabel.lineBreakMode = .byWordWrapping
        automationHintLabel.maximumNumberOfLines = 2
        automationHintLabel.widthAnchor.constraint(equalToConstant: 292).isActive = true

        let policyStack = NSStackView(views: [
            compactAutomationControl(
                label: L10n.SessionSettings.environment,
                field: environmentPopup
            ),
            compactAutomationControl(
                label: L10n.SessionSettings.aiExecutionPolicy,
                field: aiExecutionPolicyPopup
            )
        ])
        policyStack.orientation = .horizontal
        policyStack.alignment = .firstBaseline
        policyStack.spacing = 12
        policyStack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: L10n.SessionSettings.automation)
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        heading.textColor = StacioDesignSystem.theme.secondaryTextColor
        heading.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [heading, policyStack, automationHintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        automationView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: automationView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: automationView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: automationView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: automationView.bottomAnchor)
        ])
    }

    private func configureStartupActionsView() {
        startupActionsView.translatesAutoresizingMaskIntoConstraints = false
        startupActionsView.setAccessibilityIdentifier("Stacio.SessionSettings.startupActions")

        startupCommandField.translatesAutoresizingMaskIntoConstraints = false
        startupCommandField.placeholderString = "cd /srv/app && ./healthcheck.sh"
        startupCommandField.lineBreakMode = .byTruncatingTail
        startupCommandField.setAccessibilityIdentifier("Stacio.SessionSettings.startupCommand")
        StacioDesignSystem.styleTextField(startupCommandField)
        startupCommandField.widthAnchor.constraint(equalToConstant: 292).isActive = true

        postConnectScriptTextView.isRichText = false
        postConnectScriptTextView.isAutomaticQuoteSubstitutionEnabled = false
        postConnectScriptTextView.isAutomaticDashSubstitutionEnabled = false
        postConnectScriptTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        postConnectScriptTextView.textColor = StacioDesignSystem.theme.primaryTextColor
        postConnectScriptTextView.backgroundColor = NSColor.textBackgroundColor
        postConnectScriptTextView.textContainerInset = NSSize(width: 6, height: 5)
        postConnectScriptTextView.setAccessibilityIdentifier("Stacio.SessionSettings.postConnectScript")

        let postConnectScriptScrollView = NSScrollView()
        postConnectScriptScrollView.documentView = postConnectScriptTextView
        postConnectScriptScrollView.hasVerticalScroller = true
        postConnectScriptScrollView.hasHorizontalScroller = false
        postConnectScriptScrollView.autohidesScrollers = true
        postConnectScriptScrollView.borderType = .bezelBorder
        postConnectScriptScrollView.translatesAutoresizingMaskIntoConstraints = false
        postConnectScriptScrollView.setAccessibilityIdentifier("Stacio.SessionSettings.postConnectScriptScroll")

        connectTimeoutSecondsField.translatesAutoresizingMaskIntoConstraints = false
        connectTimeoutSecondsField.stringValue = SSHConnectionDefaults.fastConnectTimeoutSecondsString
        connectTimeoutSecondsField.placeholderString = SSHConnectionDefaults.fastConnectTimeoutSecondsString
        connectTimeoutSecondsField.alignment = .right
        connectTimeoutSecondsField.setAccessibilityIdentifier("Stacio.SessionSettings.connectTimeoutSeconds")
        StacioDesignSystem.styleTextField(connectTimeoutSecondsField)
        connectTimeoutSecondsField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        environmentVariablesTextView.isRichText = false
        environmentVariablesTextView.isAutomaticQuoteSubstitutionEnabled = false
        environmentVariablesTextView.isAutomaticDashSubstitutionEnabled = false
        environmentVariablesTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        environmentVariablesTextView.textColor = StacioDesignSystem.theme.primaryTextColor
        environmentVariablesTextView.backgroundColor = NSColor.textBackgroundColor
        environmentVariablesTextView.textContainerInset = NSSize(width: 6, height: 5)
        environmentVariablesTextView.setAccessibilityIdentifier("Stacio.SessionSettings.environmentVariables")

        let environmentScrollView = NSScrollView()
        environmentScrollView.documentView = environmentVariablesTextView
        environmentScrollView.hasVerticalScroller = true
        environmentScrollView.hasHorizontalScroller = false
        environmentScrollView.autohidesScrollers = true
        environmentScrollView.borderType = .bezelBorder
        environmentScrollView.translatesAutoresizingMaskIntoConstraints = false
        environmentScrollView.setAccessibilityIdentifier("Stacio.SessionSettings.environmentVariablesScroll")

        startupActionsHintLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        startupActionsHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        startupActionsHintLabel.lineBreakMode = .byWordWrapping
        startupActionsHintLabel.maximumNumberOfLines = 2
        startupActionsHintLabel.widthAnchor.constraint(equalToConstant: 292).isActive = true

        let heading = NSTextField(labelWithString: L10n.SessionSettings.startupActions)
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        heading.textColor = StacioDesignSystem.theme.secondaryTextColor
        heading.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            heading,
            compactStartupControl(
                label: L10n.SessionSettings.startupCommand,
                field: startupCommandField
            ),
            compactStartupControl(
                label: L10n.SessionSettings.postConnectScript,
                field: postConnectScriptScrollView
            ),
            compactStartupControl(
                label: L10n.SessionSettings.connectTimeoutSeconds,
                field: connectTimeoutSecondsField
            ),
            compactStartupControl(
                label: L10n.SessionSettings.environmentVariables,
                field: environmentScrollView
            ),
            startupActionsHintLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        startupActionsView.addSubview(stack)
        NSLayoutConstraint.activate([
            postConnectScriptScrollView.widthAnchor.constraint(equalToConstant: 292),
            postConnectScriptScrollView.heightAnchor.constraint(equalToConstant: 72),
            environmentScrollView.widthAnchor.constraint(equalToConstant: 292),
            environmentScrollView.heightAnchor.constraint(equalToConstant: 58),
            stack.leadingAnchor.constraint(equalTo: startupActionsView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: startupActionsView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: startupActionsView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: startupActionsView.bottomAnchor)
        ])
    }

    private func configureProxyJumpView() {
        proxyJumpView.translatesAutoresizingMaskIntoConstraints = false
        proxyJumpView.setAccessibilityIdentifier("Stacio.SessionSettings.proxyJump")

        configurePopup(
            proxyJumpModePopup,
            titles: [
                L10n.SessionSettings.proxyJumpDisabled,
                L10n.SessionSettings.proxyJumpSavedSession,
                L10n.SessionSettings.proxyJumpManual
            ],
            selectedTitle: L10n.SessionSettings.proxyJumpDisabled
        )
        proxyJumpModePopup.target = self
        proxyJumpModePopup.action = #selector(proxyJumpModeChanged(_:))
        proxyJumpModePopup.setAccessibilityIdentifier("Stacio.SessionSettings.proxyJumpMode")

        configureProxyJumpTextField(proxyJumpSessionIDField, identifier: "Stacio.SessionSettings.proxyJumpSessionID", placeholder: "session-id")
        configureProxyJumpTextField(proxyJumpHostField, identifier: "Stacio.SessionSettings.proxyJumpHost", placeholder: "bastion.example.com")
        configureProxyJumpTextField(proxyJumpPortField, identifier: "Stacio.SessionSettings.proxyJumpPort", placeholder: "22")
        proxyJumpPortField.alignment = .right
        configureProxyJumpTextField(proxyJumpUsernameField, identifier: "Stacio.SessionSettings.proxyJumpUsername", placeholder: NSUserName())
        configureProxyJumpTextField(proxyJumpCredentialIDField, identifier: "Stacio.SessionSettings.proxyJumpCredentialID", placeholder: "credential-id")
        configureProxyJumpTextField(proxyJumpPrivateKeyPathField, identifier: "Stacio.SessionSettings.proxyJumpPrivateKeyPath", placeholder: "~/.ssh/id_ed25519")

        proxyJumpHintLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        proxyJumpHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        proxyJumpHintLabel.lineBreakMode = .byWordWrapping
        proxyJumpHintLabel.maximumNumberOfLines = 2
        proxyJumpHintLabel.widthAnchor.constraint(equalToConstant: 292).isActive = true

        let heading = NSTextField(labelWithString: L10n.SessionSettings.proxyJump)
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        heading.textColor = StacioDesignSystem.theme.secondaryTextColor
        heading.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            heading,
            compactStartupControl(label: L10n.SessionSettings.proxyJumpMode, field: proxyJumpModePopup),
            compactStartupControl(label: L10n.SessionSettings.proxyJumpSessionID, field: proxyJumpSessionIDField),
            compactStartupControl(label: L10n.SessionSettings.host, field: proxyJumpHostField),
            compactStartupControl(label: L10n.SessionSettings.port, field: proxyJumpPortField),
            compactStartupControl(label: L10n.SessionSettings.user, field: proxyJumpUsernameField),
            compactStartupControl(label: L10n.SessionSettings.proxyJumpCredentialID, field: proxyJumpCredentialIDField),
            compactStartupControl(label: L10n.SessionSettings.privateKey, field: proxyJumpPrivateKeyPathField),
            proxyJumpHintLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        proxyJumpView.addSubview(stack)
        NSLayoutConstraint.activate([
            proxyJumpModePopup.widthAnchor.constraint(equalToConstant: 292),
            proxyJumpSessionIDField.widthAnchor.constraint(equalToConstant: 292),
            proxyJumpHostField.widthAnchor.constraint(equalToConstant: 292),
            proxyJumpPortField.widthAnchor.constraint(equalToConstant: 72),
            proxyJumpUsernameField.widthAnchor.constraint(equalToConstant: 292),
            proxyJumpCredentialIDField.widthAnchor.constraint(equalToConstant: 292),
            proxyJumpPrivateKeyPathField.widthAnchor.constraint(equalToConstant: 292),
            stack.leadingAnchor.constraint(equalTo: proxyJumpView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: proxyJumpView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: proxyJumpView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: proxyJumpView.bottomAnchor)
        ])
        refreshProxyJumpModeFields()
    }

    private func configureProxyJumpTextField(_ field: NSTextField, identifier: String, placeholder: String) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityIdentifier(identifier)
        StacioDesignSystem.styleTextField(field)
    }

    @objc private func proxyJumpModeChanged(_ sender: NSPopUpButton) {
        refreshProxyJumpModeFields()
        refreshProtocolState()
    }

    private func selectProxyJump(_ selection: SSHProxyJumpSelection) {
        switch selection {
        case .disabled:
            proxyJumpModePopup.selectItem(withTitle: L10n.SessionSettings.proxyJumpDisabled)
            proxyJumpSessionIDField.stringValue = ""
            proxyJumpHostField.stringValue = ""
            proxyJumpPortField.stringValue = "22"
            proxyJumpUsernameField.stringValue = ""
            proxyJumpCredentialIDField.stringValue = ""
            proxyJumpPrivateKeyPathField.stringValue = ""
        case let .session(id):
            proxyJumpModePopup.selectItem(withTitle: L10n.SessionSettings.proxyJumpSavedSession)
            proxyJumpSessionIDField.stringValue = id
        case let .manual(config):
            proxyJumpModePopup.selectItem(withTitle: L10n.SessionSettings.proxyJumpManual)
            proxyJumpHostField.stringValue = config.host
            proxyJumpPortField.stringValue = String(config.port)
            proxyJumpUsernameField.stringValue = config.username
            proxyJumpCredentialIDField.stringValue = config.credentialID ?? ""
            proxyJumpPrivateKeyPathField.stringValue = config.privateKeyPath ?? ""
        }
        refreshProxyJumpModeFields()
    }

    private func refreshProxyJumpModeFields() {
        let mode = proxyJumpModePopup.titleOfSelectedItem
        let usesSavedSession = mode == L10n.SessionSettings.proxyJumpSavedSession
        let usesManual = mode == L10n.SessionSettings.proxyJumpManual
        proxyJumpSessionIDField.isEnabled = usesSavedSession
        proxyJumpHostField.isEnabled = usesManual
        proxyJumpPortField.isEnabled = usesManual
        proxyJumpUsernameField.isEnabled = usesManual
        proxyJumpCredentialIDField.isEnabled = usesManual
        proxyJumpPrivateKeyPathField.isEnabled = usesManual
    }

    @objc private func serialProfileChanged(_ sender: NSPopUpButton) {
        applySerialProfile(SerialNetworkDeviceProfile.profile(forTitle: sender.titleOfSelectedItem))
    }

    private func applySerialProfile(_ profile: SerialNetworkDeviceProfile) {
        guard profile.appliesPreset else {
            return
        }
        if let baudRate = profile.baudRate {
            sshForm.setPortValue(String(baudRate))
        }
        configureSerialPopupSelections(
            dataBits: profile.dataBits,
            stopBits: profile.stopBits,
            parity: profile.parityTitle,
            flowControl: profile.flowControlTitle
        )
    }

    private func configureSerialPopup(
        _ popup: NSPopUpButton,
        titles: [String],
        selectedTitle: String,
        width: CGFloat = 140
    ) {
        configurePopup(popup, titles: titles, selectedTitle: selectedTitle, width: width)
    }

    private func configurePopup(
        _ popup: NSPopUpButton,
        titles: [String],
        selectedTitle: String,
        width: CGFloat = 140
    ) {
        popup.addItems(withTitles: titles)
        popup.selectItem(withTitle: selectedTitle)
        popup.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePopupButton(popup)
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func compactAutomationControl(label: String, field: NSView) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.textColor = StacioDesignSystem.theme.secondaryTextColor
        labelView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        labelView.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [labelView, field])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func compactStartupControl(label: String, field: NSView) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.textColor = StacioDesignSystem.theme.secondaryTextColor
        labelView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let stack = NSStackView(views: [labelView, field])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func serialRow(label: String, field: NSView) -> (container: NSView, label: NSTextField) {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.textColor = StacioDesignSystem.theme.secondaryTextColor
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let stack = NSStackView(views: [labelView, field])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        return (stack, labelView)
    }

    var protocolLabelsForTesting: [String] {
        SessionSettingsProtocol.selectableCases.map(\.label)
    }

    var protocolSourceListLabelsForTesting: [String] {
        SessionSettingsProtocol.selectableCases.map(\.sourceListLabel)
    }

    var selectedProtocolForTesting: SessionSettingsProtocol {
        selectedProtocol
    }

    var sshFormIsHiddenForTesting: Bool {
        sshForm.view.isHidden
    }

    var sessionIconRowIsHiddenForTesting: Bool {
        sessionIconView.isHidden
    }

    var selectedSessionIconIDForTesting: String? {
        selectedSessionIconID
    }

    func selectSessionIconForTesting(_ iconID: String?) {
        selectedSessionIconID = SessionIconCatalog.definition(id: iconID)?.id
        updateSessionIconPreview()
    }

    var unsupportedMessageForTesting: String {
        unsupportedLabel.stringValue
    }

    var saveButtonIsEnabledForTesting: Bool {
        saveButton.isEnabled
    }

    var validationMessageForTesting: String {
        sshForm.validationMessageForTesting
    }

    var initialFirstResponderIdentifierForTesting: String? {
        sshForm.initialFirstResponder.accessibilityIdentifier()
    }

    var footerUsesSeparatorForTesting: Bool {
        footerSeparator.boxType == .separator && footerSeparator.superview != nil
    }

    func selectProtocolForTesting(_ sessionProtocol: SessionSettingsProtocol) {
        applySelectedProtocol(sessionProtocol)
    }

    func setSSHValuesForTesting(_ values: SessionSidebarSessionFormValues) {
        sshForm.setValuesForTesting(values)
        refreshProtocolState()
    }

    func setTagColorForTesting(_ hexRGB: String) {
        sshForm.setTagColorForTesting(hexRGB)
        refreshProtocolState()
    }

    func setAutomationPolicyForTesting(environment: String, aiExecutionPolicy: String) {
        selectAutomation(
            environment: environment,
            aiExecutionPolicy: aiExecutionPolicy,
            startupCommand: startupCommandField.stringValue,
            postConnectScript: postConnectScriptTextView.string,
            environmentVariables: normalizedEnvironmentVariables(
                environmentVariablesTextView.string.components(separatedBy: .newlines)
            ),
            connectTimeoutMs: connectTimeoutMsFromSeconds(connectTimeoutSecondsField.stringValue)
        )
        refreshProtocolState()
    }

    func setConnectionStartupForTesting(command: String, environmentVariables: String) {
        startupCommandField.stringValue = command
        environmentVariablesTextView.string = environmentVariables
        refreshProtocolState()
    }

    func setPostConnectScriptForTesting(_ script: String) {
        postConnectScriptTextView.string = script
        refreshProtocolState()
    }

    func setConnectionAdvancedForTesting(
        startupCommand: String,
        environmentVariables: String,
        connectTimeoutSeconds: String
    ) {
        startupCommandField.stringValue = startupCommand
        environmentVariablesTextView.string = environmentVariables
        connectTimeoutSecondsField.stringValue = connectTimeoutSeconds
        refreshProtocolState()
    }

    func setProxyJumpDisabledForTesting() {
        selectProxyJump(.disabled)
        refreshProtocolState()
    }

    func setProxyJumpSavedSessionForTesting(id: String) {
        selectProxyJump(.session(id: id))
        refreshProtocolState()
    }

    func setProxyJumpManualForTesting(
        host: String,
        port: String,
        username: String,
        credentialID: String,
        privateKeyPath: String
    ) {
        proxyJumpModePopup.selectItem(withTitle: L10n.SessionSettings.proxyJumpManual)
        proxyJumpHostField.stringValue = host
        proxyJumpPortField.stringValue = port
        proxyJumpUsernameField.stringValue = username
        proxyJumpCredentialIDField.stringValue = credentialID
        proxyJumpPrivateKeyPathField.stringValue = privateKeyPath
        refreshProxyJumpModeFields()
        refreshProtocolState()
    }

    func bindSaveButtonForTesting(_ button: NSButton) {
        testingSaveButton = button
        refreshProtocolState()
    }

    var portValueForTesting: String {
        sshForm.portValueForTesting
    }

    var hostRowIsHiddenForTesting: Bool {
        sshForm.hostRowIsHiddenForTesting
    }

    var portRowIsHiddenForTesting: Bool {
        sshForm.portRowIsHiddenForTesting
    }

    var hostLabelForTesting: String {
        sshForm.hostLabelForTesting
    }

    var portLabelForTesting: String {
        sshForm.portLabelForTesting
    }

    var userRowIsHiddenForTesting: Bool {
        sshForm.userRowIsHiddenForTesting
    }

    var authRowIsHiddenForTesting: Bool {
        sshForm.authRowIsHiddenForTesting
    }

    var serialAdvancedLabelsForTesting: [String] {
        serialAdvancedLabels.map(\.stringValue)
    }

    var serialAdvancedValuesForTesting: [String: String] {
        [
            L10n.SessionSettings.serialDeviceProfile: serialProfilePopup.titleOfSelectedItem ?? "",
            L10n.SessionSettings.dataBits: serialDataBitsPopup.titleOfSelectedItem ?? "",
            L10n.SessionSettings.stopBits: serialStopBitsPopup.titleOfSelectedItem ?? "",
            L10n.SessionSettings.parity: serialParityPopup.titleOfSelectedItem ?? "",
            L10n.SessionSettings.flowControl: serialFlowControlPopup.titleOfSelectedItem ?? "",
            L10n.SessionSettings.backspaceMode: serialBackspaceModePopup.titleOfSelectedItem ?? ""
        ]
    }

    var serialStorageHintForTesting: String {
        serialStorageHintLabel.stringValue
    }

    var serialAdvancedTextForTesting: String {
        (
            serialAdvancedLabelsForTesting
            + Array(serialAdvancedValuesForTesting.values)
            + [serialStorageHintForTesting]
        ).joined(separator: " ")
    }

    var serialBaudChoicesForTesting: [String] {
        sshForm.portSuggestionsForTesting
    }

    var serialDevicePathChoicesForTesting: [String] {
        sshForm.hostSuggestionsForTesting
    }

    var serialDeviceProfileChoicesForTesting: [String] {
        (0..<serialProfilePopup.numberOfItems).compactMap { serialProfilePopup.item(at: $0)?.title }
    }

    func selectSerialDeviceProfileForTesting(_ title: String) {
        serialProfilePopup.selectItem(withTitle: title)
        applySerialProfile(SerialNetworkDeviceProfile.profile(forTitle: title))
        refreshProtocolState()
    }

    var hostValueForTesting: String {
        sshForm.hostValueForTesting
    }

    var nameValueForTesting: String {
        sshForm.nameValueForTesting
    }

    func selectBaudRateForTesting(_ title: String) {
        sshForm.selectBaudRateForTesting(title)
        refreshProtocolState()
    }

    var automationValuesForTesting: [String: String] {
        [
            L10n.SessionSettings.environment: environmentPopup.titleOfSelectedItem ?? "",
            L10n.SessionSettings.aiExecutionPolicy: aiExecutionPolicyPopup.titleOfSelectedItem ?? ""
        ]
    }

    var connectionStartupValuesForTesting: [String: String] {
        [
            L10n.SessionSettings.startupCommand: startupCommandField.stringValue,
            L10n.SessionSettings.postConnectScript: postConnectScriptTextView.string,
            L10n.SessionSettings.environmentVariables: environmentVariablesTextView.string,
            L10n.SessionSettings.connectTimeoutSeconds: connectTimeoutSecondsField.stringValue
        ]
    }

    var postConnectScriptForTesting: String {
        postConnectScriptTextView.string
    }

    var proxyJumpValuesForTesting: [String: String] {
        [
            L10n.SessionSettings.proxyJumpMode: proxyJumpModePopup.titleOfSelectedItem ?? "",
            L10n.SessionSettings.proxyJumpSessionID: proxyJumpSessionIDField.stringValue,
            L10n.SessionSettings.host: proxyJumpHostField.stringValue,
            L10n.SessionSettings.port: proxyJumpPortField.stringValue,
            L10n.SessionSettings.user: proxyJumpUsernameField.stringValue,
            L10n.SessionSettings.proxyJumpCredentialID: proxyJumpCredentialIDField.stringValue,
            L10n.SessionSettings.privateKey: proxyJumpPrivateKeyPathField.stringValue
        ]
    }

    func setSerialAdvancedValuesForTesting(
        dataBits: String,
        stopBits: String,
        parity: String,
        flowControl: String
    ) {
        configureSerialPopupSelections(
            dataBits: dataBits,
            stopBits: stopBits,
            parity: parity,
            flowControl: flowControl
        )
    }

    private func configureSerialPopupSelections(
        deviceProfile: String? = nil,
        baudRate: UInt32? = nil,
        dataBits: String,
        stopBits: String,
        parity: String,
        flowControl: String,
        backspaceMode: String = L10n.SessionSettings.backspaceDelete
    ) {
        if let deviceProfile {
            serialProfilePopup.selectItem(withTitle: deviceProfile)
        }
        if let baudRate {
            sshForm.setPortValue(baudRate == 0 ? "" : String(baudRate))
        }
        serialDataBitsPopup.selectItem(withTitle: dataBits)
        serialStopBitsPopup.selectItem(withTitle: stopBits)
        serialParityPopup.selectItem(withTitle: parity)
        serialFlowControlPopup.selectItem(withTitle: flowControl)
        serialBackspaceModePopup.selectItem(withTitle: backspaceMode)
    }

    private func selectAutomation(
        environment: String,
        aiExecutionPolicy: String,
        startupCommand: String,
        postConnectScript: String,
        environmentVariables: [String],
        connectTimeoutMs: UInt32?
    ) {
        environmentPopup.selectItem(withTitle: environmentTitle(for: normalizedEnvironment(environment)))
        aiExecutionPolicyPopup.selectItem(withTitle: aiPolicyTitle(for: normalizedAIPolicy(aiExecutionPolicy)))
        startupCommandField.stringValue = normalizedStartupCommand(startupCommand)
        postConnectScriptTextView.string = normalizedPostConnectScript(postConnectScript)
        environmentVariablesTextView.string = normalizedEnvironmentVariables(environmentVariables).joined(separator: "\n")
        connectTimeoutSecondsField.stringValue = secondsString(
            from: connectTimeoutMs ?? SSHConnectionDefaults.fastConnectTimeoutMs
        )
    }

    private func normalizedEnvironment(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "production", "prod":
            return "production"
        case "staging", "stage":
            return "staging"
        default:
            return "development"
        }
    }

    private func normalizedAIPolicy(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "disabled", "deny", "off":
            return "disabled"
        case "commandcard", "command_card", "suggest":
            return "commandCard"
        case "readonlyauto", "read_only_auto", "readonly":
            return "readOnlyAuto"
        case "requireeverycommand", "require_every_command", "confirm":
            return "requireEveryCommand"
        default:
            return "inherit"
        }
    }

    private func normalizedStartupCommand(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizedPostConnectScript(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func optionalProxyJumpValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedEnvironmentVariables(_ values: [String]) -> [String] {
        values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                return nil
            }
            return trimmed
        }
    }

    private func connectTimeoutMsFromSeconds(_ value: String) -> UInt32? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let seconds = UInt32(trimmed)
        else {
            return SSHConnectionDefaults.fastConnectTimeoutMs
        }
        return normalizedConnectTimeoutMs(seconds.saturatingMilliseconds)
    }

    private func normalizedConnectTimeoutMs(_ value: UInt32?) -> UInt32? {
        SSHConnectionDefaults.normalizedConnectTimeoutMs(value)
    }

    private func secondsString(from milliseconds: UInt32) -> String {
        String(max(1, milliseconds / 1_000))
    }

    private func environmentTitle(for value: String) -> String {
        switch value {
        case "production":
            return L10n.SessionSettings.environmentProduction
        case "staging":
            return L10n.SessionSettings.environmentStaging
        default:
            return L10n.SessionSettings.environmentDevelopment
        }
    }

    private func environmentRawValue(for title: String?) -> String {
        switch title {
        case L10n.SessionSettings.environmentProduction:
            return "production"
        case L10n.SessionSettings.environmentStaging:
            return "staging"
        default:
            return "development"
        }
    }

    private func aiPolicyTitle(for value: String) -> String {
        switch value {
        case "disabled":
            return L10n.SessionSettings.aiPolicyDisabled
        case "commandCard":
            return L10n.SessionSettings.aiPolicyCommandCard
        case "readOnlyAuto":
            return L10n.SessionSettings.aiPolicyReadOnlyAuto
        case "requireEveryCommand":
            return L10n.SessionSettings.aiPolicyRequireEveryCommand
        default:
            return L10n.SessionSettings.aiPolicyInherit
        }
    }

    private func aiPolicyRawValue(for title: String?) -> String {
        switch title {
        case L10n.SessionSettings.aiPolicyDisabled:
            return "disabled"
        case L10n.SessionSettings.aiPolicyCommandCard:
            return "commandCard"
        case L10n.SessionSettings.aiPolicyReadOnlyAuto:
            return "readOnlyAuto"
        case L10n.SessionSettings.aiPolicyRequireEveryCommand:
            return "requireEveryCommand"
        default:
            return "inherit"
        }
    }
}

@MainActor
final class SessionSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settingsViewController: SessionSettingsViewController
    private var result: SessionDraft?

    init(
        existingSession: SessionRecord?,
        selectedFolderID: String?,
        draftFactory: SessionSidebarSessionDraftFactory,
        errorPresenter: SessionSidebarErrorPresenting,
        existingSerialConfigJSON: String? = nil,
        parentWindowProvider: @escaping () -> NSWindow?
    ) {
        settingsViewController = SessionSettingsViewController(
            existingSession: existingSession,
            selectedFolderID: selectedFolderID,
            draftFactory: draftFactory,
            existingSerialConfigJSON: existingSerialConfigJSON
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 704, height: 526),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = existingSession == nil ? L10n.SessionSettings.newSession : L10n.SessionSettings.editSession
        window.appearance = nil
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = false
        window.contentViewController = settingsViewController
        settingsViewController.installInitialFirstResponder(in: window)
        super.init(window: window)
        window.delegate = self

        settingsViewController.onSave = { [weak self] draft in
            self?.result = draft
            NSApplication.shared.stopModal(withCode: .OK)
        }
        settingsViewController.onCancel = {
            NSApplication.shared.stopModal(withCode: .cancel)
        }
        settingsViewController.onError = { error in
            errorPresenter.present(error, context: .sessionEditor, parentWindow: parentWindowProvider())
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func runModal(parentWindow: NSWindow?) -> SessionDraft? {
        guard let window else {
            return nil
        }

        if let parentWindow {
            parentWindow.beginSheet(window)
            let response = NSApplication.shared.runModal(for: window)
            parentWindow.endSheet(window)
            window.orderOut(nil)
            return response == .OK ? result : nil
        }

        window.center()
        let response = NSApplication.shared.runModal(for: window)
        window.close()
        return response == .OK ? result : nil
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.stopModal(withCode: .cancel)
    }
}

private extension UInt32 {
    var saturatingMilliseconds: UInt32 {
        let (value, overflow) = multipliedReportingOverflow(by: 1_000)
        return overflow ? UInt32.max : value
    }
}
