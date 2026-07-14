import AppKit
import StacioAgentBridge

public enum AgentAuthorizationPolicy: Equatable {
    case allowAllCommandsWithoutPrompt
    case allowLowRiskCommandsWithoutPrompt
    case requireConfirmationForAll
    case allowReadOnlyExternalCommands

    public func requiresConfirmation(for risk: AgentActionRisk) -> Bool {
        switch self {
        case .allowAllCommandsWithoutPrompt:
            return false
        case .allowLowRiskCommandsWithoutPrompt:
            return risk > .write
        case .allowReadOnlyExternalCommands:
            return risk > .readOnly
        case .requireConfirmationForAll:
            return true
        }
    }
}

public struct AgentCommandPatternPolicy: Equatable {
    public let allowPatterns: [String]
    public let denyPatterns: [String]

    public init(allowPatterns: String = "", denyPatterns: String = "") {
        self.allowPatterns = Self.normalizedPatterns(allowPatterns)
        self.denyPatterns = Self.normalizedPatterns(denyPatterns)
    }

    public func matchedDenyPattern(for command: String) -> String? {
        matchedPattern(in: denyPatterns, command: command)
    }

    public func matchedAllowPattern(for command: String) -> String? {
        matchedPattern(in: allowPatterns, command: command)
    }

    private static func normalizedPatterns(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: "\n,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private func matchedPattern(in patterns: [String], command: String) -> String? {
        return patterns.first { pattern in
            patternMatchesCommand(pattern, command: command)
        }
    }

    private func patternMatchesCommand(_ pattern: String, command: String) -> Bool {
        let patternTokens = commandInvocations(from: pattern).first ?? commandTokens(from: pattern)
        guard patternTokens.isEmpty == false else {
            return false
        }
        return commandInvocations(from: command).contains { invocation in
            guard invocation.count >= patternTokens.count else {
                return false
            }
            return zip(invocation, patternTokens).allSatisfy { commandToken, patternToken in
                commandToken == patternToken
            }
        }
    }

    private func commandInvocations(from command: String) -> [[String]] {
        let tokens = commandTokens(from: command)
        var invocations: [[String]] = []
        var current: [String] = []

        func flush() {
            let invocation = normalizedInvocationTokens(current)
            if invocation.isEmpty == false {
                invocations.append(invocation)
            }
            current.removeAll()
        }

        for token in tokens {
            if Self.commandSeparators.contains(token) {
                flush()
                continue
            }
            current.append(token)
        }
        flush()
        return invocations
    }

    private func normalizedInvocationTokens(_ tokens: [String]) -> [String] {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if isEnvironmentAssignment(token) {
                index += 1
                continue
            }
            if Self.wrapperCommands.contains(token) {
                index += 1
                skipWrapperArguments(tokens: tokens, index: &index, wrapper: token)
                continue
            }
            return Array(tokens[index...])
        }
        return []
    }

    private func skipWrapperArguments(tokens: [String], index: inout Int, wrapper: String) {
        while index < tokens.count {
            let token = tokens[index]
            if isEnvironmentAssignment(token), wrapper == "env" {
                index += 1
                continue
            }
            guard token.hasPrefix("-") else {
                return
            }
            index += 1
            if wrapperFlagConsumesNextValue(token, wrapper: wrapper), index < tokens.count {
                index += 1
            }
        }
    }

    private func commandTokens(from command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        func flush() {
            guard current.isEmpty == false else { return }
            tokens.append(normalizedToken(current))
            current.removeAll()
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                flush()
                continue
            }
            if Self.operatorCharacters.contains(character) {
                flush()
                tokens.append(String(character))
                continue
            }
            current.append(character)
        }
        if escaping {
            current.append("\\")
        }
        flush()
        return mergeOperators(tokens)
    }

    private func mergeOperators(_ tokens: [String]) -> [String] {
        var merged: [String] = []
        var index = 0
        while index < tokens.count {
            if index + 1 < tokens.count {
                let pair = tokens[index] + tokens[index + 1]
                if Self.commandSeparators.contains(pair) || Self.redirectionOperators.contains(pair) {
                    merged.append(pair)
                    index += 2
                    continue
                }
            }
            merged.append(tokens[index])
            index += 1
        }
        return merged
    }

    private func normalizedToken(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
    }

    private func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let first = token.first,
              first == "_" || first.isLetter,
              let equalsIndex = token.firstIndex(of: "="),
              equalsIndex != token.startIndex
        else {
            return false
        }
        return token[..<equalsIndex].allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private func wrapperFlagConsumesNextValue(_ flag: String, wrapper: String) -> Bool {
        if flag.contains("=") {
            return false
        }
        switch wrapper {
        case "sudo":
            return ["-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt", "-C", "-T"].contains(flag)
        case "env":
            return ["-u", "--unset"].contains(flag)
        default:
            return false
        }
    }

    private static let commandSeparators: Set<String> = ["|", "||", "&", "&&", ";"]
    private static let redirectionOperators: Set<String> = [">", ">>", "<", "1>", "1>>", "2>", "2>>", "&>"]
    private static let operatorCharacters: Set<Character> = ["|", "&", ";", ">", "<"]
    private static let wrapperCommands: Set<String> = ["sudo", "env", "time", "command", "nohup"]
}

