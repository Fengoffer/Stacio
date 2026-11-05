import AppKit
import SwiftTerm

public final class AppKitLocalAgentWebsiteOpener: LocalAgentWebsiteOpening {
    public init() {}

    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// Presents Settings-only Local Agent authentication in an isolated managed
/// PTY. It never creates a workspace, TargetBinding, bridge capability, or
/// conversation effect.
public final class AppKitLocalAgentMaintenancePresenter: LocalAgentMaintenancePresenting {
    private weak var parentWindow: NSWindow?
    private var activeWindowController: LocalAgentMaintenanceWindowController?

    public init(parentWindow: NSWindow?) {
        self.parentWindow = parentWindow
    }

    public func updateParentWindow(_ window: NSWindow?) {
        parentWindow = window
    }

    public func present(
        request: LocalAgentMaintenanceLaunchRequest,
        onProcessStarted: @escaping (LocalAgentMaintenanceProcessIdentity) -> Bool,
        completion: @escaping (LocalAgentMaintenanceLaunchOutcome) -> Void
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in
                present(
                    request: request,
                    onProcessStarted: onProcessStarted,
                    completion: completion
                )
            }
            return
        }
        guard activeWindowController == nil else {
            completion(.failed(reasonCode: "local_agent_process_busy"))
            return
        }

        let contentController = LocalAgentMaintenanceViewController(
            request: request,
            onProcessStarted: onProcessStarted
        )
        let windowController = LocalAgentMaintenanceWindowController(
            contentController: contentController,
            title: request.action == .login ? "登录 \(request.displayName)" : "退出 \(request.displayName)"
        )
        activeWindowController = windowController
        contentController.onCompletion = { [weak self, weak windowController] outcome in
            windowController?.dismiss()
            if self?.activeWindowController === windowController {
                self?.activeWindowController = nil
            }
            completion(outcome)
        }

        guard contentController.start() else {
            return
        }
        if let parentWindow {
            windowController.beginSheet(for: parentWindow)
        } else {
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
        }
    }
}

final class LocalAgentMaintenanceViewController: NSViewController, LocalProcessTerminalViewDelegate {
    enum State: Equatable {
        case idle
        case running
        case interrupting
        case forceStopAvailable
        case finished
    }

    let terminalView = StacioLocalAgentTerminalView(frame: .zero)
    private(set) var state: State = .idle
    var onCompletion: ((LocalAgentMaintenanceLaunchOutcome) -> Void)?

    private let request: LocalAgentMaintenanceLaunchRequest
    private let processLauncher: LocalTerminalProcessLaunching
    private let onProcessStarted: (LocalAgentMaintenanceProcessIdentity) -> Bool
    private let forceStopGraceInterval: TimeInterval
    private let fileManager: FileManager
    private var cancellationRequested = false
    private var processIdentityRejected = false
    private var forceStopWorkItem: DispatchWorkItem?

    private let statusLabel = NSTextField(labelWithString: "准备启动")
    private lazy var stopButton: NSButton = {
        let button = NSButton(
            title: "停止",
            target: self,
            action: #selector(stopButtonPressed(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.image = NSImage(
            systemSymbolName: "stop.circle.fill",
            accessibilityDescription: "停止"
        )
        button.imagePosition = .imageLeading
        button.contentTintColor = .systemRed
        button.setAccessibilityIdentifier("Stacio.Settings.localAgentMaintenance.stop")
        return button
    }()

    init(
        request: LocalAgentMaintenanceLaunchRequest,
        processLauncher: LocalTerminalProcessLaunching = SwiftTermLocalTerminalProcessLauncher(),
        forceStopGraceInterval: TimeInterval = 2,
        fileManager: FileManager = .default,
        onProcessStarted: @escaping (LocalAgentMaintenanceProcessIdentity) -> Bool
    ) {
        self.request = request
        self.processLauncher = processLauncher
        self.forceStopGraceInterval = forceStopGraceInterval
        self.fileManager = fileManager
        self.onProcessStarted = onProcessStarted
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.Settings.localAgentMaintenance.root")

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(
            labelWithString: request.action == .login ? "登录 \(request.displayName)" : "退出 \(request.displayName)"
        )
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("Stacio.Settings.localAgentMaintenance.status")

        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(statusLabel)
        header.addArrangedSubview(stopButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.processDelegate = self
        terminalView.setAccessibilityIdentifier("Stacio.Settings.localAgentMaintenance.terminal")
        terminalView.appearance = NSApp.effectiveAppearance
        let settings = AppSettingsStore.shared.snapshot()
        TerminalAppearanceApplier.apply(settings: settings, to: terminalView)
        LocalAgentTerminalFont.apply(settings: settings, to: terminalView)
        try? terminalView.setUseMetal(false)

        root.addSubview(header)
        root.addSubview(separator)
        root.addSubview(terminalView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            terminalView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])
        view = root
    }

