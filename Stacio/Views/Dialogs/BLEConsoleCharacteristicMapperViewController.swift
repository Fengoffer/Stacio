import AppKit
import StacioCoreBindings

/// A validated, user-selected GATT mapping for a device that is not in the
/// built-in BTerm profile catalog.
struct BLEConsoleCharacteristicMapping: Equatable, Sendable {
    let profile: ConsoleProfileMatch

    var serviceUUID: String { profile.serviceUuid }
    var txCharacteristicUUID: String { profile.txCharacteristicUuid }
    var rxCharacteristicUUID: String { profile.rxCharacteristicUuid }
    var writeType: String { profile.writeType }
}

@MainActor
final class BLEConsoleCharacteristicMapperViewController: NSViewController {
    private let deviceName: String
    private let services: [ConsoleServiceMetadata]
    private let servicePopup = NSPopUpButton()
    private let txPopup = NSPopUpButton()
    private let rxPopup = NSPopUpButton()
    private let writeTypePopup = NSPopUpButton()
    private let hintLabel = NSTextField(labelWithString: L10n.BLEConsole.scannerMapperHint)
    private let confirmButton = NSButton(title: L10n.BLEConsole.scannerConnect, target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.BLEConsole.scannerCancel, target: nil, action: nil)
    private var selectedServiceUUID: String?
    private var selectedTXUUID: String?
    private var selectedRXUUID: String?
    private var selectedWriteType = "without_response"
    private var result: ConsoleProfileMatch?

    var onConfirm: ((ConsoleProfileMatch) -> Void)?
    var onCancel: (() -> Void)?