public struct AgentActionConfirmation: Equatable {
    public let actor: AgentActor
    public let risk: AgentActionRisk
    public let targetTitle: String
    public let redactedCommand: String
    public let policySummary: String
    public let sessionEnvironment: String
    public let sessionAIPolicy: String
    public let reason: String

    public init(
        actor: AgentActor,
        risk: AgentActionRisk,
        targetTitle: String,
        redactedCommand: String,
        policySummary: String = "",
        sessionEnvironment: String = "development",
        sessionAIPolicy: String = "inherit",
        reason: String = ""
    ) {
        self.actor = actor
        self.risk = risk
        self.targetTitle = targetTitle
        self.redactedCommand = redactedCommand
        self.policySummary = policySummary
        self.sessionEnvironment = sessionEnvironment
        self.sessionAIPolicy = sessionAIPolicy
        self.reason = reason
    }
}

@MainActor
public protocol AgentActionConfirming {
    func confirmAgentAction(_ confirmation: AgentActionConfirmation, parentWindow: NSWindow?) -> Bool
}

public struct AgentActionAuthorizer: AgentActionAuthorizing {
    private let policy: AgentAuthorizationPolicy
    private let commandPolicy: AgentCommandPatternPolicy
    private let confirmer: AgentActionConfirming
    private let parentWindow: NSWindow?

    private enum SessionPolicyDecision {
        case deny(String)
        case inherit
        case requireConfirmation
        case allowWithoutConfirmation
    }

    public init(
        policy: AgentAuthorizationPolicy,
        commandPolicy: AgentCommandPatternPolicy = AgentCommandPatternPolicy(),
        confirmer: AgentActionConfirming,
        parentWindow: NSWindow? = nil
    ) {
        self.policy = policy
        self.commandPolicy = commandPolicy
        self.confirmer = confirmer
        self.parentWindow = parentWindow
    }

