import AppKit

public enum WorkspaceSessionGroupCloseDecision: Equatable {
    case save(name: String)
    case discard
    case cancel
}

@MainActor
public protocol WorkspaceSessionGroupClosePresenting: AnyObject {
    func decisionForClosingGroup(
        definition: WorkspaceSessionGroupDefinition,
        suggestedName: String,
        parentWindow: NSWindow?
    ) -> WorkspaceSessionGroupCloseDecision
}

@MainActor
public final class AppKitWorkspaceSessionGroupClosePresenter: WorkspaceSessionGroupClosePresenting {
    public init() {}

    public func decisionForClosingGroup(
        definition: WorkspaceSessionGroupDefinition,
        suggestedName: String,
        parentWindow: NSWindow?
    ) -> WorkspaceSessionGroupCloseDecision {
        let nameField = NSTextField(string: suggestedName)
        nameField.placeholderString = suggestedName
        nameField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "是否保存\(definition.displayName)？"
        alert.informativeText = "保存后可从会话列表一次恢复当前的 \(definition.paneCountDescription)和布局。"
        alert.accessoryView = nameField
        alert.addButton(withTitle: "保存并关闭")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        _ = parentWindow

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .save(name: name.isEmpty ? suggestedName : name)
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }
}
