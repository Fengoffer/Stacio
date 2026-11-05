import AppKit

// MARK: - RDP 设置表单
// 独立的 RDP 配置 ViewController，不修改 SessionSettingsViewController.swift（Codex 正在修改）。
// 在 GraphicsRuntimeManager 处理 connectionKind == .rdp 时加载此表单收集 RDP 专属参数。

public struct RDPSessionFormPrefill: Equatable {
    public let user: String
    public let domain: String?
    public let security: RDPSecurityType
    public let ignoreCert: Bool

    public init(
        user: String = "",
        domain: String? = nil,
        security: RDPSecurityType = .nla,
        ignoreCert: Bool = false
    ) {
        self.user = user
        let trimmedDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.domain = trimmedDomain?.isEmpty == false ? trimmedDomain : nil
        self.security = RDPSecurityType.supportedConnectionTypes.contains(security) ? security : .nla
        self.ignoreCert = ignoreCert
    }

    public init(user: String, configJSON: String?) {
        guard let configJSON,
              let data = configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            self.init(user: user)
            return
        }

        let domain = object["rdpDomain"] as? String
        let rawSecurity = (object["rdpSecurity"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let decodedSecurity = rawSecurity.flatMap(RDPSecurityType.init(rawValue:)) ?? .nla
        self.init(
            user: user,
            domain: domain,
            security: decodedSecurity,
            ignoreCert: object["rdpIgnoreCert"] as? Bool ?? false
        )
    }
}

public struct RDPSessionFormResult: Equatable {
    public let user: String
    public let password: String
    public let domain: String?
    public let security: RDPSecurityType
    public let ignoreCert: Bool
    public let width: Int
    public let height: Int
    public let quality: Int
    public let drive: String?

    public init(
        user: String,
        password: String,
        domain: String?,
        security: RDPSecurityType,
        ignoreCert: Bool,
        width: Int,
        height: Int,
        quality: Int,
        drive: String? = nil
    ) {
        self.user = user
        self.password = password
        self.domain = domain
        self.security = security
        self.ignoreCert = ignoreCert
        self.width = width
        self.height = height
        self.quality = quality
        self.drive = drive
    }

    /// 转换为 EmbeddedRDPSessionOptions，需要外部提供 host 和 port。
    public func makeOptions(host: String, port: UInt16) -> EmbeddedRDPSessionOptions {
        EmbeddedRDPSessionOptions(
            host: host,
            port: port,
            user: user,
            password: password,
            domain: domain,
            width: width,
            height: height,
            quality: quality,
            ignoreCert: ignoreCert,
            security: security,
            drive: drive
        )
    }

