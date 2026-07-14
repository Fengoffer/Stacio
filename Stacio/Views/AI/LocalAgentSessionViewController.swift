import AppKit
import SwiftTerm

struct LocalAgentBridgeContext: Equatable {
    let socketPath: String
    let targetRuntimeID: String?
    let targetTitle: String?
    let remoteCurrentDirectory: String?
    let cliExecutablePath: String
    let toolsDirectory: String
    let workspaceDirectory: String
    let targetFilePath: String

    init(
        socketPath: String,
        targetRuntimeID: String?,
        targetTitle: String?,
        remoteCurrentDirectory: String? = nil,
        cliExecutablePath: String,
        toolsDirectory: String,
        workspaceDirectory: String? = nil,
        targetFilePath: String? = nil
    ) {
        self.socketPath = socketPath
        self.targetRuntimeID = targetRuntimeID
        self.targetTitle = targetTitle
        self.remoteCurrentDirectory = remoteCurrentDirectory
        self.cliExecutablePath = cliExecutablePath
        self.toolsDirectory = toolsDirectory
        let parentDirectory = (toolsDirectory as NSString).deletingLastPathComponent
        self.workspaceDirectory = workspaceDirectory ?? "\(parentDirectory)/AgentWorkspace"
        self.targetFilePath = targetFilePath ?? "\(toolsDirectory)/current-runtime"
    }
}

enum LocalAgentBridgeToolInstaller {
    static func installTools(for context: LocalAgentBridgeContext) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            atPath: context.toolsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileManager.createDirectory(
            atPath: context.workspaceDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try writeExecutable(
            remoteToolScript(),
            to: "\(context.toolsDirectory)/stacio-remote"
        )
        try writeExecutable(
            sessionsToolScript(),
            to: "\(context.toolsDirectory)/stacio-sessions"
        )
        try writeExecutable(
            agentToolScript(),
            to: "\(context.toolsDirectory)/stacio-agent"
        )
        try writeAgentInstructions(for: context)
        try updateTargetFile(for: context)
    }

    static func updateTargetFile(for context: LocalAgentBridgeContext) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            atPath: (context.targetFilePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let target = context.targetRuntimeID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try "\(target)\n".write(
            toFile: context.targetFilePath,
            atomically: true,
            encoding: .utf8
        )
    }

    static func defaultToolsDirectory() -> String {
        if let supportDirectory = try? StacioPaths().applicationSupportDirectory {
            return supportDirectory
                .appendingPathComponent("AgentTools", isDirectory: true)
                .path
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Stacio-AgentTools", isDirectory: true)
            .path
    }

    static func defaultWorkspaceDirectory() -> String {
        if let supportDirectory = try? StacioPaths().applicationSupportDirectory {
            return supportDirectory
                .appendingPathComponent("AgentWorkspace", isDirectory: true)
                .path
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Stacio-AgentWorkspace", isDirectory: true)
            .path
    }

    static func defaultCLIExecutablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        let bundleHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("stacio")
            .path
        let candidates = [
            environment["STACIO_CLI"],
            bundleHelper,
            "/Applications/Stacio.app/Contents/Helpers/stacio",
            "\(fileManager.currentDirectoryPath)/.build/release/StacioCLI",
            "\(fileManager.currentDirectoryPath)/.build/debug/StacioCLI"
        ].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func writeExecutable(_ content: String, to path: String) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: path
        )
    }

    private static func writeAgentInstructions(for context: LocalAgentBridgeContext) throws {
        let targetTitle = context.targetTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetTitle?.isEmpty == false ? targetTitle! : "the current selected Stacio terminal"
        let remoteDirectory = context.remoteCurrentDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteDirectoryLine: String
        if let remoteDirectory, remoteDirectory.isEmpty == false {
            remoteDirectoryLine = "- Current remote directory reported by Stacio: \(remoteDirectory)\n"
        } else {
            remoteDirectoryLine = ""
        }
        let content = """
        # Stacio Local Agent

        You are running inside Stacio's local Agent terminal on the user's Mac.

        Important:
        - Local shell commands run on the Mac, not on the remote server.
        - To operate the selected Stacio terminal (\(target)), run remote commands through `stacio-remote "<command>"`.
        - Use `stacio-sessions` to list Stacio terminal targets if needed.
        \(remoteDirectoryLine)- Do not open a separate ssh/scp/sftp connection for the selected Stacio terminal unless the user explicitly asks.
        - Stacio applies its normal approval, audit, and terminal execution policy to every `stacio-remote` command.

        Examples:
        - `stacio-remote "pwd && uname -a"`
        - `stacio-remote "systemctl status nginx --no-pager"`
        - `stacio-sessions`
        """
        try content.write(
            toFile: "\(context.workspaceDirectory)/AGENTS.md",
            atomically: true,
            encoding: .utf8
        )
        try content.write(
            toFile: "\(context.workspaceDirectory)/CLAUDE.md",
            atomically: true,
            encoding: .utf8
        )
        try content.write(
            toFile: "\(context.workspaceDirectory)/README.md",
            atomically: true,
            encoding: .utf8
        )
    }

