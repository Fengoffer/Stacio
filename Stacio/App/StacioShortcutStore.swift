import AppKit

public enum StacioShortcutAction: String, CaseIterable, Codable, Sendable {
    case newSession
    case newLocalTerminal
    case closeTerminal
    case settings
    case quit
    case find
    case multiExec
    case toggleSidebar
    case splitSingle
    case splitVertical
    case splitHorizontal
    case splitGrid
    case showFiles
    case showBrowser
    case showTunnels
    case showDiagnostics
    case showMacros
    case showCommandHistory
    case toggleDeviceDashboard
    case showAIAssistant

    public var title: String {
        switch self {
        case .newSession: return L10n.Menu.newSession
        case .newLocalTerminal: return L10n.Menu.newLocalTerminal
        case .closeTerminal: return L10n.Menu.closeCurrentTerminal
        case .settings: return L10n.Menu.settings
        case .quit: return L10n.Menu.quit
        case .find: return L10n.Menu.find
        case .multiExec: return L10n.Menu.multiExec
        case .toggleSidebar: return L10n.Menu.toggleSidebar
        case .splitSingle: return L10n.Workbench.splitSingleTerminal
        case .splitVertical: return L10n.Workbench.splitVertical
        case .splitHorizontal: return L10n.Workbench.splitHorizontal
        case .splitGrid: return L10n.Workbench.splitGrid
        case .showFiles: return L10n.Inspector.files
        case .showBrowser: return L10n.Inspector.browser
        case .showTunnels: return L10n.Workbench.tunnels
        case .showDiagnostics: return L10n.Inspector.logs
        case .showMacros: return L10n.Inspector.macros
        case .showCommandHistory: return L10n.Inspector.commandHistory
        case .toggleDeviceDashboard: return L10n.Menu.toggleDeviceDashboard
        case .showAIAssistant: return L10n.AI.assistant
        }
    }

    public var detail: String {
        switch self {
        case .newSession: return "打开新建会话窗口"
        case .newLocalTerminal: return "打开本地终端"
        case .closeTerminal: return "关闭当前终端"
        case .settings: return "打开设置"
        case .quit: return "退出 Stacio"
        case .find: return "在当前终端中查找"
        case .multiExec: return "向多个终端发送命令"
        case .toggleSidebar: return "显示或隐藏会话侧边栏"
        case .splitSingle: return "切换到单终端布局"
        case .splitVertical: return "切换到垂直分屏布局"
        case .splitHorizontal: return "切换到水平分屏布局"
        case .splitGrid: return "切换到网格分屏布局"
        case .showFiles: return "打开文件面板"
        case .showBrowser: return "打开浏览器面板"
        case .showTunnels: return "打开隧道面板"
        case .showDiagnostics: return "打开诊断面板"
        case .showMacros: return "打开终端宏面板"
        case .showCommandHistory: return "打开命令历史面板"
        case .toggleDeviceDashboard: return "显示或隐藏设备看板"
        case .showAIAssistant: return "打开 AI 助手"
        }
    }
}

public struct StacioShortcutBinding: Codable, Equatable, Sendable {
    public var key: String
    public var modifierRawValue: UInt

    public init(key: String, modifiers: NSEvent.ModifierFlags = [.command]) {
        self.key = key.lowercased()
        self.modifierRawValue = modifiers.intersection([.command, .option, .control, .shift]).rawValue
    }

    public var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
    }

    public var displayString: String {
        let flags = modifiers
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        let keyLabel: String
        switch key {
        case " ", "space": keyLabel = "空格"
        case "return": keyLabel = "↩"
        case "tab": keyLabel = "⇥"
        case "escape": keyLabel = "⎋"
        case "delete": keyLabel = "⌫"
        case "forwarddelete": keyLabel = "⌦"
        case "left": keyLabel = "←"
        case "right": keyLabel = "→"
        case "up": keyLabel = "↑"
        case "down": keyLabel = "↓"
        case "home": keyLabel = "↖"
        case "end": keyLabel = "↘"
        case "pageup": keyLabel = "⇞"
        case "pagedown": keyLabel = "⇟"
        default: keyLabel = key.uppercased()
        }
        return result + keyLabel
    }

    /// `NSMenuItem` expects control characters for non-printing keys instead
    /// of the recorder's readable names.
    public var menuKeyEquivalent: String {
        switch key {
        case "return": return "\r"
        case "tab": return "\t"
        case "escape": return "\u{1b}"
        case "delete": return "\u{8}"
        case "forwarddelete": return "\u{7f}"
        case "space": return " "
        case "left": return String(UnicodeScalar(0xF702)!)
        case "right": return String(UnicodeScalar(0xF703)!)
        case "up": return String(UnicodeScalar(0xF700)!)
        case "down": return String(UnicodeScalar(0xF701)!)
        case "home": return String(UnicodeScalar(0xF729)!)
        case "end": return String(UnicodeScalar(0xF72B)!)
        case "pageup": return String(UnicodeScalar(0xF72C)!)
        case "pagedown": return String(UnicodeScalar(0xF72D)!)
        case "f1": return String(UnicodeScalar(0xF704)!)
        case "f2": return String(UnicodeScalar(0xF705)!)
        case "f3": return String(UnicodeScalar(0xF706)!)
        case "f4": return String(UnicodeScalar(0xF707)!)
        case "f5": return String(UnicodeScalar(0xF708)!)
        case "f6": return String(UnicodeScalar(0xF709)!)
        case "f7": return String(UnicodeScalar(0xF70A)!)
        case "f8": return String(UnicodeScalar(0xF70B)!)
        case "f9": return String(UnicodeScalar(0xF70C)!)
        case "f10": return String(UnicodeScalar(0xF70D)!)
        case "f11": return String(UnicodeScalar(0xF70E)!)
        case "f12": return String(UnicodeScalar(0xF70F)!)
        default: return key
        }
    }
}