    /// 转换为 GraphicsRuntimeStartRequest 的 arguments 数组。
    public func makeAdapterArguments() -> [String] {
        var args: [String] = [
            "--user", user,
            "--password", password,
            "--width", String(width),
            "--height", String(height),
            "--quality", String(quality),
            "--security", security.rawValue
        ]
        if let domain, !domain.isEmpty {
            args.append(contentsOf: ["--domain", domain])
        }
        if ignoreCert {
            args.append("--ignore-cert")
        }
        if let drive = drive?.trimmingCharacters(in: .whitespacesAndNewlines), !drive.isEmpty {
            args.append(contentsOf: ["--drive", drive])
        }
        return args
    }
}

public final class RDPSessionFormViewController: NSViewController {
    private static let supportedSecurityTypes = RDPSecurityType.supportedConnectionTypes
    private let completionHandler: (RDPSessionFormResult?) -> Void
    private let prefill: RDPSessionFormPrefill
    private let usbDeviceEnumerator: any RDPUSBDeviceEnumerating

    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let domainField = NSTextField()
    private let securityPopup = NSPopUpButton()
    private let ignoreCertSwitch = NSSwitch()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let qualityPopup = NSPopUpButton()
    private let driveNameField = NSTextField()
    private let drivePathField = NSTextField()
    private let chooseDrivePathButton = NSButton(title: "选择…", target: nil, action: nil)
    private let connectButton = NSButton(title: "连接", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    /// 只预填用户名的兼容入口。
    public convenience init(
        prefillUser: String = "",
        completionHandler: @escaping (RDPSessionFormResult?) -> Void
    ) {
        self.init(
            prefill: RDPSessionFormPrefill(user: prefillUser),
            usbDeviceEnumerator: IOKitRDPUSBDeviceEnumerator(),
            completionHandler: completionHandler
        )
    }

    public convenience init(
        prefill: RDPSessionFormPrefill,
        completionHandler: @escaping (RDPSessionFormResult?) -> Void
    ) {
        self.init(
            prefill: prefill,
            usbDeviceEnumerator: IOKitRDPUSBDeviceEnumerator(),
            completionHandler: completionHandler
        )
    }

    init(
        prefill: RDPSessionFormPrefill,
        usbDeviceEnumerator: any RDPUSBDeviceEnumerating,
        completionHandler: @escaping (RDPSessionFormResult?) -> Void
    ) {
        self.prefill = prefill
        self.usbDeviceEnumerator = usbDeviceEnumerator
        self.completionHandler = completionHandler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(container)
        view = container

        configureControls()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let formStack = createFormStack()
        documentView.addSubview(formStack)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            formStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            formStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            formStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            formStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        validateAndUpdateConnectButton()
    }

    // MARK: - 控件配置

    private func configureControls() {
        userField.placeholderString = "Administrator"
        userField.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.user")
        userField.target = self
        userField.action = #selector(textFieldChanged)
        userField.isContinuous = true
        userField.translatesAutoresizingMaskIntoConstraints = false

        passwordField.placeholderString = "必填"
        passwordField.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.password")
        passwordField.target = self
        passwordField.action = #selector(textFieldChanged)
        passwordField.isContinuous = true
        passwordField.translatesAutoresizingMaskIntoConstraints = false

        domainField.placeholderString = "可选，如 CORP"
        domainField.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.domain")
        domainField.translatesAutoresizingMaskIntoConstraints = false

        securityPopup.addItems(withTitles: Self.supportedSecurityTypes.map { $0.displayName })
        securityPopup.selectItem(at: 0)
        securityPopup.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.security")
        securityPopup.translatesAutoresizingMaskIntoConstraints = false

        ignoreCertSwitch.target = self
        ignoreCertSwitch.action = #selector(ignoreCertToggled)
        ignoreCertSwitch.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.ignoreCert")
        ignoreCertSwitch.translatesAutoresizingMaskIntoConstraints = false

        widthField.stringValue = "1280"
        widthField.translatesAutoresizingMaskIntoConstraints = false

        heightField.stringValue = "800"
        heightField.translatesAutoresizingMaskIntoConstraints = false

        let qualityOptions = ["1 - 最低", "2", "3", "4", "5 - 弱网", "6", "7 - 默认", "8", "9", "10 - 最高"]
        qualityPopup.addItems(withTitles: qualityOptions)
        qualityPopup.selectItem(at: 6)
        qualityPopup.translatesAutoresizingMaskIntoConstraints = false

        driveNameField.placeholderString = "可选，如 Shared"
        driveNameField.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.driveName")
        driveNameField.target = self
        driveNameField.action = #selector(textFieldChanged)
        driveNameField.isContinuous = true
        driveNameField.translatesAutoresizingMaskIntoConstraints = false

        drivePathField.placeholderString = "可选，本地目录"
        drivePathField.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.drivePath")
        drivePathField.target = self
        drivePathField.action = #selector(textFieldChanged)
        drivePathField.isContinuous = true
        drivePathField.translatesAutoresizingMaskIntoConstraints = false
        drivePathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        chooseDrivePathButton.target = self
        chooseDrivePathButton.action = #selector(chooseDrivePath)
        chooseDrivePathButton.bezelStyle = .rounded
        chooseDrivePathButton.translatesAutoresizingMaskIntoConstraints = false

        connectButton.target = self
        connectButton.action = #selector(connectPressed)
        connectButton.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.connect")
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePrimaryButton(connectButton)

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        applyPrefill()
    }

    private func applyPrefill() {
        userField.stringValue = prefill.user
        domainField.stringValue = prefill.domain ?? ""
        if let index = Self.supportedSecurityTypes.firstIndex(of: prefill.security) {
            securityPopup.selectItem(at: index)
        } else {
            securityPopup.selectItem(at: 0)
        }
        ignoreCertSwitch.state = prefill.ignoreCert ? .on : .off
    }

    // MARK: - 表单布局

    private func createFormStack() -> NSView {
        let titleLabel = NSTextField(labelWithString: "RDP 远程桌面连接")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let drivePathRow = NSStackView(views: [drivePathField, chooseDrivePathButton])
        drivePathRow.orientation = .horizontal
        drivePathRow.alignment = .centerY
        drivePathRow.spacing = 8
        drivePathRow.translatesAutoresizingMaskIntoConstraints = false

        let rows: [(String, NSView)] = [
            ("用户名", userField),
            ("密码", passwordField),
            ("域", domainField),
            ("安全类型", securityPopup),
            ("忽略证书", ignoreCertSwitch),
            ("宽度", widthField),
            ("高度", heightField),
            ("画质", qualityPopup),
            ("共享名称", driveNameField),
            ("共享目录", drivePathRow)
        ]

        let rowStacks = rows.map { makeRow(label: $0.0, control: $0.1) }
        let usbCapabilityView = RDPUSBRedirectCapabilityView(
            devices: usbDeviceEnumerator.enumerateDevices()
        )
        let buttonRow = NSStackView(views: [cancelButton, connectButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel] + rowStacks + [usbCapabilityView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        usbCapabilityView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeRow(label: String, control: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        labelField.textColor = StacioDesignSystem.theme.secondaryTextColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        if let textField = control as? NSTextField, textField !== ignoreCertSwitch {
            textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        }

        let row = NSStackView(views: [labelField, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - 按钮状态

    private func validateAndUpdateConnectButton() {
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        let driveName = driveNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let drivePath = drivePathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let drivePairIsComplete = driveName.isEmpty == drivePath.isEmpty
        connectButton.isEnabled = !user.isEmpty && !password.isEmpty && drivePairIsComplete
    }

    // MARK: - 动作

    @objc private func textFieldChanged() {
        validateAndUpdateConnectButton()
    }

    @objc private func ignoreCertToggled() {
        // 状态已自动更新，无需额外处理
    }

    @objc private func chooseDrivePath() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            self?.drivePathField.stringValue = directory.path
            if self?.driveNameField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            {
                self?.driveNameField.stringValue = "Shared"
            }
            self?.validateAndUpdateConnectButton()
        }
    }

    @objc private func connectPressed() {
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        guard !user.isEmpty, !password.isEmpty else { return }

        let domain = domainField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let securityIndex = securityPopup.indexOfSelectedItem
        guard Self.supportedSecurityTypes.indices.contains(securityIndex) else { return }
        let security = Self.supportedSecurityTypes[securityIndex]
        let width = Int(widthField.stringValue) ?? 1280
        let height = Int(heightField.stringValue) ?? 800
        let quality = max(1, min(10, qualityPopup.indexOfSelectedItem + 1))
        let driveName = driveNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDrivePath = drivePathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard driveName.isEmpty == rawDrivePath.isEmpty else { return }
        let drive = driveName.isEmpty
            ? nil
            : "\(driveName):\((rawDrivePath as NSString).expandingTildeInPath)"

        let result = RDPSessionFormResult(
            user: user,
            password: password,
            domain: domain.isEmpty ? nil : domain,
            security: security,
            ignoreCert: ignoreCertSwitch.state == .on,
            width: width,
            height: height,
            quality: quality,
            drive: drive
        )
        completionHandler(result)
    }

    @objc private func cancelPressed() {
        completionHandler(nil)
    }
}

// MARK: - Sheet 弹出辅助

public extension RDPSessionFormViewController {
    /// 以 sheet 方式弹出表单。completionHandler 在主线程回调。
    @MainActor
    static func present(
        on window: NSWindow,
        prefill: RDPSessionFormPrefill,
        completionHandler: @escaping (RDPSessionFormResult?) -> Void
    ) {
        var completed = false
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "RDP 远程桌面"
        sheet.isReleasedWhenClosed = false
        sheet.center()

        let controller = RDPSessionFormViewController(
            prefill: prefill
        ) { result in
            guard !completed else { return }
            completed = true
            window.endSheet(sheet)
            completionHandler(result)
        }
        sheet.contentView = controller.view

        window.beginSheet(sheet) { _ in
            if !completed {
                completed = true
                completionHandler(nil)
            }
        }
    }

    /// 只预填用户名的兼容入口。
    @MainActor
    static func present(
        on window: NSWindow,
        prefillUser: String = "",
        completionHandler: @escaping (RDPSessionFormResult?) -> Void
    ) {
        present(
            on: window,
            prefill: RDPSessionFormPrefill(user: prefillUser),
            completionHandler: completionHandler
        )
    }
}
