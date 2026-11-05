import AppKit
import Foundation
import StacioCoreBindings

struct BLEConsoleScannerRowModel: Equatable, Sendable {
    let device: BLEConsoleDiscoveredDevice

    var leadingSymbolName: String {
        device.recognition == .nbee1103 || device.isProbableConsole
            ? "bluetooth"
            : "dot.radiowaves.left.and.right"
    }

    var signalSymbolName: String { "cellularbars" }

    var signalStrength: Double { device.rssi.signalStrength ?? 0 }

    var signalAccessibilityDescription: String {
        device.rssi.signalStrength == nil
            ? L10n.BLEConsole.scannerRSSIUnavailable
            : L10n.BLEConsole.scannerSignalStrength
    }

    var recognitionSymbolName: String? {
        device.recognition == .nbee1103 ? "checkmark.circle.fill" : nil
    }

    var title: String { device.displayName }

    var detail: String {
        if device.advertisedServiceUUIDs.isEmpty {
            return L10n.BLEConsole.scannerGenericDevice
        }
        return device.advertisedServiceUUIDs.joined(separator: ", ")
    }
}

@MainActor
protocol BLEConsoleScannerPresenting: AnyObject {
    func presentBLEConsoleScanner(
        parentWindow: NSWindow?,
        initialConfig: ConsoleSessionConfig?
    ) -> ConsoleSessionConfig?
}

@MainActor
final class CoreBluetoothBLEConsoleScannerPresenter: BLEConsoleScannerPresenting {
    private let driverFactory: () -> BLEConsoleCentralDriving

    init(driverFactory: @escaping () -> BLEConsoleCentralDriving = {
        CoreBluetoothBLEConsoleCentralDriver()
    }) {
        self.driverFactory = driverFactory
    }

    func presentBLEConsoleScanner(
        parentWindow: NSWindow?,
        initialConfig: ConsoleSessionConfig?
    ) -> ConsoleSessionConfig? {
        let controller = BLEConsoleScannerViewController(
            driver: driverFactory(),
            initialConfig: initialConfig
        )
        return controller.runModal(parentWindow: parentWindow)
    }
}