    public func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String
    ) throws -> AgentAuthorizationDecision {
        try authorize(
            actor: actor,
            command: command,
            targetTitle: targetTitle,
            automationPolicy: .default
        )
    }

    public func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> AgentAuthorizationDecision {
        let risk = AgentActionClassifier.risk(forCommand: command)
        if let deniedPattern = commandPolicy.matchedDenyPattern(for: command) {
            return AgentAuthorizationDecision(
                allowed: false,
                reason: "blocked by global deny pattern: \(deniedPattern)",
                risk: risk,
                requiredUserConfirmation: false
            )
        }
        switch sessionPolicyDecision(for: automationPolicy, risk: risk) {
        case .deny(let reason):
            return AgentAuthorizationDecision(
                allowed: false,
                reason: reason,
                risk: risk,
                requiredUserConfirmation: false
            )
        case .allowWithoutConfirmation:
            return AgentAuthorizationDecision(
                allowed: true,
                reason: "allowed by session policy",
                risk: risk,
                requiredUserConfirmation: false
            )
        case .requireConfirmation:
            break
        case .inherit:
            if let allowedPattern = commandPolicy.matchedAllowPattern(for: command) {
                if allowPatternCanBypassConfirmation(allowedPattern, commandRisk: risk) {
                    return AgentAuthorizationDecision(
                        allowed: true,
                        reason: "allowed by global allow pattern: \(allowedPattern)",
                        risk: risk,
                        requiredUserConfirmation: false
                    )
                }
            }
            if policy.requiresConfirmation(for: risk) == false {
                return AgentAuthorizationDecision(
                    allowed: true,
                    reason: "allowed by policy",
                    risk: risk,
                    requiredUserConfirmation: false
                )
            }
        }

        let confirmation = AgentActionConfirmation(
            actor: actor,
            risk: risk,
            targetTitle: targetTitle,
            redactedCommand: AgentProtocolRedaction.redact(command),
            policySummary: policySummary(for: policy),
            sessionEnvironment: automationPolicy.environment,
            sessionAIPolicy: automationPolicy.aiExecutionPolicy,
            reason: confirmationReason(
                automationPolicy: automationPolicy,
                risk: risk
            )
        )
        let allowed = confirmer.confirmAgentAction(confirmation, parentWindow: parentWindow)
        return AgentAuthorizationDecision(
            allowed: allowed,
            reason: allowed ? "confirmed" : "cancelled by user",
            risk: risk,
            requiredUserConfirmation: true
        )
    }

    public func requiresUserConfirmation(actor: AgentActor, command: String, targetTitle: String) -> Bool {
        requiresUserConfirmation(
            actor: actor,
            command: command,
            targetTitle: targetTitle,
            automationPolicy: .default
        )
    }

    public func requiresUserConfirmation(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) -> Bool {
        let risk = AgentActionClassifier.risk(forCommand: command)
        if commandPolicy.matchedDenyPattern(for: command) != nil {
            return false
        }
        switch sessionPolicyDecision(for: automationPolicy, risk: risk) {
        case .deny, .allowWithoutConfirmation:
            return false
        case .requireConfirmation:
            return true
        case .inherit:
            if let allowedPattern = commandPolicy.matchedAllowPattern(for: command),
               allowPatternCanBypassConfirmation(allowedPattern, commandRisk: risk) {
                return false
            }
            return policy.requiresConfirmation(for: risk)
        }
    }

    private func allowPatternCanBypassConfirmation(
        _ pattern: String,
        commandRisk: AgentActionRisk
    ) -> Bool {
        commandRisk <= AgentActionClassifier.risk(forCommand: pattern)
    }

    private func sessionPolicyDecision(
        for automationPolicy: SessionAutomationPolicy,
        risk: AgentActionRisk
    ) -> SessionPolicyDecision {
        switch automationPolicy.aiExecutionPolicy {
        case "disabled":
            return .deny("AI execution disabled for this session")
        default:
            break
        }
        if automationPolicy.environment == "production" {
            return .requireConfirmation
        }
        switch automationPolicy.aiExecutionPolicy {
        case "disabled":
            return .deny("AI execution disabled for this session")
        case "commandCard":
            return .deny("AI execution is limited to command cards for this session")
        case "readOnlyAuto":
            return risk == .readOnly ? .allowWithoutConfirmation : .requireConfirmation
        case "requireEveryCommand":
            return .requireConfirmation
        default:
            return .inherit
        }
    }

    private func policySummary(for policy: AgentAuthorizationPolicy) -> String {
        switch policy {
        case .allowAllCommandsWithoutPrompt:
            return "全局策略：全部自动"
        case .allowLowRiskCommandsWithoutPrompt:
            return "全局策略：低风险自动"
        case .allowReadOnlyExternalCommands:
            return "全局策略：只读自动"
        case .requireConfirmationForAll:
            return "全局策略：每次确认"
        }
    }

    private func confirmationReason(
        automationPolicy: SessionAutomationPolicy,
        risk: AgentActionRisk
    ) -> String {
        if automationPolicy.environment == "production" {
            return "生产环境会话需要确认；命令风险：\(risk.rawValue)。"
        }
        switch automationPolicy.aiExecutionPolicy {
        case "requireEveryCommand":
            return "会话 AI 执行策略要求每条命令确认；命令风险：\(risk.rawValue)。"
        case "readOnlyAuto" where risk > .readOnly:
            return "会话只允许只读命令自动执行，此命令需要确认；命令风险：\(risk.rawValue)。"
        default:
            return "全局审批策略要求确认；命令风险：\(risk.rawValue)。"
        }
    }
}

public struct SettingsBackedAgentActionAuthorizer: AgentActionAuthorizing {
    private let settingsStore: AppSettingsStore
    private let confirmer: AgentActionConfirming
    private let parentWindow: NSWindow?

    public init(
        settingsStore: AppSettingsStore,
        confirmer: AgentActionConfirming,
        parentWindow: NSWindow? = nil
    ) {
        self.settingsStore = settingsStore
        self.confirmer = confirmer
        self.parentWindow = parentWindow
    }