    private static func remoteToolScript() -> String {
        """
        #!/bin/sh
        set -eu

        if [ "$#" -eq 0 ]; then
          echo "usage: stacio-remote <command>" >&2
          echo "Runs a command through the current Stacio terminal via Agent Bridge." >&2
          exit 64
        fi
        if [ -z "${STACIO_CLI:-}" ] || [ ! -x "$STACIO_CLI" ]; then
          echo "Stacio CLI helper is unavailable. Reopen Stacio and try again." >&2
          exit 69
        fi

        runtime="${STACIO_AGENT_TARGET_RUNTIME_ID:-}"
        target_file="${STACIO_AGENT_TARGET_FILE:-}"
        if [ -n "$target_file" ] && [ -r "$target_file" ]; then
          file_runtime="$(head -n 1 "$target_file" 2>/dev/null || true)"
          if [ -n "$file_runtime" ]; then
            runtime="$file_runtime"
          fi
        fi

        socket="${STACIO_AGENT_SOCKET:-}"
        if [ -n "$socket" ]; then
          if [ -n "$runtime" ]; then
            exec "$STACIO_CLI" agent run --socket "$socket" --text --runtime "$runtime" --follow --command "$*"
          fi
          exec "$STACIO_CLI" agent run --socket "$socket" --text --target current --follow --command "$*"
        fi

        if [ -n "$runtime" ]; then
          exec "$STACIO_CLI" agent run --text --runtime "$runtime" --follow --command "$*"
        fi
        exec "$STACIO_CLI" agent run --text --target current --follow --command "$*"
        """
    }

    private static func sessionsToolScript() -> String {
        """
        #!/bin/sh
        set -eu

        if [ -z "${STACIO_CLI:-}" ] || [ ! -x "$STACIO_CLI" ]; then
          echo "Stacio CLI helper is unavailable. Reopen Stacio and try again." >&2
          exit 69
        fi
        socket="${STACIO_AGENT_SOCKET:-}"
        if [ -n "$socket" ]; then
          exec "$STACIO_CLI" agent sessions --socket "$socket" --text
        fi
        exec "$STACIO_CLI" agent sessions --text
        """
    }

    private static func agentToolScript() -> String {
        """
        #!/bin/sh
        set -eu

        if [ -z "${STACIO_CLI:-}" ] || [ ! -x "$STACIO_CLI" ]; then
          echo "Stacio CLI helper is unavailable. Reopen Stacio and try again." >&2
          exit 69
        fi
        socket="${STACIO_AGENT_SOCKET:-}"
        if [ -n "$socket" ]; then
          exec "$STACIO_CLI" agent --socket "$socket" "$@"
        fi
        exec "$STACIO_CLI" agent "$@"
        """
    }
}

enum LocalAgentSessionLaunchState: Equatable {
    case idle
    case missingExecutable(String)
    case running(String)
    case terminated(Int32?)
}

final class StacioLocalAgentTerminalView: LocalProcessTerminalView {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

final class LocalAgentSessionViewController: NSViewController, LocalProcessTerminalViewDelegate {
    let tool: LocalAgentTool
    let terminalView: StacioLocalAgentTerminalView
    var onStatusChange: ((LocalAgentSessionLaunchState) -> Void)?
    private(set) var launchState: LocalAgentSessionLaunchState = .idle {
        didSet {
            onStatusChange?(launchState)
        }
    }

    private let resolver: LocalAgentToolResolving
    private let processLauncher: LocalTerminalProcessLaunching
    private let settingsStore: AppSettingsStore
    private let currentDirectoryProvider: () -> String?
    private let bridgeContextProvider: () -> LocalAgentBridgeContext?
    private let environmentProvider: () -> [String: String]
    private(set) var activeBridgeContext: LocalAgentBridgeContext?
    private(set) var bridgeInstallError: String?

