import AppKit

final class RDPUSBRedirectCapabilityView: NSView {
    static let unsupportedMessage = "当前内置 IronRDP 引擎尚未实现通用 USB（URBDRC）重定向。设备开关已禁用，不会触发虚假的“应用并重连”。"

    init(devices: [RDPUSBDeviceInfo]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("Stacio.RDP.usbCapability")
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = StacioDesignSystem.theme.separatorColor.cgColor

        let title = NSTextField(labelWithString: "USB 设备（当前不可重定向）")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor

        let explanation = wrappingLabel(Self.unsupportedMessage)
        explanation.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.usbUnsupported")

        let deviceViews: [NSView]
        if devices.isEmpty {
            let empty = wrappingLabel("未检测到可枚举的本地 USB 设备。")
            empty.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.usbEmpty")
            deviceViews = [empty]
        } else {
            deviceViews = devices.map { device in
                let checkbox = NSButton(
                    checkboxWithTitle: "\(device.productName) [\(device.category.displayName)] · \(device.vendorProductDescription)",
                    target: nil,
                    action: nil
                )
                checkbox.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.usbDevice.\(device.identifier)")
                checkbox.state = .off
                checkbox.isEnabled = false
                checkbox.lineBreakMode = .byTruncatingTail
                checkbox.toolTip = "当前 RDP 引擎不支持 USB 直通"
                return checkbox
            }
        }

        let alternative = wrappingLabel("USB 存储内容可在上方选择“共享目录”映射；HID、打印机、智能卡和加密狗暂不能直通。")
        alternative.identifier = NSUserInterfaceItemIdentifier("Stacio.RDP.usbAlternative")

        let stack = NSStackView(views: [title, explanation] + deviceViews + [alternative])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 450),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            alternative.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }
}