    public func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String
    ) throws -> AgentAuthorizationDecision {
        try currentAuthorizer().authorize(
            actor: actor,
            command: command,
            targetTitle: targetTitle
        )
    }

    public func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> AgentAuthorizationDecision {
        try currentAuthorizer().authorize(
            actor: actor,
            command: command,
            targetTitle: targetTitle,
            automationPolicy: automationPolicy
        )
    }

    public func requiresUserConfirmation(actor: AgentActor, command: String, targetTitle: String) -> Bool {
        currentAuthorizer().requiresUserConfirmation(
            actor: actor,
            command: command,
            targetTitle: targetTitle
        )
    }

    public func requiresUserConfirmation(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) -> Bool {
        currentAuthorizer().requiresUserConfirmation(
            actor: actor,
            command: command,
            targetTitle: targetTitle,
            automationPolicy: automationPolicy
        )
    }

    private func currentAuthorizer() -> AgentActionAuthorizer {
        AgentActionAuthorizer(
            policy: settingsStore.snapshot().agentConfirmationPolicy.authorizationPolicy,
            commandPolicy: AgentCommandPatternPolicy(
                allowPatterns: settingsStore.snapshot().agentCommandAllowPatterns,
                denyPatterns: settingsStore.snapshot().agentCommandDenyPatterns
            ),
            confirmer: confirmer,
            parentWindow: parentWindow
        )
    }
}

public struct AppKitAgentActionConfirmer: AgentActionConfirming {
    public init() {}

    public func confirmAgentAction(_ confirmation: AgentActionConfirmation, parentWindow: NSWindow?) -> Bool {
        AgentActionApprovalPanelController.runModal(
            confirmation: confirmation,
            parentWindow: parentWindow
        )
    }

    public static func makeAlert(for confirmation: AgentActionConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = confirmation.risk >= .destructive ? .critical : .warning
        alert.messageText = "命令需要确认"
        alert.informativeText = ""
        alert.accessoryView = AgentActionApprovalAccessoryView(confirmation: confirmation)
        alert.addButton(withTitle: "批准执行")
        alert.addButton(withTitle: "拒绝")
        return alert
    }

    static func makeApprovalBarForTesting(
        confirmation: AgentActionConfirmation,
        showsActions: Bool
    ) -> NSView {
        AgentActionApprovalBarView(confirmation: confirmation, showsActions: showsActions)
    }
}

private final class AgentActionApprovalAccessoryView: NSView {
    private static let width: CGFloat = 560