    init(
        deviceName: String,
        services: [ConsoleServiceMetadata],
        initialSelection: ConsoleProfileMatch? = nil
    ) {
        self.deviceName = deviceName
        self.services = services
        selectedServiceUUID = initialSelection?.serviceUuid
        selectedTXUUID = initialSelection?.txCharacteristicUuid
        selectedRXUUID = initialSelection?.rxCharacteristicUuid
        selectedWriteType = initialSelection?.writeType ?? "without_response"
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        StacioDesignSystem.applyRootSurface(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.BLEConsole.CharacteristicMapper.surface")

        let title = NSTextField(labelWithString: L10n.BLEConsole.scannerProfileMapping)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let deviceLabel = NSTextField(labelWithString: deviceName)
        deviceLabel.font = .systemFont(ofSize: 12)
        deviceLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        deviceLabel.lineBreakMode = .byTruncatingTail
        deviceLabel.translatesAutoresizingMaskIntoConstraints = false
        deviceLabel.setAccessibilityIdentifier("Stacio.BLEConsole.CharacteristicMapper.device")

        configurePopup(servicePopup, identifier: "Stacio.BLEConsole.CharacteristicMapper.service")
        configurePopup(txPopup, identifier: "Stacio.BLEConsole.CharacteristicMapper.tx")
        configurePopup(rxPopup, identifier: "Stacio.BLEConsole.CharacteristicMapper.rx")
        configurePopup(writeTypePopup, identifier: "Stacio.BLEConsole.CharacteristicMapper.writeType")

        servicePopup.target = self
        servicePopup.action = #selector(serviceChanged(_:))
        txPopup.target = self
        txPopup.action = #selector(txChanged(_:))
        rxPopup.target = self
        rxPopup.action = #selector(rxChanged(_:))
        writeTypePopup.target = self
        writeTypePopup.action = #selector(writeTypeChanged(_:))

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.setAccessibilityIdentifier("Stacio.BLEConsole.CharacteristicMapper.hint")

        confirmButton.target = self
        confirmButton.action = #selector(confirmPressed(_:))
        confirmButton.keyEquivalent = "\r"
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.setAccessibilityIdentifier("Stacio.BLEConsole.CharacteristicMapper.confirm")
        StacioDesignSystem.styleSheetButton(confirmButton, isDefault: true)

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setAccessibilityIdentifier("Stacio.BLEConsole.CharacteristicMapper.cancel")
        StacioDesignSystem.styleSheetButton(cancelButton)

        let form = NSGridView(views: [
            [NSTextField(labelWithString: L10n.BLEConsole.scannerService), servicePopup],
            [NSTextField(labelWithString: L10n.BLEConsole.scannerTX), txPopup],
            [NSTextField(labelWithString: L10n.BLEConsole.scannerRX), rxPopup],
            [NSTextField(labelWithString: L10n.BLEConsole.scannerWriteType), writeTypePopup]
        ])
        form.rowSpacing = 10
        form.columnSpacing = 10
        form.column(at: 0).width = 148
        form.column(at: 0).xPlacement = .trailing
        form.translatesAutoresizingMaskIntoConstraints = false
        form.setAccessibilityIdentifier("Stacio.BLEConsole.CharacteristicMapper.form")
        for row in 0..<form.numberOfRows {
            let label = form.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField
            label?.textColor = StacioDesignSystem.theme.secondaryTextColor
        }

        let footer = NSStackView(views: [NSView(), cancelButton, confirmButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(deviceLabel)
        root.addSubview(form)
        root.addSubview(hintLabel)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            deviceLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            deviceLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            deviceLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            form.topAnchor.constraint(equalTo: deviceLabel.bottomAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            hintLabel.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 14),
            hintLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            confirmButton.widthAnchor.constraint(equalToConstant: 86),
            cancelButton.widthAnchor.constraint(equalToConstant: 86)
        ])

        view = root
        rebuildServices()
        updateChoices()
    }

    private func configurePopup(_ popup: NSPopUpButton, identifier: String) {
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setAccessibilityIdentifier(identifier)
        popup.setAccessibilityRole(.popUpButton)
    }

    private func rebuildServices() {
        servicePopup.removeAllItems()
        for service in services {
            let normalized = Self.normalizeUUID(service.uuid) ?? service.uuid.lowercased()
            servicePopup.addItem(withTitle: service.uuid)
            servicePopup.lastItem?.representedObject = normalized
        }
        guard !services.isEmpty else {
            selectedServiceUUID = nil
            return
        }
        let requested = selectedServiceUUID.flatMap(Self.normalizeUUID)
        let index = services.firstIndex {
            Self.normalizeUUID($0.uuid) == requested
        } ?? 0
        servicePopup.selectItem(at: index)
        selectedServiceUUID = Self.normalizeUUID(services[index].uuid)
    }

    @objc private func serviceChanged(_ sender: NSPopUpButton) {
        selectedServiceUUID = sender.selectedItem?.representedObject as? String
        selectedTXUUID = nil
        selectedRXUUID = nil
        updateChoices()
    }

    @objc private func txChanged(_ sender: NSPopUpButton) {
        selectedTXUUID = sender.selectedItem?.representedObject as? String
        updateWriteTypes()
        updateValidation()
    }

    @objc private func rxChanged(_ sender: NSPopUpButton) {
        selectedRXUUID = sender.selectedItem?.representedObject as? String
        updateValidation()
    }

    @objc private func writeTypeChanged(_ sender: NSPopUpButton) {
        selectedWriteType = sender.selectedItem?.representedObject as? String ?? "without_response"
        updateValidation()
    }

    private func updateChoices() {
        guard let service = selectedService else {
            txPopup.removeAllItems()
            rxPopup.removeAllItems()
            writeTypePopup.removeAllItems()
            updateValidation()
            return
        }

        let writable = service.characteristics.filter {
            $0.supportsWrite || $0.supportsWriteWithoutResponse
        }
        let readable = service.characteristics.filter {
            $0.supportsNotify || $0.supportsIndicate
        }
        rebuild(popup: txPopup, choices: writable.map(\.uuid), selected: selectedTXUUID)
        rebuild(popup: rxPopup, choices: readable.map(\.uuid), selected: selectedRXUUID)
        selectedTXUUID = txPopup.selectedItem?.representedObject as? String
        selectedRXUUID = rxPopup.selectedItem?.representedObject as? String
        updateWriteTypes()
        updateValidation()
    }

    private func rebuild(popup: NSPopUpButton, choices: [String], selected: String?) {
        popup.removeAllItems()
        for choice in choices {
            popup.addItem(withTitle: choice)
            popup.lastItem?.representedObject = Self.normalizeUUID(choice) ?? choice.lowercased()
        }
        guard !choices.isEmpty else { return }
        if let selected,
           let index = choices.firstIndex(where: { Self.normalizeUUID($0) == Self.normalizeUUID(selected) }) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
    }

    private func updateWriteTypes() {
        writeTypePopup.removeAllItems()
        guard let tx else {
            selectedWriteType = "without_response"
            updateValidation()
            return
        }
        if tx.supportsWriteWithoutResponse {
            writeTypePopup.addItem(withTitle: L10n.BLEConsole.scannerWithoutResponse)
            writeTypePopup.lastItem?.representedObject = "without_response"
        }
        if tx.supportsWrite {
            writeTypePopup.addItem(withTitle: L10n.BLEConsole.scannerWithResponse)
            writeTypePopup.lastItem?.representedObject = "with_response"
        }
        let desiredIndex = writeTypePopup.itemArray.firstIndex {
            ($0.representedObject as? String) == selectedWriteType
        } ?? 0
        if writeTypePopup.numberOfItems > 0 {
            writeTypePopup.selectItem(at: desiredIndex)
            selectedWriteType = writeTypePopup.selectedItem?.representedObject as? String ?? "without_response"
        }
    }

    private func updateValidation() {
        confirmButton.isEnabled = selectedProfile != nil
        if selectedTXUUID == nil {
            hintLabel.stringValue = L10n.BLEConsole.scannerNoWritableTX
        } else if selectedRXUUID == nil {
            hintLabel.stringValue = L10n.BLEConsole.scannerNoReadableRX
        } else {
            hintLabel.stringValue = L10n.BLEConsole.scannerMapperHint
        }
    }

    private var selectedService: ConsoleServiceMetadata? {
        guard let selectedServiceUUID else { return nil }
        return services.first { Self.normalizeUUID($0.uuid) == Self.normalizeUUID(selectedServiceUUID) }
    }

    private var tx: ConsoleCharacteristicMetadata? {
        guard let selectedTXUUID else { return nil }
        return selectedService?.characteristics.first {
            Self.normalizeUUID($0.uuid) == Self.normalizeUUID(selectedTXUUID)
        }
    }

    private var selectedProfile: ConsoleProfileMatch? {
        guard let service = selectedService,
              let tx,
              let rxUUID = selectedRXUUID,
              let normalizedService = Self.normalizeUUID(service.uuid),
              let normalizedTX = Self.normalizeUUID(tx.uuid),
              let normalizedRX = Self.normalizeUUID(rxUUID),
              tx.supportsWrite || tx.supportsWriteWithoutResponse,
              let rx = service.characteristics.first(where: {
                  Self.normalizeUUID($0.uuid) == normalizedRX
              }),
              rx.supportsNotify || rx.supportsIndicate,
              writeTypePopup.numberOfItems > 0
        else {
            return nil
        }
        return ConsoleProfileMatch(
            profileId: "custom-v1",
            serviceUuid: normalizedService,
            txCharacteristicUuid: normalizedTX,
            rxCharacteristicUuid: normalizedRX,
            writeType: selectedWriteType
        )
    }

    @objc private func confirmPressed(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        result = profile
        onConfirm?(profile)
    }

    @objc private func cancelPressed(_ sender: Any?) {
        onCancel?()
    }

    func runModal(parentWindow: NSWindow?) -> ConsoleProfileMatch? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.BLEConsole.scannerProfileMapping
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
        return response == .OK ? result : nil
    }