    /// Starts synchronously while the window is still hidden, so durable PID /
    /// PGID registration happens before a running terminal becomes visible.
    @discardableResult
    func start() -> Bool {
        guard state == .idle else { return state != .finished }
        loadViewIfNeeded()
        guard validateLaunchRequest() else {
            finish(.failed(reasonCode: "invalid_maintenance_launch"))
            return false
        }

        statusLabel.stringValue = "正在启动"
        processLauncher.startProcess(
            in: terminalView,
            executable: request.executablePath,
            args: request.arguments,
            environment: request.environment,
            execName: URL(fileURLWithPath: request.executablePath).lastPathComponent,
            currentDirectory: request.currentDirectory
        )
        guard processLauncher.isRunning(terminalView) else {
            finish(.failed(reasonCode: "maintenance_process_start_failed"))
            return false
        }
        guard let processIdentifier = processLauncher.managedProcessIdentifier(terminalView),
              let processGroupIdentifier = processLauncher.managedProcessGroupID(terminalView),
              let trustedStartTime = processLauncher.managedProcessTrustedStartTime(terminalView),
              processIdentifier > 0,
              processGroupIdentifier > 0
        else {
            processIdentityRejected = true
            statusLabel.stringValue = "正在安全终止"
            processLauncher.terminate(terminalView)
            if processLauncher.isRunning(terminalView) == false {
                finish(.stateUnknown(referenceID: request.operationID))
            }
            return false
        }

        let accepted = onProcessStarted(
            .init(
                processIdentifier: processIdentifier,
                processGroupIdentifier: processGroupIdentifier,
                trustedStartTime: trustedStartTime
            )
        )
        guard accepted else {
            processIdentityRejected = true
            statusLabel.stringValue = "正在安全终止"
            processLauncher.terminate(terminalView)
            if processLauncher.isRunning(terminalView) == false {
                finish(.stateUnknown(referenceID: request.operationID))
            }
            return false
        }

        state = .running
        statusLabel.stringValue = "运行中"
        return true
    }

    func requestStop() {
        switch state {
        case .running:
            cancellationRequested = true
            state = .interrupting
            statusLabel.stringValue = "正在中断"
            stopButton.isEnabled = false
            processLauncher.interrupt(terminalView)
            if processLauncher.isRunning(terminalView) == false {
                finish(.cancelled)
                return
            }
            scheduleForceStopAvailability()
        case .forceStopAvailable:
            statusLabel.stringValue = "正在强制停止"
            stopButton.isEnabled = false
            processLauncher.terminate(terminalView)
            if processLauncher.isRunning(terminalView) == false {
                finish(.cancelled)
            }
        case .idle, .interrupting, .finished:
            break
        }
    }

    @objc private func stopButtonPressed(_ sender: NSButton) {
        requestStop()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === terminalView,
              state != .finished,
              processLauncher.isRunning(terminalView) == false
        else {
            return
        }
        if processIdentityRejected {
            finish(.stateUnknown(referenceID: request.operationID))
        } else if cancellationRequested {
            finish(.cancelled)
        } else if let exitCode {
            finish(.exited(exitCode: exitCode))
        } else {
            finish(.stateUnknown(referenceID: request.operationID))
        }
    }

    private func scheduleForceStopAvailability() {
        forceStopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .interrupting else { return }
            guard self.processLauncher.isRunning(self.terminalView) else {
                self.finish(.cancelled)
                return
            }
            self.state = .forceStopAvailable
            self.statusLabel.stringValue = "仍在运行"
            self.stopButton.title = "强制停止"
            self.stopButton.image = NSImage(
                systemSymbolName: "xmark.octagon.fill",
                accessibilityDescription: "强制停止"
            )
            self.stopButton.isEnabled = true
        }
        forceStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + forceStopGraceInterval, execute: work)
    }

    private func validateLaunchRequest() -> Bool {
        guard request.executablePath.hasPrefix("/"),
              URL(fileURLWithPath: request.executablePath).standardizedFileURL.path == request.executablePath,
              fileManager.isExecutableFile(atPath: request.executablePath),
              request.currentDirectory.hasPrefix("/"),
              URL(fileURLWithPath: request.currentDirectory, isDirectory: true).standardizedFileURL.path
                == request.currentDirectory
        else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: request.currentDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }
        return request.environment.allSatisfy { entry in
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else { return false }
            return entry[..<separator].utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
            }
        }
    }

    private func finish(_ outcome: LocalAgentMaintenanceLaunchOutcome) {
        guard state != .finished else { return }
        state = .finished
        forceStopWorkItem?.cancel()
        forceStopWorkItem = nil
        stopButton.isEnabled = false
        let completion = onCompletion
        onCompletion = nil
        completion?(outcome)
    }
}

private final class LocalAgentMaintenanceWindowController: NSWindowController, NSWindowDelegate {
    private let maintenanceController: LocalAgentMaintenanceViewController

    init(contentController: LocalAgentMaintenanceViewController, title: String) {
        maintenanceController = contentController
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 760, height: 500)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.minSize = NSSize(width: 620, height: 420)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.contentViewController = contentController
        StacioDesignSystem.applyWindowChrome(panel)
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func beginSheet(for parentWindow: NSWindow) {
        guard let window, window.sheetParent == nil else { return }
        parentWindow.beginSheet(window)
    }

    func dismiss() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        maintenanceController.requestStop()
        return maintenanceController.state == .finished
    }
}