    init(confirmation: AgentActionConfirmation) {
        super.init(frame: .zero)
        setAccessibilityIdentifier("Stacio.AgentApproval.sheet")
        translatesAutoresizingMaskIntoConstraints = false
        let bar = AgentActionApprovalBarView(confirmation: confirmation, showsActions: false)
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class AgentActionApprovalBarView: NSView {
    static let preferredWidth: CGFloat = 560

    var onApprove: (() -> Void)?
    var onDeny: (() -> Void)?

    init(confirmation: AgentActionConfirmation, showsActions: Bool) {
        super.init(frame: .zero)
        setAccessibilityIdentifier("Stacio.AgentApproval.compactBar")
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            self,
            color: confirmation.risk >= .destructive
                ? StacioDesignSystem.theme.warningColor.withAlphaComponent(0.16)
                : StacioDesignSystem.theme.warningColor.withAlphaComponent(0.12)
        )
        StacioDesignSystem.setLayerBorderColor(
            self,
            color: StacioDesignSystem.theme.warningColor.withAlphaComponent(0.32)
        )
        layer?.borderWidth = 1

        let commandField = NSTextField(labelWithString: confirmation.redactedCommand)
        commandField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        commandField.textColor = StacioDesignSystem.theme.primaryTextColor
        commandField.backgroundColor = .clear
        commandField.lineBreakMode = .byTruncatingMiddle
        commandField.maximumNumberOfLines = 1
        commandField.isSelectable = true
        commandField.setAccessibilityIdentifier("Stacio.AgentApproval.commandPreview")
        commandField.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let risk = makeRiskBadge(for: confirmation.risk)
        let title = makeTitleLabel("命令需要确认")
        let shortcut = makeShortcutLabel("Enter 批准，Esc 拒绝")
        titleRow.addArrangedSubview(risk)
        titleRow.addArrangedSubview(title)
        titleRow.addArrangedSubview(shortcut)

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 7
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(titleRow)

        let commandRow = NSStackView()
        commandRow.orientation = .horizontal
        commandRow.alignment = .firstBaseline
        commandRow.spacing = 8
        commandRow.translatesAutoresizingMaskIntoConstraints = false
        let prompt = NSTextField(labelWithString: "$")
        prompt.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        prompt.textColor = StacioDesignSystem.theme.primaryTextColor
        prompt.translatesAutoresizingMaskIntoConstraints = false
        commandRow.addArrangedSubview(prompt)
        commandRow.addArrangedSubview(commandField)
        contentStack.addArrangedSubview(commandRow)

        let metaLabel = makeMetaLabel(
            [
                confirmation.actor.name,
                confirmation.targetTitle,
                confirmation.policySummary,
                "\(confirmation.sessionEnvironment) · AI \(confirmation.sessionAIPolicy)",
                confirmation.reason
            ].joined(separator: " · ")
        )
        contentStack.addArrangedSubview(metaLabel)

        let rootStack = NSStackView()
        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(contentStack)

        if showsActions {
            let actions = NSStackView()
            actions.orientation = .horizontal
            actions.alignment = .centerY
            actions.spacing = 10
            actions.translatesAutoresizingMaskIntoConstraints = false
            let denyButton = makeActionButton(title: "拒绝", emphasized: false, action: #selector(denyPressed(_:)))
            let approveButton = makeActionButton(title: "批准执行", emphasized: true, action: #selector(approvePressed(_:)))
            actions.addArrangedSubview(denyButton)
            actions.addArrangedSubview(approveButton)
            rootStack.addArrangedSubview(actions)
            approveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
            denyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        }
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            contentStack.widthAnchor.constraint(greaterThanOrEqualToConstant: showsActions ? 330 : Self.preferredWidth - 28),
            commandField.widthAnchor.constraint(lessThanOrEqualToConstant: showsActions ? 330 : Self.preferredWidth - 60),
            metaLabel.widthAnchor.constraint(lessThanOrEqualToConstant: showsActions ? 330 : Self.preferredWidth - 28)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func makeRiskBadge(for risk: AgentActionRisk) -> NSTextField {
        let label = NSTextField(labelWithString: "⚠")
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = risk >= .destructive
            ? StacioDesignSystem.theme.dangerColor
            : StacioDesignSystem.theme.warningColor
        label.setAccessibilityIdentifier("Stacio.AgentApproval.risk.\(risk.rawValue)")
        label.toolTip = "风险：\(risk.rawValue)"
        return label
    }

    private func makeTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = StacioDesignSystem.theme.warningColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeShortcutLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeMetaLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.toolTip = text
        return label
    }

    private func makeActionButton(title: String, emphasized: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        if emphasized {
            button.keyEquivalent = "\r"
        } else {
            button.keyEquivalent = "\u{1b}"
        }
        return button
    }

    @objc private func approvePressed(_ sender: Any?) {
        onApprove?()
    }

    @objc private func denyPressed(_ sender: Any?) {
        onDeny?()
    }
}

private final class AgentActionApprovalPanelController: NSWindowController, NSWindowDelegate {
    private var result = false

    static func runModal(
        confirmation: AgentActionConfirmation,
        parentWindow: NSWindow?
    ) -> Bool {
        let controller = AgentActionApprovalPanelController(confirmation: confirmation)
        guard let window = controller.window else { return false }
        let application = NSApplication.shared
        if let parentWindow {
            parentWindow.beginSheet(window)
            let response = application.runModal(for: window)
            parentWindow.endSheet(window)
            window.orderOut(nil)
            return response == .OK && controller.result
        }
        let response = application.runModal(for: window)
        window.orderOut(nil)
        return response == .OK && controller.result
    }

    init(confirmation: AgentActionConfirmation) {
        let bar = AgentActionApprovalBarView(confirmation: confirmation, showsActions: true)
        let contentView = NSView(frame: .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bar)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 114),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "命令需要确认"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = contentView
        window.initialFirstResponder = nil
        super.init(window: window)
        window.delegate = self

        bar.onApprove = { [weak self] in
            self?.result = true
            NSApplication.shared.stopModal(withCode: .OK)
        }
        bar.onDeny = { [weak self] in
            self?.result = false
            NSApplication.shared.stopModal(withCode: .cancel)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bar.topAnchor.constraint(equalTo: contentView.topAnchor),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 660),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        window.setContentSize(contentView.fittingSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        result = false
        NSApplication.shared.stopModal(withCode: .cancel)
    }
}