    var servicePopupForTesting: NSPopUpButton { servicePopup }
    var txPopupForTesting: NSPopUpButton { txPopup }
    var rxPopupForTesting: NSPopUpButton { rxPopup }
    var writeTypePopupForTesting: NSPopUpButton { writeTypePopup }
    var confirmButtonIsEnabledForTesting: Bool { confirmButton.isEnabled }
    var selectedProfileForTesting: ConsoleProfileMatch? { selectedProfile }

    func selectServiceForTesting(_ uuid: String) {
        guard let index = services.firstIndex(where: { Self.normalizeUUID($0.uuid) == Self.normalizeUUID(uuid) }) else { return }
        servicePopup.selectItem(at: index)
        serviceChanged(servicePopup)
    }

    func selectTXForTesting(_ uuid: String) {
        guard let index = txPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == Self.normalizeUUID(uuid) }) else { return }
        txPopup.selectItem(at: index)
        txChanged(txPopup)
    }

    func selectRXForTesting(_ uuid: String) {
        guard let index = rxPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == Self.normalizeUUID(uuid) }) else { return }
        rxPopup.selectItem(at: index)
        rxChanged(rxPopup)
    }

    func selectWriteTypeForTesting(_ value: String) {
        guard let index = writeTypePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == value }) else { return }
        writeTypePopup.selectItem(at: index)
        writeTypeChanged(writeTypePopup)
    }

    func confirmForTesting() {
        confirmPressed(nil)
    }

    func cancelForTesting() {
        cancelPressed(nil)
    }

    static func normalizeUUID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.allSatisfy { $0.isHexDigit }
        if (trimmed.count == 4 || trimmed.count == 8), hex {
            let prefix = trimmed.count == 4 ? "0000" : ""
            return "\(prefix)\(trimmed.lowercased())-0000-1000-8000-00805f9b34fb"
        }
        return UUID(uuidString: trimmed)?.uuidString.lowercased()
    }
}