@MainActor
final class BLEConsoleScannerViewController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private enum ProbeState {
        case idle
        case connecting
        case discovering
        case mapping
        case disconnecting
        case finished
    }

    private final class ScannerRootView: NSView {
        var onKeyDown: ((NSEvent) -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if onKeyDown?(event) == true { return }
            super.keyDown(with: event)
        }
    }

    private final class ScannerRowView: NSTableRowView {
        var isRecognized = false

        override func drawBackground(in dirtyRect: NSRect) {
            super.drawBackground(in: dirtyRect)
            guard isSelected == false, isRecognized else { return }
            let color = StacioDesignSystem.theme.accentColor.withAlphaComponent(0.08)
            color.setFill()
            dirtyRect.fill()
        }
    }

    private let driver: BLEConsoleCentralDriving
    private let initialConfig: ConsoleSessionConfig?
    private var devices: [BLEConsoleDiscoveredDevice] = []
    private var filteredDevices: [BLEConsoleDiscoveredDevice] = []
    private var selectedIdentifier: UUID?
    private var scanGeneration: UInt64 = 0
    private var probeGeneration: UInt64 = 0
    private var probeState: ProbeState = .idle
    private var probeDevice: BLEConsoleDiscoveredDevice?
    private var probeServices: [ConsoleServiceMetadata] = []
    private var didRequestProbeDisconnect = false
    private var result: ConsoleSessionConfig?
    private var isClosed = false

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: L10n.BLEConsole.scannerEmpty)
    private let rescanButton = NSButton()
    private let connectButton = NSButton(title: L10n.BLEConsole.scannerConnect, target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.BLEConsole.scannerCancel, target: nil, action: nil)

    var onConfirm: ((ConsoleSessionConfig) -> Void)?
    var onCancel: (() -> Void)?
    /// Tests and embedders can supply a non-modal mapper implementation.
    var mapperSelectionProvider: ((String, [ConsoleServiceMetadata]) -> ConsoleProfileMatch?)?

    init(
        driver: BLEConsoleCentralDriving = CoreBluetoothBLEConsoleCentralDriver(),
        initialConfig: ConsoleSessionConfig? = nil
    ) {
        self.driver = driver
        self.initialConfig = initialConfig
        super.init(nibName: nil, bundle: nil)
        driver.eventHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.receive(event)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        driver.eventHandler = nil
    }

    override func loadView() {
        let root = ScannerRootView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        StacioDesignSystem.applyRootSurface(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.surface")
        root.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }

        let title = NSTextField(labelWithString: L10n.BLEConsole.scannerTitle)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.title")

        searchField.placeholderString = L10n.BLEConsole.scannerSearchPlaceholder
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.search")

        progressIndicator.style = .spinning
        progressIndicator.isIndeterminate = true
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.progress")
        progressIndicator.startAnimation(nil)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.status")

        rescanButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: L10n.BLEConsole.scannerRescan
        )
        rescanButton.imagePosition = .imageOnly
        rescanButton.bezelStyle = .texturedRounded
        rescanButton.isBordered = false
        rescanButton.toolTip = L10n.BLEConsole.scannerRescan
        rescanButton.target = self
        rescanButton.action = #selector(rescanPressed(_:))
        rescanButton.translatesAutoresizingMaskIntoConstraints = false
        rescanButton.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.rescan")
        rescanButton.setAccessibilityLabel(L10n.BLEConsole.scannerRescan)

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.scrollView")

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        emptyLabel.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.empty")

        connectButton.target = self
        connectButton.action = #selector(connectPressed(_:))
        connectButton.keyEquivalent = "\r"
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.connect")
        StacioDesignSystem.styleSheetButton(connectButton, isDefault: true)

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.cancel")
        StacioDesignSystem.styleSheetButton(cancelButton)

        let toolbar = NSStackView(views: [progressIndicator, statusLabel, NSView(), rescanButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [NSView(), cancelButton, connectButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(searchField)
        root.addSubview(toolbar)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 440),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16),
            rescanButton.widthAnchor.constraint(equalToConstant: 28),
            rescanButton.heightAnchor.constraint(equalToConstant: 28),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            connectButton.widthAnchor.constraint(equalToConstant: 86),
            cancelButton.widthAnchor.constraint(equalToConstant: 86)
        ])

        view = root
        updateStatus(text: L10n.BLEConsole.scannerScanning, scanning: true)
        applyFilteredDevices()
        startScan()
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.style = .sourceList
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.table")
    }

    private func startScan() {
        scanGeneration &+= 1
        updateStatus(text: L10n.BLEConsole.scannerScanning, scanning: true)
        driver.startScan()
    }

    private func receive(_ event: BLEConsoleCentralEvent) {
        guard !isClosed else { return }
        switch event {
        case let .stateChanged(state):
            switch state {
            case .unauthorized:
                updateStatus(text: BLEConsoleErrorCode.permissionDenied.message, scanning: false)
            case .poweredOff:
                updateStatus(text: BLEConsoleErrorCode.poweredOff.message, scanning: false)
            case .unsupported:
                updateStatus(text: BLEConsoleErrorCode.unavailable.message, scanning: false)
            case .unknown, .resetting:
                updateStatus(text: L10n.BLEConsole.scannerScanning, scanning: true)
            case .poweredOn:
                break
            }
        case let .discoverySnapshot(snapshot):
            apply(snapshot)
        case let .scanCompleted(snapshot, timedOut):
            apply(snapshot)
            updateStatus(
                text: timedOut && filteredDevices.isEmpty
                    ? BLEConsoleErrorCode.scanTimeout.message
                    : (filteredDevices.isEmpty ? L10n.BLEConsole.scannerEmpty : ""),
                scanning: false
            )
        case let .connected(identifier, generation):
            guard probeState == .connecting,
                  identifier == probeDevice?.identifier,
                  generation == probeGeneration
            else { return }
            probeState = .discovering
            updateStatus(text: "正在读取 GATT Service...", scanning: false)
            driver.discoverProfile(identifier: identifier, generation: generation)
        case let .servicesDiscovered(identifier, services, generation):
            guard probeState == .discovering,
                  identifier == probeDevice?.identifier,
                  generation == probeGeneration
            else { return }
            handleDiscoveredServices(services, generation: generation)
        case let .profileDiscoveryFailed(identifier, code, diagnostic, generation):
            guard identifier == probeDevice?.identifier, generation == probeGeneration else { return }
            probeFailed(code: code, diagnostic: diagnostic)
        case let .connectionFailed(identifier, code, diagnostic, generation):
            guard identifier == probeDevice?.identifier, generation == probeGeneration else { return }
            probeFailed(code: code, diagnostic: diagnostic)
        case let .disconnected(identifier, _, generation):
            guard identifier == probeDevice?.identifier, generation == probeGeneration else { return }
            if probeState == .disconnecting {
                probeState = .finished
            }
        case .subscribed, .subscriptionFailed, .rxData, .writeAcknowledged, .writeFailed, .readyToSendWithoutResponse:
            break
        }
    }

    private func apply(_ snapshot: BLEConsoleDiscoverySnapshot) {
        let previousSelection = selectedIdentifier
        devices = snapshot.devices
        if let selected = previousSelection,
           devices.contains(where: { $0.identifier == selected }) {
            selectedIdentifier = selected
        } else {
            selectedIdentifier = nil
        }
        applyFilteredDevices()
    }

    private func applyFilteredDevices() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filteredDevices = devices.filter { device in
            guard !query.isEmpty else { return true }
            let haystack = ([device.displayName, device.identifier.uuidString] + device.advertisedServiceUUIDs)
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(query)
        }
        tableView.reloadData()
        if let selectedIdentifier,
           let row = filteredDevices.firstIndex(where: { $0.identifier == selectedIdentifier }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
        emptyLabel.stringValue = query.isEmpty ? L10n.BLEConsole.scannerEmpty : L10n.BLEConsole.scannerNoMatch
        emptyLabel.isHidden = !filteredDevices.isEmpty
        connectButton.isEnabled = selectedIdentifier != nil && probeState == .idle
    }

    private func updateStatus(text: String, scanning: Bool) {
        statusLabel.stringValue = text
        progressIndicator.isHidden = !scanning
        if scanning {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func handleDiscoveredServices(_ services: [ConsoleServiceMetadata], generation: UInt64) {
        probeServices = services
        guard let device = probeDevice else {
            probeFailed(code: .deviceNotFound, diagnostic: nil)
            return
        }
        if let builtIn = CoreBridge.matchBLEConsoleProfile(services: services) {
            finishBinding(device: device, profile: builtIn, status: L10n.BLEConsole.scannerBindingReady)
            return
        }

        probeState = .mapping
        let mapped: ConsoleProfileMatch?
        if let mapperSelectionProvider {
            mapped = mapperSelectionProvider(device.displayName, services)
        } else {
            let mapper = BLEConsoleCharacteristicMapperViewController(
                deviceName: device.displayName,
                services: services
            )
            mapped = mapper.runModal(parentWindow: view.window)
        }
        guard let mapped else {
            disconnectProbe()
            probeState = .idle
            updateStatus(text: L10n.BLEConsole.scannerScanning, scanning: false)
            applyFilteredDevices()
            return
        }
        finishBinding(device: device, profile: mapped, status: L10n.BLEConsole.scannerBindingCustom)
    }

    private func finishBinding(
        device: BLEConsoleDiscoveredDevice,
        profile: ConsoleProfileMatch,
        status: String
    ) {
        guard let serviceUUID = BLEConsoleCharacteristicMapperViewController.normalizeUUID(profile.serviceUuid),
              let txUUID = BLEConsoleCharacteristicMapperViewController.normalizeUUID(profile.txCharacteristicUuid),
              let rxUUID = BLEConsoleCharacteristicMapperViewController.normalizeUUID(profile.rxCharacteristicUuid)
        else {
            probeFailed(code: .configInvalid, diagnostic: "invalid mapped UUID")
            return
        }
        let config = ConsoleSessionConfig(
            kind: "console",
            schemaVersion: 1,
            transportPolicy: "prefer_ble",
            ble: ConsoleBleConfig(
                deviceName: device.displayName,
                profileId: profile.profileId,
                serviceUuid: serviceUUID,
                txCharacteristicUuid: txUUID,
                rxCharacteristicUuid: rxUUID,
                writeType: profile.writeType,
                platformBindings: ConsolePlatformBindings(
                    macOsPeripheralUuid: device.identifier.uuidString,
                    windowsDeviceId: initialConfig?.ble.platformBindings.windowsDeviceId
                )
            ),
            sppFallback: initialConfig?.sppFallback
        )
        result = config
        updateStatus(text: status, scanning: false)
        disconnectProbe()
        probeState = .finished
        onConfirm?(config)
    }

    private func probeFailed(code: BLEConsoleErrorCode, diagnostic: String?) {
        disconnectProbe()
        probeState = .idle
        let detail = diagnostic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updateStatus(
            text: detail.isEmpty ? code.message : "\(code.message) \(detail)",
            scanning: false
        )
        applyFilteredDevices()
    }

    private func disconnectProbe() {
        guard !didRequestProbeDisconnect,
              let device = probeDevice
        else { return }
        didRequestProbeDisconnect = true
        probeState = .disconnecting
        driver.disconnect(identifier: device.identifier, generation: probeGeneration)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilteredDevices()
    }

    @objc private func rescanPressed(_ sender: Any?) {
        guard probeState == .idle || probeState == .finished else { return }
        selectedIdentifier = nil
        devices = []
        filteredDevices = []
        didRequestProbeDisconnect = false
        probeDevice = nil
        probeServices = []
        probeState = .idle
        applyFilteredDevices()
        startScan()
    }

    @objc private func connectPressed(_ sender: Any?) {
        guard probeState == .idle,
              let identifier = selectedIdentifier,
              let device = devices.first(where: { $0.identifier == identifier })
        else { return }
        driver.stopScan()
        probeDevice = device
        didRequestProbeDisconnect = false
        probeGeneration &+= 1
        probeState = .connecting
        connectButton.isEnabled = false
        updateStatus(text: "正在连接 (device.displayName)...", scanning: false)
        driver.connect(identifier: identifier, generation: probeGeneration)
    }

    @objc private func cancelPressed(_ sender: Any?) {
        driver.stopScan()
        disconnectProbe()
        isClosed = true
        onCancel?()
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76 { // Return / keypad Enter
            connectPressed(nil)
            return true
        }
        if event.keyCode == 53 {
            cancelPressed(nil)
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "r" {
            rescanPressed(nil)
            return true
        }
        return false
    }

    func runModal(parentWindow: NSWindow?) -> ConsoleSessionConfig? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.BLEConsole.scannerTitle
        StacioDesignSystem.applyWindowChrome(window)
        window.contentViewController = self
        var response: NSApplication.ModalResponse = .cancel
        onConfirm = { _ in NSApplication.shared.stopModal(withCode: .OK) }
        onCancel = { NSApplication.shared.stopModal(withCode: .cancel) }
        if let parentWindow {
            parentWindow.beginSheet(window)
            response = NSApplication.shared.runModal(for: window)
            parentWindow.endSheet(window)
            window.orderOut(nil)
        } else {
            window.center()
            response = NSApplication.shared.runModal(for: window)
            window.close()
        }
        isClosed = true
        driver.stopScan()
        return response == .OK ? result : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredDevices.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard filteredDevices.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("BLEConsoleScannerDeviceCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        let device = filteredDevices[row]
        let model = BLEConsoleScannerRowModel(device: device)

        let leading = cell.imageView ?? NSImageView()
        leading.image = StacioSymbolImage.image(
            named: model.leadingSymbolName,
            accessibilityDescription: device.displayName,
            size: NSSize(width: 18, height: 18)
        )
        leading.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        leading.contentTintColor = device.isProbableConsole
            ? StacioDesignSystem.theme.accentColor
            : StacioDesignSystem.theme.secondaryTextColor
        leading.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = leading

        let title = cell.textField ?? NSTextField(labelWithString: "")
        title.stringValue = model.title
        title.font = .systemFont(ofSize: 13)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = title

        let detail = cell.subviews.compactMap { $0 as? NSTextField }.first(where: { $0 !== title })
            ?? NSTextField(labelWithString: "")
        detail.stringValue = model.detail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = StacioDesignSystem.theme.secondaryTextColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        let recognitionIdentifier = NSUserInterfaceItemIdentifier("BLEConsoleScannerRecognition")
        let recognition = cell.subviews
            .compactMap { $0 as? NSImageView }
            .first(where: { $0.identifier == recognitionIdentifier }) ?? NSImageView()
        recognition.identifier = recognitionIdentifier
        if let symbol = model.recognitionSymbolName {
            recognition.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.BLEConsole.scannerRecognized)
            recognition.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            recognition.contentTintColor = StacioDesignSystem.theme.successColor
        } else {
            recognition.image = nil
        }
        recognition.translatesAutoresizingMaskIntoConstraints = false

        let signalIdentifier = NSUserInterfaceItemIdentifier("BLEConsoleScannerSignal")
        let signal = cell.subviews
            .compactMap { $0 as? NSImageView }
            .first(where: { $0.identifier == signalIdentifier }) ?? NSImageView()
        signal.identifier = signalIdentifier
        signal.image = NSImage(
            systemSymbolName: model.signalSymbolName,
            variableValue: model.signalStrength,
            accessibilityDescription: model.signalAccessibilityDescription
        )
        signal.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        signal.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        signal.toolTip = model.signalAccessibilityDescription
        signal.translatesAutoresizingMaskIntoConstraints = false

        let needsConstraintInstallation = signal.superview == nil
        if leading.superview == nil { cell.addSubview(leading) }
        if title.superview == nil { cell.addSubview(title) }
        if detail.superview == nil { cell.addSubview(detail) }
        if recognition.superview == nil { cell.addSubview(recognition) }
        if signal.superview == nil { cell.addSubview(signal) }
        if needsConstraintInstallation {
            NSLayoutConstraint.activate([
                leading.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                leading.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                leading.widthAnchor.constraint(equalToConstant: 20),
                leading.heightAnchor.constraint(equalToConstant: 20),
                title.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 8),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
                title.trailingAnchor.constraint(lessThanOrEqualTo: recognition.leadingAnchor, constant: -8),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: recognition.leadingAnchor, constant: -8),
                recognition.trailingAnchor.constraint(equalTo: signal.leadingAnchor, constant: -6),
                recognition.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                recognition.widthAnchor.constraint(equalToConstant: 16),
                recognition.heightAnchor.constraint(equalToConstant: 16),
                signal.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                signal.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                signal.widthAnchor.constraint(equalToConstant: 18),
                signal.heightAnchor.constraint(equalToConstant: 18)
            ])
        }
        cell.setAccessibilityLabel("\(device.displayName)，\(model.signalAccessibilityDescription)")
        cell.setAccessibilityIdentifier("Stacio.BLEConsole.Scanner.device.\(device.identifier.uuidString)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedIdentifier = filteredDevices.indices.contains(row) ? filteredDevices[row].identifier : nil
        connectButton.isEnabled = selectedIdentifier != nil && probeState == .idle
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ScannerRowView()
        if filteredDevices.indices.contains(row) {
            view.isRecognized = filteredDevices[row].recognition == .nbee1103
        }
        return view
    }

    var tableViewForTesting: NSTableView { tableView }
    var searchFieldForTesting: NSSearchField { searchField }
    var scrollViewForTesting: NSScrollView { scrollView }
    var progressIndicatorForTesting: NSProgressIndicator { progressIndicator }
    var connectButtonForTesting: NSButton { connectButton }
    var cancelButtonForTesting: NSButton { cancelButton }
    var rescanButtonForTesting: NSButton { rescanButton }
    var selectedIdentifierForTesting: UUID? { selectedIdentifier }
    var filteredDevicesForTesting: [BLEConsoleDiscoveredDevice] { filteredDevices }
    var statusTextForTesting: String { statusLabel.stringValue }
    var resultForTesting: ConsoleSessionConfig? { result }

    func rowModel(at index: Int) -> BLEConsoleScannerRowModel {
        BLEConsoleScannerRowModel(device: filteredDevices[index])
    }

    func applySnapshotForTesting(_ snapshot: BLEConsoleDiscoverySnapshot) {
        apply(snapshot)
    }

    func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        applyFilteredDevices()
    }

    func handleEventForTesting(_ event: BLEConsoleCentralEvent) {
        receive(event)
    }

    func selectDeviceForTesting(_ identifier: UUID?) {
        selectedIdentifier = identifier
        applyFilteredDevices()
        if let identifier,
           let row = filteredDevices.firstIndex(where: { $0.identifier == identifier }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func connectForTesting() { connectPressed(nil) }
    func cancelForTesting() { cancelPressed(nil) }
    func rescanForTesting() { rescanPressed(nil) }
    func handleKeyForTesting(keyCode: UInt16, command: Bool = false) {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: keyCode == 53 ? "\u{1b}" : (keyCode == 36 ? "\r" : "r"),
            charactersIgnoringModifiers: keyCode == 53 ? "\u{1b}" : (keyCode == 36 ? "\r" : "r"),
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        _ = handleKeyDown(event)
    }
}
