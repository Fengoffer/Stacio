import AppKit

/// An in-panel rendering of the model or permission menu, used only so the menu
/// state can be screenshotted.
///
/// The real UI uses a native `NSMenu`, which lives in its own window and cannot
/// be captured offscreen. This mirrors the same items, checkmarks, disabled rows
/// and separator so the comparison image shows what the menu contains. It is a
/// comparison aid, not the production control.
@MainActor
public final class AgentMenuPreviewView: NSView {
 public struct Item {
 public let title: String
 public let checked: Bool
 public let disabled: Bool
 public var isSeparator: Bool { title == "-" }

 public init(title: String, checked: Bool, disabled: Bool) {
 self.title = title
 self.checked = checked
 self.disabled = disabled
 }
 }

 private let stack = NSStackView()

 public init(items: [Item], width: CGFloat) {
 super.init(frame: .zero)
 translatesAutoresizingMaskIntoConstraints = false
 wantsLayer = true
 layer?.backgroundColor = AgentTheme.Color.cardOuter.cgColor
 layer?.cornerRadius = AgentTheme.Metric.radiusCard
 layer?.borderWidth = 1
 layer?.borderColor = AgentTheme.Color.borderCard.cgColor

 stack.translatesAutoresizingMaskIntoConstraints = false
 stack.orientation = .vertical
 stack.alignment = .leading
 stack.spacing = 2
 addSubview(stack)

 NSLayoutConstraint.activate([
 stack.topAnchor.constraint(equalTo: topAnchor, constant:6),
 stack.leadingAnchor.constraint(equalTo: leadingAnchor),
 stack.trailingAnchor.constraint(equalTo: trailingAnchor),
 stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
 widthAnchor.constraint(equalToConstant: width)
 ])

 for item in items {
 if item.isSeparator {
 let divider = NSBox()
 divider.translatesAutoresizingMaskIntoConstraints = false
 divider.boxType = .separator
 stack.addArrangedSubview(divider)
 divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
 continue
 }
 let mark = NSTextField(labelWithString: item.checked ? "\u{2713}" : " ")
 mark.translatesAutoresizingMaskIntoConstraints = false
 mark.font = AgentTheme.Font.body
 mark.textColor = AgentTheme.Color.textSecondary

 let row = NSTextField(labelWithString: item.title)
 row.translatesAutoresizingMaskIntoConstraints = false
 row.font = AgentTheme.Font.body
 row.textColor = item.disabled ? AgentTheme.Color.textTertiary : AgentTheme.Color.text
 row.lineBreakMode = .byTruncatingTail

 let line = NSStackView(views: [mark, row])
 line.translatesAutoresizingMaskIntoConstraints = false
 line.orientation = .horizontal
 line.spacing = 6
 line.edgeInsets = NSEdgeInsets(top:2, left:12, bottom:2, right:12)
 stack.addArrangedSubview(line)
 line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
 mark.widthAnchor.constraint(equalToConstant:12).isActive = true
 }
 }

 required init?(coder: NSCoder) { return nil }
}

extension AgentMenuPreviewView {
 /// The rows the real menu would show for a given state.
 public static func previewItems(
 for state: String,
 selectedPermissionLabel: String = "请求批准"
 ) -> [Item] {
 if state == "permission-menu" {
 // Reflect the live mode rather than assuming which row is checked.
 let rows = AgentPermissionMode.allCases.map { mode in
 Item(title: mode.label, checked: mode.label ==  selectedPermissionLabel, disabled: false)
 }
 return [Item(title: "工具权限模式", checked: false, disabled: true)] + rows
 }
 // model-menu: nothing configured in a fresh build, so the real menu shows a
 // single disabled row; the "add" entry follows a separator.
 return [
 Item(title: "尚未配置模型", checked: false, disabled: true),
 Item(title: "-", checked: false, disabled: false),
 Item(title: "添加模型", checked: false, disabled: false)
 ]
 }
}
