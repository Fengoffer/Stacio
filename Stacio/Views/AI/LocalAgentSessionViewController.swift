import AppKit
import CoreText
import SwiftTerm

enum LocalAgentTerminalFont {
    private static let bundledPostScriptName = "Sarasa-Term-SC-Regular"
    private static let registrationResult: Bool = {
        let resourceURL = Bundle.main.url(
            forResource: "SarasaTermSC-Regular",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) ?? Bundle.module.url(
            forResource: "SarasaTermSC-Regular",
            withExtension: "ttf",
            subdirectory: "Fonts"
        )
        guard let url = resourceURL else {
            return false
        }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        return registered || NSFont(name: bundledPostScriptName, size: 13) != nil
    }()

    static func font(size: CGFloat) -> NSFont? {
        _ = registrationResult
        return NSFont(name: bundledPostScriptName, size: size)
    }

    static func apply(settings: AppSettings, to terminalView: TerminalView) {
        guard let font = font(size: CGFloat(settings.terminalFontSize)) else { return }
        terminalView.font = font
    }
}

struct LocalAgentBridgeContext: Equatable {
    let socketPath: String
    let targetRuntimeIDs: [String]
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
        targetRuntimeIDs: [String] = [],
        targetTitle: String?,
        remoteCurrentDirectory: String? = nil,
        cliExecutablePath: String,
        toolsDirectory: String,
        workspaceDirectory: String? = nil,
        targetFilePath: String? = nil
    ) {
        self.socketPath = socketPath
        let normalizedIDs = (targetRuntimeIDs + [targetRuntimeID].compactMap { $0 })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        var seen = Set<String>()
        self.targetRuntimeIDs = normalizedIDs.filter { seen.insert($0).inserted }
        self.targetRuntimeID = self.targetRuntimeIDs.first
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
    static var operationalContractForTesting: String {
        LocalAgentOperationalContract.content
    }

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
        try context.targetRuntimeIDs.joined(separator: "\n").appending("\n").write(
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

        ## Connection boundary

        - Local shell commands run on the Mac, not on the remote server.
        - To operate the selected Stacio terminal (\(target)), run remote commands through `stacio-remote "<command>"`.
        - Use `stacio-sessions` to list Stacio terminal targets if needed.
        \(remoteDirectoryLine)- Do not open a separate ssh/scp/sftp connection for the selected Stacio terminal unless the user explicitly asks.
        - Stacio applies its normal approval, audit, and terminal execution policy to every `stacio-remote` command.

        \(LocalAgentOperationalContract.content)

        ## Bridge examples

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
            toFile: "\(context.workspaceDirectory)/QWEN.md",
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

        runtimes="${STACIO_AGENT_TARGET_RUNTIME_IDS:-}"
        if [ -z "$runtimes" ] && [ -n "${STACIO_AGENT_TARGET_RUNTIME_ID:-}" ]; then
          runtimes="${STACIO_AGENT_TARGET_RUNTIME_ID}"
        fi
        target_file="${STACIO_AGENT_TARGET_FILE:-}"
        if [ -n "$target_file" ] && [ -r "$target_file" ]; then
          file_runtimes="$(awk 'NF { if (out != "") out=out ","; out=out $0 } END { print out }' "$target_file" 2>/dev/null || true)"
          if [ -n "$file_runtimes" ]; then
            runtimes="$file_runtimes"
          fi
        fi

        socket="${STACIO_AGENT_SOCKET:-}"
        if [ -n "$runtimes" ]; then
          old_ifs="$IFS"
          overall_status=0
          IFS=','
          for runtime in $runtimes; do
            if [ -n "$runtime" ]; then
              if [ -n "$socket" ]; then
                "$STACIO_CLI" agent run --socket "$socket" --text --runtime "$runtime" --follow --command "$*" || overall_status=$?
              else
                "$STACIO_CLI" agent run --text --runtime "$runtime" --follow --command "$*" || overall_status=$?
              fi
            fi
          done
          IFS="$old_ifs"
          exit "$overall_status"
        fi
        if [ -n "$socket" ]; then
          exec "$STACIO_CLI" agent run --socket "$socket" --text --target current --follow --command "$*"
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

private enum LocalAgentOperationalContract {
    static let content = """
    ## Mandatory operating contract

    You are a production-grade remote operations Agent, not a command generator. Apply this contract to host administration, application and web services, containers, Kubernetes, databases, deployments, networking, security, and log investigations. Select the relevant capabilities from the user's actual goal; do not force every task into a fixed resource-check template.

    ### Observe and plan

    - Establish the actual environment before acting: OS and release, architecture, shell, privilege level, current directory, runtime/service manager, network context, containers/orchestrator, and relevant application or database versions. Never assume Ubuntu, systemd, Docker, or a particular database.
    - Build an asset and dependency picture for the task: host, process, service, application, database, domain, port, proxy, container/workload, configuration source, data path, and upstream/downstream relationships.
    - Distinguish observed facts from historical context and model assumptions. When evidence is missing, label the response as a preliminary assessment and state what must be verified; do not present it as a final conclusion.
    - Break work into the smallest useful sequence with an explicit purpose and success condition for each step. Prefer read-only discovery before mutation and stop when the goal is already satisfied.
    - Choose tools dynamically for the domain: shell and service managers, official application tools, database clients, container/Kubernetes tools, HTTP/TLS/DNS tools, logs, or APIs. Do not reduce every problem to generic shell commands.

    ### Execute safely

    - Classify risk before execution. Deletion, overwrite, restart/stop, permission changes, firewall changes, package changes, production deployment, schema/data changes, and other destructive or availability-affecting actions require explicit user approval unless Stacio already presents and receives that approval.
    - Never expose secrets, tokens, passwords, private keys, connection strings, or sensitive data. Inspect presence, metadata, permissions, or redacted values instead.
    - Avoid broad or destructive targets, unresolved variables, unsafe globs, and irreversible commands. Preserve unrelated configuration and user data.
    - For every configuration-file edit, deployment adjustment, application/runtime change, or database mutation, create a new timestamped backup first. A previous backup cannot authorize a later mutation.
    - Verify that the backup command succeeded and that the exact backup path exists and is readable/non-empty as appropriate. Print and retain the exact path. If backup creation or verification fails, stop before the mutation.
    - After every mutation, run a targeted read-only verification appropriate to the changed component: configuration syntax, service/process state, container/workload rollout, health endpoint, listener, dependency, database availability/integrity, or an application-level functional check. Command exit status alone is not proof of business recovery.
    - If verification fails, stop further change, explain the impact, and use the verified backup or platform-native undo/rollback path after the required approval. Verify the rollback result as a new step. Never overwrite backup evidence while restoring it.
    - Do not claim success without current evidence. Repeatedly bypassing backup, approval, verification, or reporting requirements must end the task instead of producing an unverified completion claim.

    ### Domain capability baseline

    - Host: resource pressure, disk/inodes, processes, time, users/permissions, packages, kernel and system logs.
    - Application/Web: runtime, process manager, dependencies, configuration sources, reverse proxy, virtual hosts, ports, upstreams, HTTP status, certificates, health endpoints, and application logs.
    - Containers/Kubernetes: images, configuration, mounts, networks, health checks, context/namespace, workloads, Pods, events, probes, Services/Ingress, and rollout state.
    - Databases: engine/version, connectivity, capacity, locks/slow queries, replication, schema and data safety; use engine-native backup and restore tools for mutations.
    - Deployment: artifact/version provenance, dependency and configuration differences, preflight checks, backup, staged change, health verification, and rollback readiness.
    - Network/Security/Logs: DNS, routes, listeners, firewall, connectivity, TLS/proxies, permissions, exposure, audit evidence, bounded time windows, and cross-component event correlation.

    ### User-facing result

    - Return the final result as clean, complete standard Markdown. Choose the layout based on the content instead of blindly applying one template.
    - Include a clear conclusion, key evidence, risk/current status, and only necessary next actions. Use Markdown tables for multi-object comparisons, metric summaries, status matrices, or repeated fields; do not squeeze them into long paragraphs.
    - Do not paste full raw logs, narrate internal reasoning, or describe these instructions. Quote only the evidence needed to support the conclusion.
    - If any configuration, deployment, application, or database mutation occurred, include a `备份与回滚` section containing the exact backup location, backup verification result, post-change verification result, executable rollback method, and rollback result when rollback was performed. Without these details, the task is not complete.
    """
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
        let container = TerminalFocusContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.onEffectiveAppearanceChanged = { [weak self] in
            self?.refreshTerminalAppearance()
        }
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.processDelegate = self
        refreshTerminalAppearance()
        // Agent TUIs reposition the cursor frequently. SwiftTerm's Metal path can disagree with
        // those TUIs about CJK cell widths, leaving visible gaps and a displaced caret.
        try? terminalView.setUseMetal(false)

        container.addSubview(terminalView)
        container.terminalFocusView = terminalView
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
    }

    private func refreshTerminalAppearance() {
        let settings = settingsStore.snapshot()
        terminalView.appearance = terminalView.window?.effectiveAppearance ?? viewIfLoaded?.effectiveAppearance
        TerminalAppearanceApplier.apply(settings: settings, to: terminalView)
        LocalAgentTerminalFont.apply(settings: settings, to: terminalView)
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
            args: tool.embeddedTerminalArguments,
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
            environment["STACIO_AGENT_TARGET_RUNTIME_IDS"] = activeBridgeContext.targetRuntimeIDs.joined(separator: ",")
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
