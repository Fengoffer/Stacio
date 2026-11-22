import AppKit

@MainActor
final class AgentFullAccessSheet: NSPanel {
 static let contentWidth: CGFloat = 416

 init() {
 super.init(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 300),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
 title = "启用完全权限？"
 titleVisibility = .hidden
 titlebarAppearsTransparent = true
 isReleasedWhenClosed = false

 let icon = NSImageView(image: AgentPermissionMode.dangerFullAccess.permissionIcon(size: 48, tint: .systemRed) ?? NSImage())
 icon.setAccessibilityElement(false)
 let heading = NSTextField(labelWithString: title)
 heading.font = .systemFont(ofSize: 16, weight: .semibold)
 heading.alignment = .center
 let detail = NSTextField(wrappingLabelWithString: """
 启用后，Stacio Agent 可使用当前终端账号的权限，在本机或所选的 SSH 主机上自动执行命令。常用查询、软件包安装和服务管理可直接执行，可能修改文件或中断服务。

 灾难性命令、无法判断风险的命令，以及生产环境或目标策略要求审批的命令，仍需你手动批准。

 此设置仅对当前 AI 对话生效。你可以切回「请求批准」，已执行的操作不会撤销。
 """)
 let margin: CGFloat = 24
 let textWidth = Self.contentWidth - 2 * margin
 detail.preferredMaxLayoutWidth = textWidth

 let cancel = NSButton(title: "取消", target: self, action: #selector(dismissSheet))
 cancel.bezelStyle = .rounded
 cancel.keyEquivalent = "\u{1B}"
 let enable = AgentFilledActionButton(title: "启用完全权限", color: .systemRed, target: self, action: #selector(confirmSheet))
 enable.hasDestructiveAction = true
 let buttons = NSStackView(views: [cancel, enable])
 buttons.spacing = 10
 buttons.distribution = .fillEqually
 buttons.orientation = .horizontal

 let stack = NSStackView(views: [icon, heading, detail, buttons])
 stack.orientation = .vertical
 stack.alignment = .centerX
 stack.spacing = 12
 stack.edgeInsets = NSEdgeInsets(top: 24, left: margin, bottom: 20, right: margin)
 NSLayoutConstraint.activate([
 icon.widthAnchor.constraint(equalToConstant: 48),
 icon.heightAnchor.constraint(equalToConstant: 48),
 detail.widthAnchor.constraint(equalToConstant: textWidth),
 buttons.widthAnchor.constraint(equalToConstant: textWidth)
 ])
 setContentSize(NSSize(width: Self.contentWidth, height: stack.fittingSize.height))
 contentView = stack
 initialFirstResponder = cancel
 }

 @objc private func dismissSheet() { sheetParent?.endSheet(self, returnCode: .cancel) }
 @objc private func confirmSheet() { sheetParent?.endSheet(self, returnCode: .OK) }
}

@MainActor
final class AgentFilledActionButton: NSButton {
 private let fillColor: NSColor

 init(title: String, color: NSColor, target: AnyObject, action: Selector) {
     fillColor = color
     super.init(frame: .zero)
     self.target = target
     self.action = action
     isBordered = false
     setButtonType(.momentaryPushIn)
     attributedTitle = NSAttributedString(string: title, attributes: [
         .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
         .foregroundColor: NSColor.white
     ])
 }

 required init?(coder: NSCoder) { return nil }

 override var intrinsicContentSize: NSSize {
     NSSize(width: ceil(attributedTitle.size().width) + 24, height: 24)
 }

 override var isHighlighted: Bool { didSet { needsDisplay = true } }

 override func draw(_ dirtyRect: NSRect) {
     let fill = isHighlighted ? fillColor.blended(withFraction: 0.15, of: .black) ?? fillColor : fillColor
     fill.setFill()
     NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
     super.draw(dirtyRect)
 }
}