public enum StacioShortcutConflict: Equatable, Sendable {
    case none
    case duplicate(String)
    case systemReserved(String)

    public var message: String? {
        switch self {
        case .none: return nil
        case .duplicate(let title): return "与“\(title)”冲突"
        case .systemReserved(let title): return "系统保留快捷键：\(title)"
        }
    }
}

@MainActor
public final class StacioShortcutStore {
    public static let shared = StacioShortcutStore(
        defaults: UserDefaults(suiteName: "com.stacio.Stacio.shortcuts") ?? .standard
    )
    public static let didChangeNotification = Notification.Name("StacioShortcutStore.didChange")

    private let defaults: UserDefaults
    private let defaultsKey = "stacio.shortcuts.v1"
    private var values: [StacioShortcutAction: StacioShortcutBinding]

    @MainActor
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let builtIns: [StacioShortcutAction: StacioShortcutBinding] = [
            .newSession: .init(key: "n", modifiers: [.command, .shift]),
            .newLocalTerminal: .init(key: "n"),
            .closeTerminal: .init(key: "w"),
            .settings: .init(key: ","),
            .quit: .init(key: "q"),
            .find: .init(key: "f"),
            .multiExec: .init(key: "d"),
            .toggleSidebar: .init(key: "b", modifiers: [.command, .option]),
            .splitSingle: .init(key: "1"),
            .splitVertical: .init(key: "2"),
            .splitHorizontal: .init(key: "3"),
            .splitGrid: .init(key: "4"),
            .showFiles: .init(key: "f", modifiers: [.command, .shift]),
            .showBrowser: .init(key: "b", modifiers: [.command, .shift]),
            .showTunnels: .init(key: "t", modifiers: [.command, .shift]),
            .showDiagnostics: .init(key: "l", modifiers: [.command, .shift]),
            .showMacros: .init(key: "m", modifiers: [.command, .shift]),
            .showCommandHistory: .init(key: "h", modifiers: [.command, .shift]),
            .toggleDeviceDashboard: .init(key: "d", modifiers: [.command, .shift]),
            .showAIAssistant: .init(key: "a", modifiers: [.command, .shift])
        ]
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: StacioShortcutBinding].self, from: data) {
            var merged = builtIns
            for (raw, binding) in decoded {
                if let action = StacioShortcutAction(rawValue: raw) { merged[action] = binding }
            }
            values = merged
        } else {
            values = builtIns
        }
    }

    public func binding(for action: StacioShortcutAction) -> StacioShortcutBinding {
        values[action] ?? StacioShortcutBinding(key: "")
    }

    public func conflict(for proposed: StacioShortcutBinding, excluding action: StacioShortcutAction? = nil) -> StacioShortcutConflict {
        guard proposed.key.isEmpty == false else { return .none }
        if let duplicate = StacioShortcutAction.allCases.first(where: {
            $0 != action && values[$0] == proposed
        }) {
            return .duplicate(duplicate.title)
        }
        let normalized = proposed.key.lowercased()
        let modifiers = proposed.modifiers
        let systemShortcuts: [(String, StacioShortcutBinding)] = [
            ("聚焦 Spotlight", .init(key: " ", modifiers: [.command])),
            ("切换应用", .init(key: "tab", modifiers: [.command])),
            ("强制退出", .init(key: "escape", modifiers: [.command, .option])),
            ("隐藏应用", .init(key: "h", modifiers: [.command])),
            ("最小化窗口", .init(key: "m", modifiers: [.command])),
            ("截取屏幕", .init(key: "3", modifiers: [.command, .shift])),
            ("截取窗口", .init(key: "4", modifiers: [.command, .shift])),
            ("截取屏幕区域", .init(key: "5", modifiers: [.command, .shift])),
            ("切换窗口", .init(key: "`", modifiers: [.command])),
            ("切换空间", .init(key: "left", modifiers: [.command, .control]))
        ]
        if let reserved = systemShortcuts.first(where: {
            $0.1.key == normalized && $0.1.modifiers == modifiers
        }) {
            return .systemReserved(reserved.0)
        }
        return .none
    }

    @discardableResult
    public func set(_ binding: StacioShortcutBinding, for action: StacioShortcutAction) -> StacioShortcutConflict {
        let result = conflict(for: binding, excluding: action)
        guard result == .none else { return result }
        values[action] = binding
        persist()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return .none
    }

    public func reset(_ action: StacioShortcutAction) {
        let defaultsStore = StacioShortcutStore(defaults: UserDefaults())
        _ = set(defaultsStore.binding(for: action), for: action)
    }

    private func persist() {
        let encoded = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