    init(
        tool: LocalAgentTool,
        resolver: LocalAgentToolResolving = LocalAgentToolResolver(),
        processLauncher: LocalTerminalProcessLaunching = SwiftTermLocalTerminalProcessLauncher(),
        settingsStore: AppSettingsStore = .shared,
        currentDirectoryProvider: @escaping () -> String? = { nil },
        bridgeContextProvider: @escaping () -> LocalAgentBridgeContext? = { nil },
        environmentProvider: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.tool = tool
        self.resolver = resolver
        self.processLauncher = processLauncher
        self.settingsStore = settingsStore
        self.currentDirectoryProvider = currentDirectoryProvider
        self.bridgeContextProvider = bridgeContextProvider
        self.environmentProvider = environmentProvider
        self.terminalView = StacioLocalAgentTerminalView(frame: .zero)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.processDelegate = self
        TerminalAppearanceApplier.apply(settings: settingsStore.snapshot(), to: terminalView)

        container.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startIfNeeded()
    }

    func startIfNeeded() {
        guard processLauncher.isRunning(terminalView) == false else {
            return
        }
        switch launchState {
        case .idle, .missingExecutable, .terminated:
            break
        case .running:
            return
        }
        guard let executablePath = resolver.executablePath(for: tool) else {
            launchState = .missingExecutable(tool.displayName)
            terminalView.feed(text: "Stacio 找不到 \(tool.displayName) 本地命令，请先安装或把命令加入 PATH。\r\n")
            return
        }

        let environment = launchEnvironment(executablePath: executablePath)
        processLauncher.startProcess(
            in: terminalView,
            executable: executablePath,
            args: [],
            environment: environment,
            execName: tool.executableNames.first,
            currentDirectory: activeBridgeContext?.workspaceDirectory ?? currentDirectoryProvider()
        )
        launchState = .running(executablePath)
    }

    func terminateSession() {
        processLauncher.terminate(terminalView)
    }

    func refreshBridgeContext() {
        guard let context = bridgeContextProvider() else {
            activeBridgeContext = nil
            bridgeInstallError = nil
            return
        }
        do {
            try LocalAgentBridgeToolInstaller.installTools(for: context)
            activeBridgeContext = context
            bridgeInstallError = nil
        } catch {
            activeBridgeContext = context
            bridgeInstallError = RuntimeDiagnosticFormatter.userMessage(for: error)
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        launchState = .terminated(exitCode)
    }

    private func launchEnvironment(executablePath: String) -> [String] {
        var environment = environmentProvider()
        refreshBridgeContext()
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["COLORTERM"] = environment["COLORTERM"] ?? "truecolor"
        environment["STACIO_LOCAL_AGENT"] = tool.rawValue
        if let activeBridgeContext {
            environment["STACIO_AGENT_SOCKET"] = activeBridgeContext.socketPath
            environment["STACIO_AGENT_TARGET_RUNTIME_ID"] = activeBridgeContext.targetRuntimeID
            environment["STACIO_AGENT_TARGET_TITLE"] = activeBridgeContext.targetTitle
            environment["STACIO_REMOTE_CURRENT_DIRECTORY"] = activeBridgeContext.remoteCurrentDirectory
            environment["STACIO_AGENT_TARGET_FILE"] = activeBridgeContext.targetFilePath
            environment["STACIO_CLI"] = activeBridgeContext.cliExecutablePath
            environment["STACIO_REMOTE_COMMAND"] = "stacio-remote \"uptime\""
            environment["STACIO_REMOTE_HELP"] = "Use stacio-remote \"<command>\" to run commands through the current Stacio terminal."
        }
        environment["PATH"] = launchPath(
            executablePath: executablePath,
            existingPath: environment["PATH"],
            homeDirectory: environment["HOME"] ?? NSHomeDirectory(),
            additionalDirectories: activeBridgeContext.map { [$0.toolsDirectory] } ?? []
        )
        return environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    private func launchPath(
        executablePath: String,
        existingPath: String?,
        homeDirectory: String,
        additionalDirectories: [String] = []
    ) -> String {
        let executableDirectory = (executablePath as NSString).deletingLastPathComponent
        let home = homeDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rootedHome = home.isEmpty ? homeDirectory : "/\(home)"
        let preferredDirectories = additionalDirectories + [
            executableDirectory,
            "\(rootedHome)/.hermes/node/bin",
            "\(rootedHome)/.opencode/bin",
            "\(rootedHome)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existingDirectories = (existingPath ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        let directories = (preferredDirectories + existingDirectories).filter { directory in
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.contains(trimmed) == false else {
                return false
            }
            seen.insert(trimmed)
            return true
        }
        return directories.joined(separator: ":")
    }
}
