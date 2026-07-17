import AppKit
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class AppSettingsWindowControllerTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func assertAlignedSettingsGroups(
        _ groups: [NSView],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let first = groups.first else {
            return XCTFail("Expected at least one settings group", file: file, line: line)
        }
        for group in groups.dropFirst() {
            XCTAssertEqual(group.frame.minX, first.frame.minX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(group.frame.width, first.frame.width, accuracy: 1, file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(first.frame.width, 480, file: file, line: line)
    }

    private func frame(_ view: NSView, in root: NSView) -> NSRect {
        view.convert(view.bounds, to: root)
    }

    private func assertTextFieldContentVerticallyCentered(
        _ field: NSTextField,
        bounds: NSRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let cell = try XCTUnwrap(field.cell, file: file, line: line)
        let drawingRect = cell.drawingRect(forBounds: bounds)
        let titleRect = cell.titleRect(forBounds: bounds)
        XCTAssertEqual(drawingRect.midY, bounds.midY, accuracy: 0.25, file: file, line: line)
        XCTAssertEqual(titleRect.midY, bounds.midY, accuracy: 0.25, file: file, line: line)
        XCTAssertLessThanOrEqual(drawingRect.height, bounds.height, file: file, line: line)
        XCTAssertLessThanOrEqual(titleRect.height, bounds.height, file: file, line: line)

        let editEditor = NSTextView(frame: .zero)
        cell.edit(withFrame: bounds, in: field, editor: editEditor, delegate: nil, event: nil)
        XCTAssertEqual(editEditor.frame.midY, bounds.midY, accuracy: 0.25, file: file, line: line)
        XCTAssertLessThanOrEqual(editEditor.frame.height, bounds.height, file: file, line: line)

        let selectEditor = NSTextView(frame: .zero)
        cell.select(
            withFrame: bounds,
            in: field,
            editor: selectEditor,
            delegate: nil,
            start: 0,
            length: 0
        )
        XCTAssertEqual(selectEditor.frame.midY, bounds.midY, accuracy: 0.25, file: file, line: line)
        XCTAssertLessThanOrEqual(selectEditor.frame.height, bounds.height, file: file, line: line)
    }

    private func assertControlsShareFormColumn(
        _ first: NSView,
        _ second: NSView,
        in content: NSView,
        tolerance: CGFloat = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let firstFrame = frame(first, in: content)
        let secondFrame = frame(second, in: content)
        XCTAssertGreaterThan(firstFrame.minX, 0, file: file, line: line)
        XCTAssertGreaterThan(secondFrame.minX, 0, file: file, line: line)
        XCTAssertEqual(firstFrame.maxX, secondFrame.maxX, accuracy: tolerance, file: file, line: line)
    }

    private func assertControlColumnDoesNotFloatAway(
        row: NSView,
        label: NSView,
        control: NSView,
        group: NSView,
        content: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rowFrame = frame(row, in: content)
        let labelFrame = frame(label, in: content)
        let controlFrame = frame(control, in: content)
        let groupFrame = frame(group, in: content)
        XCTAssertLessThanOrEqual(rowFrame.minX - groupFrame.minX, 24, file: file, line: line)
        XCTAssertGreaterThan(controlFrame.minX, labelFrame.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(groupFrame.maxX - controlFrame.maxX, 24, file: file, line: line)
    }

    private func assertFormLabelMatchesControlTypographyAndCenter(
        label: NSTextField,
        control: NSControl,
        content: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualFontSize = label.font?.pointSize ?? -1
        let expectedFontSize = control.font?.pointSize ?? -2
        XCTAssertEqual(actualFontSize, expectedFontSize, accuracy: 0.1, file: file, line: line)

        let labelDrawingRect = label.cell?.drawingRect(forBounds: label.bounds) ?? label.bounds
        let labelTextMidY = label.convert(
            NSPoint(x: labelDrawingRect.midX, y: labelDrawingRect.midY),
            to: content
        ).y
        XCTAssertEqual(labelTextMidY, frame(control, in: content).midY, accuracy: 1.5, file: file, line: line)
    }

    private func assertSettingsFormPair(
        labelIdentifier: String,
        controlIdentifier: String,
        in content: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let label = try XCTUnwrap(
            content.firstSubview(withIdentifier: labelIdentifier) as? NSTextField,
            file: file,
            line: line
        )
        let control = try XCTUnwrap(
            content.firstSubview(withIdentifier: controlIdentifier) as? NSControl,
            file: file,
            line: line
        )
        assertFormLabelMatchesControlTypographyAndCenter(
            label: label,
            control: control,
            content: content,
            file: file,
            line: line
        )
    }

    private func settingsRows(
        in content: NSView,
        listIdentifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [NSView] {
        try settingsListStack(
            in: content,
            listIdentifier: listIdentifier,
            file: file,
            line: line
        ).arrangedSubviews.filter {
            $0.accessibilityIdentifier() != "Stacio.Settings.groupRowSeparator"
        }
    }

    private func settingsListStack(
        in content: NSView,
        listIdentifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSStackView {
        let list = try XCTUnwrap(
            content.firstSubview(withIdentifier: listIdentifier),
            file: file,
            line: line
        )
        return try XCTUnwrap(
            list.subviews.compactMap { $0 as? NSStackView }.first,
            file: file,
            line: line
        )
    }

    private func settingsRowIndex(
        containing identifier: String,
        in rows: [NSView],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        try XCTUnwrap(
            rows.firstIndex { $0.firstSubview(withIdentifier: identifier) != nil },
            file: file,
            line: line
        )
    }

    private func assertSettingsPreferenceRow(
        identifier: String,
        title: String,
        detail: String,
        in content: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let row = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.preferenceRow.\(identifier)") as? NSStackView,
            file: file,
            line: line
        )
        let titleLabel = try XCTUnwrap(
            row.firstSubview(withIdentifier: "Stacio.Settings.preferenceTitle.\(identifier)") as? NSTextField,
            file: file,
            line: line
        )
        let detailLabel = try XCTUnwrap(
            row.firstSubview(withIdentifier: "Stacio.Settings.preferenceHelp.\(identifier)") as? NSTextField,
            file: file,
            line: line
        )
        XCTAssertEqual(titleLabel.stringValue, title, file: file, line: line)
        XCTAssertEqual(detailLabel.stringValue, detail, file: file, line: line)
        XCTAssertFalse(
            titleLabel.font?.fontDescriptor.symbolicTraits.contains(.bold) == true,
            file: file,
            line: line
        )
        XCTAssertEqual(detailLabel.maximumNumberOfLines, 0, file: file, line: line)
    }

    private func assertTerminalPreferenceRowLayout(
        identifier: String,
        controlIdentifier: String,
        in content: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let row = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.preferenceRow.\(identifier)") as? NSStackView,
            file: file,
            line: line
        )
        let topRow = try XCTUnwrap(
            row.firstSubview(withIdentifier: "Stacio.Settings.preferenceTopRow.\(identifier)") as? NSStackView,
            file: file,
            line: line
        )
        let titleLabel = try XCTUnwrap(
            row.firstSubview(withIdentifier: "Stacio.Settings.preferenceTitle.\(identifier)") as? NSTextField,
            file: file,
            line: line
        )
        let detailLabel = try XCTUnwrap(
            row.firstSubview(withIdentifier: "Stacio.Settings.preferenceHelp.\(identifier)") as? NSTextField,
            file: file,
            line: line
        )
        let control = try XCTUnwrap(
            content.firstSubview(withIdentifier: controlIdentifier),
            file: file,
            line: line
        )
        let rowFrame = frame(row, in: content)
        let titleFrame = frame(titleLabel, in: content)
        let detailFrame = frame(detailLabel, in: content)
        let controlFrame = frame(control, in: content)

        XCTAssertEqual(row.orientation, .vertical, file: file, line: line)
        XCTAssertEqual(topRow.orientation, .horizontal, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rowFrame.width, 460, file: file, line: line)
        XCTAssertGreaterThanOrEqual(detailFrame.width, 440, file: file, line: line)
        XCTAssertGreaterThan(controlFrame.minX, titleFrame.maxX, file: file, line: line)
        XCTAssertEqual(controlFrame.midY, titleFrame.midY, accuracy: 18, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(detailFrame.minX - rowFrame.minX), 10, file: file, line: line)
        XCTAssertLessThanOrEqual(detailFrame.maxX, rowFrame.maxX + 10, file: file, line: line)
        XCTAssertLessThanOrEqual(controlFrame.maxX, rowFrame.maxX + 10, file: file, line: line)
    }

    private func selectSettingsSection(_ identifier: String, in content: NSView) throws {
        let navigationButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.\(identifier)") as? NSButton
        )
        navigationButton.performClick(nil)
        content.layoutSubtreeIfNeeded()
    }

    private func selectAISettingsTab(_ title: String, in content: NSView) throws {
        let tabControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.aiTabs.control") as? NSSegmentedControl
        )
        let matchingSegment = (0..<tabControl.segmentCount).first {
            tabControl.label(forSegment: $0) == title
        }
        let segment = try XCTUnwrap(matchingSegment)
        tabControl.selectedSegment = segment
        tabControl.sendAction(tabControl.action, to: tabControl.target)
        content.layoutSubtreeIfNeeded()
    }

    private func assertSettingsNavigationSelectedStyle(
        _ button: NSButton,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(button.state, .on, file: file, line: line)
        XCTAssertTrue(button.wantsLayer, file: file, line: line)
        XCTAssertNotNil(button.layer?.backgroundColor, file: file, line: line)
        XCTAssertEqual(button.layer?.borderWidth ?? 0, 0, accuracy: 0.1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.layer?.cornerRadius ?? 0, 8.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.font?.pointSize ?? 0, 14.5, file: file, line: line)
    }

    private func assertSettingsNavigationUnselectedStyle(
        _ button: NSButton,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(button.state, .off, file: file, line: line)
        XCTAssertTrue(button.wantsLayer, file: file, line: line)
        XCTAssertNil(button.layer?.backgroundColor, file: file, line: line)
        XCTAssertEqual(button.layer?.borderWidth ?? 0, 0, accuracy: 0.1, file: file, line: line)
        XCTAssertFalse(
            button.font?.fontDescriptor.symbolicTraits.contains(.bold) == true,
            file: file,
            line: line
        )
    }

    func testSettingsWindowUsesChineseLabelsAndPersistsTerminalPreferences() throws {
        let suiteName = "StacioSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let fontSizeField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.fontSize") as? NSTextField
        )
        let closeConfirmationButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalCloseConfirmation") as? NSButton
        )

        XCTAssertEqual(controller.window?.title, "设置")
        XCTAssertFalse(controller.window?.titlebarAppearsTransparent ?? true)
        XCTAssertEqual(controller.window?.toolbarStyle, .automatic)
        XCTAssertEqual(content.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual(content.layer?.borderWidth ?? 0, 0)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.terminalTitle"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.nav.terminalTheme"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.theme"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalThemeLibrary"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.terminalThemeGallery"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.importTerminalTheme"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.terminalPreview"))
        XCTAssertEqual(closeConfirmationButton.title, "关闭终端前确认")
        XCTAssertEqual(closeConfirmationButton.state, .on)
        XCTAssertFalse(fontSizeField.isBordered)
        XCTAssertFalse(fontSizeField.isBezeled)
        XCTAssertEqual(fontSizeField.focusRingType, .default)
        XCTAssertTrue(fontSizeField.wantsLayer)
        XCTAssertNotNil(fontSizeField.layer?.backgroundColor)
        XCTAssertEqual(fontSizeField.layer?.borderWidth ?? -1, 0, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(fontSizeField.layer?.cornerRadius ?? 0, 5.5)
        XCTAssertEqual(fontSizeField.controlSize, .regular)
        XCTAssertLessThanOrEqual(frame(fontSizeField, in: content).width, 61)
        XCTAssertEqual(frame(fontSizeField, in: content).height, 24, accuracy: 0.5)
        XCTAssertEqual(fontSizeField.fittingSize.height, 24, accuracy: 1)
        let fontSizeContentRect = try XCTUnwrap(fontSizeField.cell?.drawingRect(
            forBounds: NSRect(x: 0, y: 0, width: 59, height: 24)
        ))
        XCTAssertGreaterThanOrEqual(fontSizeContentRect.minX, 6)
        XCTAssertLessThanOrEqual(fontSizeContentRect.minX, 9)
        XCTAssertEqual(fontSizeContentRect.midY, 12, accuracy: 0.25)
        try assertTextFieldContentVerticallyCentered(
            fontSizeField,
            bounds: NSRect(x: 0, y: 0, width: 59, height: 24)
        )
        try assertTextFieldContentVerticallyCentered(
            fontSizeField,
            bounds: NSRect(x: 0, y: 0, width: 59, height: 32)
        )

        fontSizeField.stringValue = "16"
        fontSizeField.sendAction(fontSizeField.action, to: fontSizeField.target)
        closeConfirmationButton.performClick(nil)

        XCTAssertEqual(store.snapshot().terminalFontSize, 16)
        XCTAssertFalse(store.snapshot().terminalCloseConfirmationEnabled)
    }

    func testUpdateChannelLivesInRegularSettingsAndRequiresConfirmation() throws {
        let appSuiteName = "StacioSettingsUpdateChannelTests-App-\(UUID().uuidString)"
        let productSuiteName = "StacioSettingsUpdateChannelTests-Product-\(UUID().uuidString)"
        let appDefaults = try XCTUnwrap(UserDefaults(suiteName: appSuiteName))
        let productDefaults = try XCTUnwrap(UserDefaults(suiteName: productSuiteName))
        defer {
            appDefaults.removePersistentDomain(forName: appSuiteName)
            productDefaults.removePersistentDomain(forName: productSuiteName)
        }
        let productStore = ProductOpsConfigurationStore(
            defaults: productDefaults,
            environment: [:],
            bundleInfo: [
                ProductOpsConfigurationStore.Key.updateChannel: ProductOpsReleaseChannel.stable.rawValue,
                ProductOpsConfigurationStore.Key.betaUpdatesEnabled: false
            ]
        )
        let confirmer = RecordingUpdateChannelConfirmation(decisions: [false, true])
        let controller = AppSettingsWindowController(
            settingsStore: AppSettingsStore(defaults: appDefaults),
            productOpsConfigurationStore: productStore,
            updateChannelConfirmation: confirmer
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)

        try selectSettingsSection("updates", in: content)
        let channel = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.updateChannel") as? NSSegmentedControl
        )
        XCTAssertNil(content.firstTextField(containing: "Product Ops"))
        XCTAssertEqual((0..<channel.segmentCount).map { channel.label(forSegment: $0) }, ["Stable", "Beta"])
        XCTAssertEqual(channel.selectedSegment, 0)

        channel.selectedSegment = 1
        channel.sendAction(channel.action, to: channel.target)
        XCTAssertEqual(productStore.load().effectiveUpdateChannel, .stable)
        XCTAssertEqual(channel.selectedSegment, 0)

        channel.selectedSegment = 1
        channel.sendAction(channel.action, to: channel.target)
        XCTAssertEqual(productStore.load().effectiveUpdateChannel, .beta)
        XCTAssertEqual(channel.selectedSegment, 1)
        XCTAssertEqual(confirmer.requestedChanges, [.init(from: .stable, to: .beta), .init(from: .stable, to: .beta)])
    }

    func testTerminalThemeSettingsExposeCustomThemeImportControls() throws {
        let suiteName = "StacioTerminalThemeImportSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.terminalTheme = .custom
            settings.customTerminalTheme = TerminalColorTheme(
                name: "Catppuccin Mocha",
                sourceFormat: .kitty,
                foregroundHex: "#CDD6F4",
                backgroundHex: "#1E1E2E",
                cursorHex: "#F5E0DC",
                selectionBackgroundHex: "#45475A",
                ansiColorHexes: [
                    "#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF",
                    "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                    "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF",
                    "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"
                ]
            )
        }
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("terminalTheme", in: content)

        let themeControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.theme") as? NSSegmentedControl
        )
        let importButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.importTerminalTheme") as? NSButton
        )
        let customThemeSummary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.customTerminalThemeSummary") as? NSTextField
        )

        XCTAssertEqual(themeControl.selectedSegment, 3)
        XCTAssertEqual(importButton.title, "导入主题...")
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.exportTerminalTheme"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.resetTerminalTheme"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.customTerminalThemeEditor"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.customTheme.name"))
        XCTAssertTrue(customThemeSummary.stringValue.contains("Catppuccin Mocha"))
        XCTAssertTrue(customThemeSummary.stringValue.contains("Kitty"))
    }

    func testSettingsPersistsTerminalInteractionPreferences() throws {
        let suiteName = "StacioTerminalInteractionSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let autoCopyButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalSelectionAutoCopy") as? NSButton
        )
        let rightClickControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalRightClickBehavior") as? NSSegmentedControl
        )
        let controlScrollZoomButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalControlScrollZoom") as? NSButton
        )
        let completionNotificationButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalCommandCompletionNotificationEnabled") as? NSButton
        )
        let completionThresholdField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalCommandCompletionNotificationThresholdSeconds") as? NSTextField
        )
        let commandSuggestionButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalCommandSuggestionEnabled") as? NSButton
        )
        let commandSuggestionMinLengthField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalCommandSuggestionHistoryMinLength") as? NSTextField
        )
        let commandSuggestionMaxLengthField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalCommandSuggestionHistoryMaxLength") as? NSTextField
        )
        let commandSuggestionWordSeparatorsField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalCommandSuggestionWordSeparators") as? NSTextField
        )
        let duplicateSessionCommandDelayField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalDuplicateSessionCommandDelayMilliseconds") as? NSTextField
        )
        let scrollbackField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalScrollbackLines") as? NSTextField
        )
        let keepAliveField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalKeepAliveIntervalSeconds") as? NSTextField
        )
        let x11DisplayField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalX11Display") as? NSTextField
        )
        let lineNumbersButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalLineNumbers") as? NSButton
        )
        let timestampsButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalTimestamps") as? NSButton
        )
        let multiLinePasteButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalMultiLinePasteConfirmation") as? NSButton
        )
        let pasteImageAsPathButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalPasteImageAsPath") as? NSButton
        )
        let altAsMetaButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalAltAsMeta") as? NSButton
        )

        XCTAssertEqual(autoCopyButton.title, "选中自动复制")
        XCTAssertEqual(autoCopyButton.state, .on)
        XCTAssertEqual(rightClickControl.segmentCount, 3)
        XCTAssertEqual(rightClickControl.label(forSegment: 0), "粘贴")
        XCTAssertEqual(rightClickControl.label(forSegment: 1), "菜单")
        XCTAssertEqual(rightClickControl.label(forSegment: 2), "无操作")
        XCTAssertEqual(rightClickControl.selectedSegment, 0)
        XCTAssertEqual(controlScrollZoomButton.title, "Ctrl 滚轮缩放字体")
        XCTAssertEqual(controlScrollZoomButton.state, .on)
        XCTAssertEqual(completionNotificationButton.title, "长命令结束后通知")
        XCTAssertEqual(completionNotificationButton.state, .on)
        XCTAssertEqual(completionThresholdField.stringValue, "5")
        XCTAssertEqual(commandSuggestionButton.title, "联想补全")
        XCTAssertEqual(commandSuggestionButton.state, .on)
        XCTAssertEqual(commandSuggestionMinLengthField.stringValue, "2")
        XCTAssertEqual(commandSuggestionMaxLengthField.stringValue, "64")
        XCTAssertEqual(commandSuggestionWordSeparatorsField.stringValue, AppSettings.defaultTerminalCommandSuggestionWordSeparators)
        XCTAssertEqual(duplicateSessionCommandDelayField.stringValue, "1000")
        XCTAssertEqual(scrollbackField.stringValue, "10000")
        XCTAssertEqual(keepAliveField.stringValue, "60")
        XCTAssertEqual(x11DisplayField.stringValue, "")
        try assertSettingsPreferenceRow(
            identifier: "terminalScrollbackLines",
            title: "滚动缓冲行数",
            detail: "保留可回滚查看的历史输出行数；数值越大，长时间会话可查看的内容越多。",
            in: content
        )
        try assertSettingsPreferenceRow(
            identifier: "terminalKeepAliveIntervalSeconds",
            title: "保活间隔（秒）",
            detail: "SSH 空闲时发送保活探测，降低网络设备断开连接的概率；设为 0 表示关闭。",
            in: content
        )
        try assertSettingsPreferenceRow(
            identifier: "terminalX11Display",
            title: "X11 DISPLAY",
            detail: "为需要 X11 转发的远程程序指定 DISPLAY；macOS 通常需要先启动 XQuartz。",
            in: content
        )
        try assertSettingsPreferenceRow(
            identifier: "terminalHardwareAcceleration",
            title: "硬件加速",
            detail: "使用 GPU 加速终端绘制，提升高频输出和大屏滚动时的渲染流畅度。",
            in: content
        )
        try assertSettingsPreferenceRow(
            identifier: "terminalLineNumbers",
            title: "显示行号",
            detail: "在终端左侧显示输出行号，便于定位日志、错误堆栈和 AI 引用的行。",
            in: content
        )
        try assertSettingsPreferenceRow(
            identifier: "terminalMacIMECompatibility",
            title: "macOS 输入法兼容",
            detail: "优化中文等输入法的组合输入流程，减少候选词确认和终端快捷键之间的冲突。",
            in: content
        )
        XCTAssertEqual(lineNumbersButton.title, "显示行号")
        XCTAssertEqual(timestampsButton.title, "显示时间戳")
        XCTAssertEqual(multiLinePasteButton.state, .on)
        XCTAssertEqual(pasteImageAsPathButton.state, .on)

        autoCopyButton.performClick(nil)
        rightClickControl.selectedSegment = 1
        rightClickControl.sendAction(rightClickControl.action, to: rightClickControl.target)
        controlScrollZoomButton.performClick(nil)
        completionNotificationButton.performClick(nil)
        completionThresholdField.stringValue = "9"
        completionThresholdField.sendAction(completionThresholdField.action, to: completionThresholdField.target)
        commandSuggestionButton.performClick(nil)
        commandSuggestionMinLengthField.stringValue = "3"
        commandSuggestionMinLengthField.sendAction(commandSuggestionMinLengthField.action, to: commandSuggestionMinLengthField.target)
        commandSuggestionMaxLengthField.stringValue = "72"
        commandSuggestionMaxLengthField.sendAction(commandSuggestionMaxLengthField.action, to: commandSuggestionMaxLengthField.target)
        commandSuggestionWordSeparatorsField.stringValue = "()[]{}"
        commandSuggestionWordSeparatorsField.sendAction(
            commandSuggestionWordSeparatorsField.action,
            to: commandSuggestionWordSeparatorsField.target
        )
        duplicateSessionCommandDelayField.stringValue = "750"
        duplicateSessionCommandDelayField.sendAction(
            duplicateSessionCommandDelayField.action,
            to: duplicateSessionCommandDelayField.target
        )
        scrollbackField.stringValue = "25000"
        scrollbackField.sendAction(scrollbackField.action, to: scrollbackField.target)
        keepAliveField.stringValue = "15"
        keepAliveField.sendAction(keepAliveField.action, to: keepAliveField.target)
        x11DisplayField.stringValue = " :10 "
        x11DisplayField.sendAction(x11DisplayField.action, to: x11DisplayField.target)
        lineNumbersButton.performClick(nil)
        timestampsButton.performClick(nil)
        multiLinePasteButton.performClick(nil)
        pasteImageAsPathButton.performClick(nil)
        altAsMetaButton.performClick(nil)

        let snapshot = store.snapshot()
        XCTAssertFalse(snapshot.terminalSelectionAutoCopyEnabled)
        XCTAssertEqual(snapshot.terminalRightClickBehavior, .contextMenu)
        XCTAssertFalse(snapshot.terminalControlScrollZoomEnabled)
        XCTAssertFalse(snapshot.terminalCommandCompletionNotificationEnabled)
        XCTAssertEqual(snapshot.terminalCommandCompletionNotificationThresholdSeconds, 9)
        XCTAssertFalse(snapshot.terminalCommandSuggestionEnabled)
        XCTAssertEqual(snapshot.terminalCommandSuggestionHistoryMinLength, 3)
        XCTAssertEqual(snapshot.terminalCommandSuggestionHistoryMaxLength, 72)
        XCTAssertEqual(snapshot.terminalCommandSuggestionWordSeparators, "()[]{}")
        XCTAssertEqual(snapshot.terminalDuplicateSessionCommandDelayMilliseconds, 750)
        XCTAssertEqual(snapshot.terminalScrollbackLines, 25_000)
        XCTAssertEqual(snapshot.terminalKeepAliveIntervalSeconds, 15)
        XCTAssertEqual(snapshot.terminalX11Display, ":10")
        XCTAssertTrue(snapshot.terminalLineNumbersEnabled)
        XCTAssertTrue(snapshot.terminalTimestampsEnabled)
        XCTAssertFalse(snapshot.terminalMultiLinePasteConfirmationEnabled)
        XCTAssertFalse(snapshot.terminalPasteImageAsPathEnabled)
        XCTAssertTrue(snapshot.terminalAltAsMetaEnabled)
    }

    func testSettingsPersistsTerminalFontAndCursorPreferences() throws {
        let suiteName = "StacioTerminalFontCursorSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let fontFamilyPopup = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalFontFamily") as? NSPopUpButton
        )
        let cursorStyleControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalCursorStyle") as? NSSegmentedControl
        )
        let cursorBlinkButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalCursorBlink") as? NSButton
        )
        let highlightLevelControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalHighlightLevel") as? NSSegmentedControl
        )
        let richHighlightingButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalRichHighlighting") as? NSButton
        )

        XCTAssertEqual(fontFamilyPopup.titleOfSelectedItem, "SF Mono")
        XCTAssertTrue(fontFamilyPopup.itemTitles.contains("Menlo"))
        XCTAssertTrue(fontFamilyPopup.itemTitles.contains("JetBrains Mono"))
        XCTAssertTrue(fontFamilyPopup.itemTitles.contains("Fira Code"))
        XCTAssertTrue(fontFamilyPopup.itemTitles.contains("Hack"))
        XCTAssertTrue(fontFamilyPopup.itemTitles.contains("Source Code Pro"))
        XCTAssertTrue(fontFamilyPopup.itemTitles.contains("Cascadia Code"))
        XCTAssertEqual(cursorStyleControl.segmentCount, 3)
        XCTAssertEqual(cursorStyleControl.label(forSegment: 0), "块")
        XCTAssertEqual(cursorStyleControl.label(forSegment: 1), "竖线")
        XCTAssertEqual(cursorStyleControl.label(forSegment: 2), "下划线")
        XCTAssertEqual(cursorBlinkButton.title, "光标闪烁")
        XCTAssertEqual(cursorBlinkButton.state, .on)
        XCTAssertEqual(highlightLevelControl.segmentCount, 3)
        XCTAssertEqual(highlightLevelControl.label(forSegment: 0), "关闭")
        XCTAssertEqual(highlightLevelControl.label(forSegment: 1), "ANSI")
        XCTAssertEqual(highlightLevelControl.label(forSegment: 2), "命令增强")
        XCTAssertEqual(highlightLevelControl.selectedSegment, 2)
        XCTAssertEqual(richHighlightingButton.title, "丰富高亮")
        XCTAssertEqual(richHighlightingButton.state, .on)
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.theme"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.terminalHighlightTheme"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.customTerminalThemeSummary"))

        fontFamilyPopup.selectItem(withTitle: "JetBrains Mono")
        fontFamilyPopup.sendAction(fontFamilyPopup.action, to: fontFamilyPopup.target)
        highlightLevelControl.selectedSegment = 2
        highlightLevelControl.sendAction(highlightLevelControl.action, to: highlightLevelControl.target)
        richHighlightingButton.performClick(nil)
        cursorStyleControl.selectedSegment = 1
        cursorStyleControl.sendAction(cursorStyleControl.action, to: cursorStyleControl.target)
        cursorBlinkButton.performClick(nil)

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.terminalFontFamily, .jetBrainsMono)
        XCTAssertEqual(snapshot.terminalHighlightLevel, .commandLineEnhanced)
        XCTAssertFalse(snapshot.terminalRichHighlightingEnabled)
        XCTAssertEqual(snapshot.terminalCursorShape, .bar)
        XCTAssertFalse(snapshot.terminalCursorBlinkEnabled)
    }

    func testTerminalHighlightHelpStaysWithHighlightLevelControl() throws {
        let suiteName = "StacioTerminalHighlightHelpLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppSettingsWindowController(settingsStore: AppSettingsStore(defaults: defaults))

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let rows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.terminalAppearance.rows"
        )

        let sessionIconIndex = try settingsRowIndex(
            containing: "Stacio.Settings.sessionTabIconMode",
            in: rows
        )
        let sessionIconHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.sessionTabIconModeHelp",
            in: rows
        )
        let highlightIndex = try settingsRowIndex(
            containing: "Stacio.Settings.terminalHighlightLevel",
            in: rows
        )
        let helpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.terminalHighlightHelp",
            in: rows
        )
        XCTAssertEqual(sessionIconHelpIndex, sessionIconIndex)
        XCTAssertEqual(helpIndex, highlightIndex)
        XCTAssertLessThan(
            helpIndex,
            try settingsRowIndex(containing: "Stacio.Settings.terminalRichHighlighting", in: rows)
        )
        XCTAssertLessThan(
            helpIndex,
            try settingsRowIndex(containing: "Stacio.Settings.terminalCursorStyle", in: rows)
        )
        XCTAssertLessThan(
            helpIndex,
            try settingsRowIndex(containing: "Stacio.Settings.terminalCursorBlink", in: rows)
        )
    }

    func testTerminalCommandSuggestionHelpStaysWithSuggestionToggle() throws {
        let suiteName = "StacioTerminalSuggestionHelpLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppSettingsWindowController(settingsStore: AppSettingsStore(defaults: defaults))

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let rows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.terminalCommandInput.rows"
        )

        let suggestionIndex = try settingsRowIndex(
            containing: "Stacio.Settings.terminalCommandSuggestionEnabled",
            in: rows
        )
        let helpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.terminalCommandSuggestionHelp",
            in: rows
        )
        let historyMinimumIndex = try settingsRowIndex(
            containing: "Stacio.Settings.terminalCommandSuggestionHistoryMinLength",
            in: rows
        )
        XCTAssertEqual(helpIndex, suggestionIndex)
        XCTAssertLessThan(helpIndex, historyMinimumIndex)

        let listStack = try settingsListStack(
            in: content,
            listIdentifier: "Stacio.Settings.group.terminalCommandInput.rows"
        )
        let suggestionItem = try XCTUnwrap(
            listStack.arrangedSubviews.first {
                $0.accessibilityIdentifier() != "Stacio.Settings.groupRowSeparator"
                    && $0.firstSubview(withIdentifier: "Stacio.Settings.terminalCommandSuggestionEnabled") != nil
            }
        )
        let helpItem = try XCTUnwrap(
            listStack.arrangedSubviews.first {
                $0.accessibilityIdentifier() != "Stacio.Settings.groupRowSeparator"
                    && $0.firstSubview(withIdentifier: "Stacio.Settings.terminalCommandSuggestionHelp") != nil
            }
        )
        XCTAssertTrue(suggestionItem === helpItem)

        let suggestionItemIndex = try XCTUnwrap(
            listStack.arrangedSubviews.firstIndex { $0 === suggestionItem }
        )
        XCTAssertEqual(
            listStack.arrangedSubviews[suggestionItemIndex + 1].accessibilityIdentifier(),
            "Stacio.Settings.groupRowSeparator"
        )
        XCTAssertNotNil(
            listStack.arrangedSubviews[suggestionItemIndex + 2].firstSubview(
                withIdentifier: "Stacio.Settings.terminalCommandSuggestionHistoryMinLength"
            )
        )
    }

    func testTerminalRichHighlightingHelpStaysWithToggle() throws {
        let suiteName = "StacioTerminalRichHighlightHelpLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppSettingsWindowController(settingsStore: AppSettingsStore(defaults: defaults))

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let rows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.terminalAppearance.rows"
        )

        let richHighlightingIndex = try settingsRowIndex(
            containing: "Stacio.Settings.terminalRichHighlighting",
            in: rows
        )
        let helpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.terminalRichHighlightingHelp",
            in: rows
        )
        XCTAssertEqual(helpIndex, richHighlightingIndex)
        XCTAssertLessThan(
            helpIndex,
            try settingsRowIndex(containing: "Stacio.Settings.terminalCursorStyle", in: rows)
        )
    }

    func testTerminalThemeImportHintStaysWithImportAction() throws {
        let suiteName = "StacioTerminalThemeImportHintLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppSettingsWindowController(settingsStore: AppSettingsStore(defaults: defaults))

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("terminalTheme", in: content)
        content.layoutSubtreeIfNeeded()
        let rows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.terminalThemeLibrary.rows"
        )

        let importIndex = try settingsRowIndex(
            containing: "Stacio.Settings.importTerminalTheme",
            in: rows
        )
        let hintIndex = try settingsRowIndex(
            containing: "Stacio.Settings.terminalThemeImportHint",
            in: rows
        )
        XCTAssertEqual(hintIndex, importIndex)
    }

    func testAIExecutionHelpRowsStayWithRelatedControls() throws {
        let suiteName = "StacioAIExecutionHelpLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppSettingsWindowController(settingsStore: AppSettingsStore(defaults: defaults))

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("ai", in: content)
        try selectAISettingsTab("执行与权限", in: content)
        content.layoutSubtreeIfNeeded()
        let rows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.aiExecution.rows"
        )

        let patternFieldsIndex = try settingsRowIndex(
            containing: "Stacio.Settings.agentCommandDenyPatterns",
            in: rows
        )
        let patternHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.agentCommandPatternHelp",
            in: rows
        )
        let riskMatrixIndex = try settingsRowIndex(
            containing: "Stacio.Settings.agentApprovalRiskMatrix",
            in: rows
        )
        let autoRunIndex = try settingsRowIndex(
            containing: "Stacio.Settings.aiAutoRunProposedCommands",
            in: rows
        )
        let executionHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.aiExecutionHelp",
            in: rows
        )
        XCTAssertEqual(patternHelpIndex, patternFieldsIndex)
        XCTAssertEqual(riskMatrixIndex, patternHelpIndex + 1)
        XCTAssertEqual(executionHelpIndex, autoRunIndex)
    }

    func testSecurityHelpRowsStayWithRelatedControls() throws {
        let suiteName = "StacioSecurityHelpLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppSettingsWindowController(settingsStore: AppSettingsStore(defaults: defaults))

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("security", in: content)
        content.layoutSubtreeIfNeeded()

        let approvalRows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.securityApproval.rows"
        )
        let policyFieldsIndex = try settingsRowIndex(
            containing: "Stacio.Settings.securityAgentCommandDenyPatterns",
            in: approvalRows
        )
        let policyHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.securityCommandPolicyHelp",
            in: approvalRows
        )
        let approvalMatrixIndex = try settingsRowIndex(
            containing: "Stacio.Settings.securityApprovalRiskMatrix",
            in: approvalRows
        )
        XCTAssertEqual(policyHelpIndex, policyFieldsIndex)
        XCTAssertEqual(approvalMatrixIndex, policyHelpIndex + 1)

        let auditRows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.securityAudit.rows"
        )
        let exportFieldsIndex = try settingsRowIndex(
            containing: "Stacio.Settings.diagnosticsAppLogLineLimit",
            in: auditRows
        )
        let exportHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.diagnosticsExportLimitHelp",
            in: auditRows
        )
        let includeLogsIndex = try settingsRowIndex(
            containing: "Stacio.Settings.diagnosticsIncludeAppLogs",
            in: auditRows
        )
        let auditHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.securityAuditHelp",
            in: auditRows
        )
        XCTAssertEqual(exportHelpIndex, exportFieldsIndex)
        XCTAssertEqual(includeLogsIndex, exportHelpIndex + 1)
        XCTAssertEqual(auditHelpIndex, includeLogsIndex)
    }

    func testMetricsHelpRowsStayWithRelatedControls() throws {
        let suiteName = "StacioMetricsHelpLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppSettingsWindowController(settingsStore: AppSettingsStore(defaults: defaults))

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("metrics", in: content)
        content.layoutSubtreeIfNeeded()

        let collectionRows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.metricsCollection.rows"
        )
        let refreshIntervalIndex = try settingsRowIndex(
            containing: "Stacio.Settings.deviceMetricsRefreshIntervalSeconds",
            in: collectionRows
        )
        let refreshHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.metricsRefreshHelp",
            in: collectionRows
        )
        let keepLastIndex = try settingsRowIndex(
            containing: "Stacio.Settings.deviceMetricsKeepLastSnapshotOnFailure",
            in: collectionRows
        )
        XCTAssertEqual(refreshHelpIndex, refreshIntervalIndex)
        XCTAssertEqual(keepLastIndex, refreshHelpIndex + 1)

        let displayRows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.metricsDisplay.rows"
        )
        let showDiskIndex = try settingsRowIndex(
            containing: "Stacio.Settings.deviceMetricsShowDiskSection",
            in: displayRows
        )
        let moduleHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.metricsModuleVisibilityHelp",
            in: displayRows
        )
        let historyLimitIndex = try settingsRowIndex(
            containing: "Stacio.Settings.deviceMetricsHistorySampleCount",
            in: displayRows
        )
        let limitsHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.metricsDisplayLimitsHelp",
            in: displayRows
        )
        XCTAssertEqual(moduleHelpIndex, showDiskIndex)
        XCTAssertEqual(limitsHelpIndex, historyLimitIndex)

        let compatibilityRows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.metricsCompatibility.rows"
        )
        XCTAssertEqual(
            try settingsRowIndex(containing: "Stacio.Settings.metricsCompatibilityHelp", in: compatibilityRows),
            0
        )
        XCTAssertEqual(
            try settingsRowIndex(
                containing: "Stacio.Settings.deviceMetricsHideVirtualNetworkInterfaces",
                in: compatibilityRows
            ),
            1
        )

        let alertsRows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.metricsAlerts.rows"
        )
        let alertEnabledIndex = try settingsRowIndex(
            containing: "Stacio.Settings.deviceMetricsAlertEnabled",
            in: alertsRows
        )
        let notificationHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.metricsAlertNotificationHelp",
            in: alertsRows
        )
        let consecutiveIndex = try settingsRowIndex(
            containing: "Stacio.Settings.deviceMetricsAlertConsecutiveRefreshCount",
            in: alertsRows
        )
        let thresholdHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.metricsAlertThresholdHelp",
            in: alertsRows
        )
        XCTAssertEqual(notificationHelpIndex, alertEnabledIndex)
        XCTAssertEqual(thresholdHelpIndex, consecutiveIndex)
    }

    func testCredentialCenterHelpRowsStayWithRelatedControls() throws {
        let suiteName = "StacioCredentialCenterHelpLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppSettingsWindowController(settingsStore: AppSettingsStore(defaults: defaults))

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("security", in: content)
        content.layoutSubtreeIfNeeded()
        let rows = try settingsRows(
            in: content,
            listIdentifier: "Stacio.Settings.group.credentialCenter.rows"
        )

        let listActionsIndex = try settingsRowIndex(
            containing: "Stacio.Settings.credentialCenterList",
            in: rows
        )
        let summaryIndex = try settingsRowIndex(
            containing: "Stacio.Settings.credentialCenterSummary",
            in: rows
        )
        let listHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.credentialCenterListHelp",
            in: rows
        )
        let secretFieldIndex = try settingsRowIndex(
            containing: "Stacio.Settings.credentialCenterNewSecret",
            in: rows
        )
        let secretHelpIndex = try settingsRowIndex(
            containing: "Stacio.Settings.credentialCenterSecretHelp",
            in: rows
        )
        let addActionsIndex = try settingsRowIndex(
            containing: "Stacio.Settings.credentialCenterAddPassword",
            in: rows
        )
        XCTAssertEqual(summaryIndex, listActionsIndex)
        XCTAssertEqual(listHelpIndex, listActionsIndex)
        XCTAssertEqual(secretFieldIndex, listActionsIndex + 1)
        XCTAssertEqual(secretHelpIndex, secretFieldIndex)
        XCTAssertEqual(addActionsIndex, secretFieldIndex + 1)
    }

    func testTerminalRichHighlightingDefaultsOnWithoutOverridingSavedHighlightLevel() throws {
        let newSuiteName = "StacioRichHighlightNewDefaults-\(UUID().uuidString)"
        let newDefaults = UserDefaults(suiteName: newSuiteName)!
        defer { newDefaults.removePersistentDomain(forName: newSuiteName) }
        let newStore = AppSettingsStore(defaults: newDefaults)

        XCTAssertEqual(newStore.snapshot().terminalHighlightLevel, .commandLineEnhanced)
        XCTAssertTrue(newStore.snapshot().terminalRichHighlightingEnabled)

        let savedSuiteName = "StacioRichHighlightSavedDefaults-\(UUID().uuidString)"
        let savedDefaults = UserDefaults(suiteName: savedSuiteName)!
        defer { savedDefaults.removePersistentDomain(forName: savedSuiteName) }
        savedDefaults.set(TerminalHighlightLevelPreference.off.rawValue, forKey: "Stacio.Settings.terminalHighlightLevel")
        let savedStore = AppSettingsStore(defaults: savedDefaults)

        XCTAssertEqual(savedStore.snapshot().terminalHighlightLevel, .off)
        XCTAssertTrue(savedStore.snapshot().terminalRichHighlightingEnabled)

        savedStore.update { settings in
            settings.terminalRichHighlightingEnabled = false
        }
        XCTAssertFalse(savedStore.snapshot().terminalRichHighlightingEnabled)
        XCTAssertEqual(savedStore.snapshot().terminalHighlightLevel, .off)
    }

    func testTerminalThemeSettingsPersistThemeModeAndBuiltInThemePopup() throws {
        let suiteName = "StacioTerminalThemeModeSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("terminalTheme", in: content)

        let title = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalThemeTitle") as? NSTextField
        )
        let themeControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.theme") as? NSSegmentedControl
        )
        let themeSummary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.customTerminalThemeSummary") as? NSTextField
        )
        let highlightThemePopup = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalHighlightTheme") as? NSPopUpButton
        )

        XCTAssertEqual(title.stringValue, "终端主题")
        XCTAssertEqual(themeControl.segmentCount, 4)
        XCTAssertEqual(themeControl.label(forSegment: 0), "跟随系统")
        XCTAssertEqual(themeControl.label(forSegment: 1), "浅色")
        XCTAssertEqual(themeControl.label(forSegment: 2), "深色")
        XCTAssertEqual(themeControl.label(forSegment: 3), "自定义")
        XCTAssertEqual(themeControl.fittingSize.height, 32, accuracy: 4)
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Stacio Dark"))
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Solarized Dark"))
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Solarized Light"))
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Nordic Ops"))
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Graphite"))
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Night Owl"))
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Kanagawa Wave"))
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Catppuccin Mocha"))
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Flexoki Dark"))
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Tokyo Night"))
        XCTAssertTrue(highlightThemePopup.itemTitles.contains("Gruvbox Dark"))
        XCTAssertEqual(themeSummary.stringValue, "尚未导入自定义主题")

        themeControl.selectedSegment = 2
        themeControl.sendAction(themeControl.action, to: themeControl.target)
        highlightThemePopup.selectItem(withTitle: "Solarized Dark")
        highlightThemePopup.sendAction(highlightThemePopup.action, to: highlightThemePopup.target)

        XCTAssertEqual(store.snapshot().terminalTheme, .dark)
        XCTAssertEqual(store.snapshot().terminalBuiltInThemeID, "solarized-dark")
    }

    func testTerminalThemeSettingsShowPreviewCardsAndPersistSelection() throws {
        let suiteName = "StacioTerminalThemeCardsSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("terminalTheme", in: content)
        content.layoutSubtreeIfNeeded()

        let themeGallery = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.terminalThemeGallery"))
        let cards = themeGallery.allSubviews(ofType: NSButton.self).filter {
            $0.accessibilityIdentifier().hasPrefix("Stacio.Settings.themeCard.")
        }
        XCTAssertGreaterThanOrEqual(cards.count, 9)
        XCTAssertEqual(themeGallery.subviews.count, cards.count)
        XCTAssertGreaterThanOrEqual(cards.first?.frame.width ?? 0, 440)
        XCTAssertGreaterThanOrEqual(cards.first?.frame.height ?? 0, 126)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.themeCard.stacio-dark.preview"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.themeCard.stacio-dark.palette"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.themeCard.stacio-dark.metadata"))

        let selectedCard = try XCTUnwrap(
            cards.first { $0.accessibilityIdentifier() == "Stacio.Settings.themeCard.solarized-dark" }
        )
        selectedCard.performClick(nil as Any?)

        XCTAssertEqual(store.snapshot().terminalTheme, .dark)
        XCTAssertEqual(store.snapshot().terminalBuiltInThemeID, "solarized-dark")
    }

    func testTerminalThemeSettingsKeepSystemAdaptiveThemeCard() throws {
        let suiteName = "StacioSystemAdaptiveThemeCardSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.terminalTheme = .dark
            settings.terminalBuiltInThemeID = "solarized-dark"
        }
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("terminalTheme", in: content)
        content.layoutSubtreeIfNeeded()

        let systemCard = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.themeCard.systemAdaptive") as? NSButton
        )
        let metadata = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.themeCard.systemAdaptive.metadata") as? NSTextField
        )

        XCTAssertTrue(metadata.stringValue.contains("跟随 macOS"))
        XCTAssertTrue(metadata.stringValue.contains("浅色/深色"))

        systemCard.performClick(nil as Any?)

        let themeControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.theme") as? NSSegmentedControl
        )
        let previewTitle = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalPreview.title") as? NSTextField
        )

        XCTAssertEqual(store.snapshot().terminalTheme, .system)
        XCTAssertEqual(themeControl.selectedSegment, 0)
        XCTAssertTrue(previewTitle.stringValue.contains("系统自适应"))
    }

    func testTerminalThemeSettingsThemeCardsShowComparableColorMetadata() throws {
        let suiteName = "StacioTerminalThemeMetadataSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("terminalTheme", in: content)
        content.layoutSubtreeIfNeeded()

        let metadata = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.themeCard.stacio-dark.metadata") as? NSTextField
        )
        let preview = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.themeCard.stacio-dark.preview"))
        let sampleLabels = preview.allSubviews(ofType: NSTextField.self)

        XCTAssertTrue(metadata.stringValue.contains("前景 #F5F5F5"))
        XCTAssertTrue(metadata.stringValue.contains("背景 #000000"))
        XCTAssertTrue(metadata.stringValue.contains("光标 #F5F5F5"))
        XCTAssertGreaterThanOrEqual(sampleLabels.count, 4)
        XCTAssertGreaterThanOrEqual(Set(sampleLabels.compactMap { $0.textColor }).count, 3)
    }

    func testTerminalThemeSettingsPreviewShowsRealisticCommandSampleAndPalette() throws {
        let suiteName = "StacioTerminalPreviewDetailSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("terminalTheme", in: content)
        content.layoutSubtreeIfNeeded()

        let preview = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.terminalPreview"))
        let sample = try XCTUnwrap(
            preview.firstSubview(withIdentifier: "Stacio.Settings.terminalPreview.sample") as? NSTextField
        )
        let palette = try XCTUnwrap(preview.firstSubview(withIdentifier: "Stacio.Settings.terminalPreview.palette"))

        XCTAssertGreaterThanOrEqual(preview.frame.height, 170)
        XCTAssertTrue(sample.stringValue.contains("root@stacio"))
        XCTAssertTrue(sample.stringValue.contains("systemctl status"))
        XCTAssertEqual(palette.subviews.count, 16)
    }

    func testSettingsPersistsSessionTabIconModePreference() throws {
        let suiteName = "StacioSessionTabIconModeSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let iconModeControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.sessionTabIconMode") as? NSSegmentedControl
        )
        let helpLabel = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.sessionTabIconModeHelp") as? NSTextField
        )

        XCTAssertEqual(iconModeControl.segmentCount, 2)
        XCTAssertEqual(iconModeControl.label(forSegment: 0), "默认")
        XCTAssertEqual(iconModeControl.label(forSegment: 1), "操作系统")
        XCTAssertEqual(iconModeControl.selectedSegment, 0)
        XCTAssertTrue(helpLabel.stringValue.contains("SSH 连接成功后自动识别远端系统"))

        iconModeControl.selectedSegment = 1
        iconModeControl.sendAction(iconModeControl.action, to: iconModeControl.target)

        XCTAssertEqual(store.snapshot().sessionTabIconMode, .operatingSystem)
    }

    func testSettingsPersistsRecentSessionsVisibilityPreference() throws {
        let suiteName = "StacioRecentSessionsVisibilitySettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let group = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.group.sessionSidebar")
        )
        let recentSwitch = try XCTUnwrap(
            content.firstSubview(
                withIdentifier: "Stacio.Settings.sessionSidebarShowRecentSessions.switch"
            ) as? NSSwitch
        )
        let title = try XCTUnwrap(
            content.firstSubview(
                withIdentifier: "Stacio.Settings.preferenceTitle.sessionSidebarShowRecentSessions"
            ) as? NSTextField
        )
        let help = try XCTUnwrap(
            content.firstSubview(
                withIdentifier: "Stacio.Settings.preferenceHelp.sessionSidebarShowRecentSessions"
            ) as? NSTextField
        )

        XCTAssertFalse(group.isHidden)
        XCTAssertEqual(recentSwitch.state, .on)
        XCTAssertEqual(title.stringValue, "显示“最近使用”分组")
        XCTAssertTrue(help.stringValue.contains("最多 5 个会话"))

        recentSwitch.state = .off
        recentSwitch.sendAction(recentSwitch.action, to: recentSwitch.target)

        XCTAssertFalse(store.snapshot().sessionSidebarShowRecentSessions)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).snapshot().sessionSidebarShowRecentSessions)
    }

    func testTerminalSettingsPreviewUsesSelectedFontFamily() throws {
        let suiteName = "StacioTerminalPreviewFontSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let fontFamilyPopup = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalFontFamily") as? NSPopUpButton
        )

        fontFamilyPopup.selectItem(withTitle: "Menlo")
        fontFamilyPopup.sendAction(fontFamilyPopup.action, to: fontFamilyPopup.target)
        try selectSettingsSection("terminalTheme", in: content)

        let previewSample = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalPreview.sample") as? NSTextField
        )

        XCTAssertEqual(store.snapshot().terminalFontFamily, .menlo)
        XCTAssertEqual(previewSample.font?.familyName, NSFont(name: "Menlo-Regular", size: 13)?.familyName)
    }

    func testSettingsWindowRendersNativeNavigationAndVisibleContent() throws {
        let suiteName = "StacioVisibleSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let navigation = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.navigation"))
        let terminalItem = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.nav.terminal"))
        let aiItem = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai"))
        let contentPane = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.content"))
        let terminalTitle = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.terminalTitle"))

        XCTAssertGreaterThanOrEqual(window.frame.width, 700)
        XCTAssertGreaterThanOrEqual(window.frame.height, 460)
        XCTAssertGreaterThan(navigation.frame.width, 150)
        XCTAssertGreaterThan(navigation.frame.height, 320)
        XCTAssertGreaterThan(contentPane.frame.width, 380)
        XCTAssertGreaterThan(contentPane.frame.height, 320)
        XCTAssertGreaterThan(terminalItem.frame.height, 24)
        XCTAssertGreaterThan(aiItem.frame.height, 24)
        XCTAssertGreaterThan(terminalTitle.frame.width, 40)
    }

    func testSettingsNavigationShowsSelectedItemClearlyInLightAppearance() throws {
        let suiteName = "StacioSelectedNavigationSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: .aqua)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let terminalItem = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.terminal") as? NSButton
        )
        let aiItem = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )

        assertSettingsNavigationSelectedStyle(terminalItem)
        assertSettingsNavigationUnselectedStyle(aiItem)

        aiItem.performClick(nil)
        content.layoutSubtreeIfNeeded()

        assertSettingsNavigationUnselectedStyle(terminalItem)
        assertSettingsNavigationSelectedStyle(aiItem)
    }

    func testSettingsNavigationItemsUseReadableCompactSidebarMetrics() throws {
        let suiteName = "StacioNavigationMetricsSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let terminalItem = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.terminal") as? NSButton
        )
        let securityItem = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )

        XCTAssertLessThanOrEqual(terminalItem.frame.width, 168)
        XCTAssertGreaterThanOrEqual(terminalItem.frame.height, 34)
        XCTAssertGreaterThanOrEqual(terminalItem.font?.pointSize ?? 0, 14.5)
        XCTAssertGreaterThanOrEqual(terminalItem.image?.size.width ?? 0, 24)
        XCTAssertEqual(securityItem.frame.width, terminalItem.frame.width, accuracy: 1)
    }

    func testSettingsGroupsUseMacOSGroupedListStyle() throws {
        let suiteName = "StacioGroupedListSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let group = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalAppearance"))
        let list = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalAppearance.rows"))
        let fontFamilyRow = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.formRow.terminalFontFamily"))
        let fontFamilyLabel = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.terminalFontFamily") as? NSTextField
        )
        let fontFamilyPopup = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalFontFamily") as? NSPopUpButton
        )

        XCTAssertEqual(group.layer?.cornerRadius ?? 0, 0, accuracy: 0.1)
        XCTAssertEqual(group.layer?.borderWidth ?? 0, 0, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(list.layer?.cornerRadius ?? 0, 11.5)
        XCTAssertNotNil(list.layer?.backgroundColor)
        XCTAssertEqual(list.layer?.borderWidth ?? 0, 0, accuracy: 0.1)
        XCTAssertNil(group.firstSubview(withIdentifier: "Stacio.Settings.groupSeparator"))
        XCTAssertNotNil(list.firstSubview(withIdentifier: "Stacio.Settings.groupRowSeparator"))
        XCTAssertEqual(fontFamilyLabel.alignment, .left)
        XCTAssertEqual(fontFamilyLabel.textColor, .labelColor)
        XCTAssertGreaterThan(frame(fontFamilyPopup, in: content).minX, frame(fontFamilyLabel, in: content).maxX)
        XCTAssertLessThanOrEqual(frame(fontFamilyRow, in: content).minX - frame(list, in: content).minX, 18)
    }

    func testSettingsWindowUsesProviderManagementReadyDesktopLayout() throws {
        let suiteName = "StacioBalancedSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let navigation = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.navigation"))
        let contentPane = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.content"))
        let appearanceGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalAppearance"))

        XCTAssertGreaterThanOrEqual(window.frame.width, 980)
        XCTAssertGreaterThanOrEqual(window.frame.height, 680)
        XCTAssertGreaterThanOrEqual(navigation.frame.width, 200)
        XCTAssertGreaterThanOrEqual(contentPane.frame.width, 700)
        XCTAssertGreaterThanOrEqual(appearanceGroup.frame.width, 680)
        XCTAssertEqual(appearanceGroup.layer?.cornerRadius ?? 0, 0, accuracy: 0.1)
        XCTAssertEqual(appearanceGroup.layer?.borderWidth ?? 0, 0, accuracy: 0.1)

        try selectSettingsSection("terminalTheme", in: content)
        let themeModeGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalThemeMode"))
        let preview = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.terminalPreview"))
        XCTAssertGreaterThanOrEqual(themeModeGroup.frame.width, 680)
        XCTAssertGreaterThanOrEqual(preview.frame.width, 620)
    }

    func testTerminalPreferenceRowsKeepReadableTextAtDesktopWidth() throws {
        let suiteName = "StacioReadablePreferenceRowsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        try assertTerminalPreferenceRowLayout(
            identifier: "terminalScrollbackLines",
            controlIdentifier: "Stacio.Settings.terminalScrollbackLines",
            in: content
        )
        try assertTerminalPreferenceRowLayout(
            identifier: "terminalX11Display",
            controlIdentifier: "Stacio.Settings.terminalX11Display",
            in: content
        )
        let scrollbackField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalScrollbackLines") as? NSTextField
        )
        let x11DisplayField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalX11Display") as? NSTextField
        )
        XCTAssertLessThanOrEqual(frame(scrollbackField, in: content).width, 61)
        XCTAssertEqual(frame(scrollbackField, in: content).height, 24, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(frame(x11DisplayField, in: content).width, 300)
        XCTAssertEqual(frame(x11DisplayField, in: content).height, 24, accuracy: 0.5)
        try assertTextFieldContentVerticallyCentered(
            scrollbackField,
            bounds: scrollbackField.bounds
        )
        try assertTextFieldContentVerticallyCentered(
            x11DisplayField,
            bounds: x11DisplayField.bounds
        )
    }

    func testSettingsLayoutKeepsGroupsAndFormColumnsAligned() throws {
        let suiteName = "StacioAlignedSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let terminalGroups = [
            try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalAppearance")),
            try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalBehavior"))
        ]
        assertAlignedSettingsGroups(terminalGroups)

        let fontSizeField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.fontSize") as? NSTextField
        )
        XCTAssertGreaterThan(frame(fontSizeField, in: content).minX, 0)

        try selectSettingsSection("terminalTheme", in: content)
        let terminalThemeGroups = [
            try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalThemeMode")),
            try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalThemeLibrary"))
        ]
        assertAlignedSettingsGroups(terminalThemeGroups)
        let themeControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.theme") as? NSSegmentedControl
        )
        let highlightThemePopup = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalHighlightTheme") as? NSPopUpButton
        )
        assertControlsShareFormColumn(themeControl, highlightThemePopup, in: content)

        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.ai.tabs"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiProvider"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiModelCatalog"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProvider"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiModelCatalog"))
    }

    func testSettingsFormControlsStayNearTheirGroupDescription() throws {
        let suiteName = "StacioSettingsFormColumnTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let terminalGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalAppearance"))
        let fontFamilyRow = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.formRow.terminalFontFamily"))
        let fontFamilyLabel = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.terminalFontFamily") as? NSTextField
        )
        let fontFamilyPopup = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.terminalFontFamily") as? NSPopUpButton
        )
        assertControlColumnDoesNotFloatAway(
            row: fontFamilyRow,
            label: fontFamilyLabel,
            control: fontFamilyPopup,
            group: terminalGroup,
            content: content
        )

        try selectSettingsSection("ai", in: content)

        try selectAISettingsTab("上下文", in: content)

        let aiContextGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiContext"))
        XCTAssertGreaterThan(aiContextGroup.frame.height, 40)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiIncludeRecentTerminalTranscript"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiReasoningEffort"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiContextCharacterLimit"))

        try selectSettingsSection("metrics", in: content)

        let metricsDisplayGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.metricsDisplay"))
        let diskLimitRow = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsDiskMountLimitRow"))
        let diskLimitLabel = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsDiskMountLimit.label") as? NSTextField
        )
        let diskLimitField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsDiskMountLimit") as? NSTextField
        )
        assertControlColumnDoesNotFloatAway(
            row: diskLimitRow,
            label: diskLimitLabel,
            control: diskLimitField,
            group: metricsDisplayGroup,
            content: content
        )
    }

    func testSettingsFormLabelsMatchControlFontSizeAndVerticalTextCenter() throws {
        let suiteName = "StacioSettingsFormLabelAlignmentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.terminalFontFamily",
            controlIdentifier: "Stacio.Settings.terminalFontFamily",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.fontSize",
            controlIdentifier: "Stacio.Settings.fontSize",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.sessionTabIconMode",
            controlIdentifier: "Stacio.Settings.sessionTabIconMode",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.terminalHighlightLevel",
            controlIdentifier: "Stacio.Settings.terminalHighlightLevel",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.terminalRightClickBehavior",
            controlIdentifier: "Stacio.Settings.terminalRightClickBehavior",
            in: content
        )

        try selectSettingsSection("terminalTheme", in: content)
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.theme",
            controlIdentifier: "Stacio.Settings.theme",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.terminalHighlightTheme",
            controlIdentifier: "Stacio.Settings.terminalHighlightTheme",
            in: content
        )

        try selectSettingsSection("ai", in: content)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.ai.tabs"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.provider"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.baseURL"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.model"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.apiKey"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.aiModelCatalog"))
        try selectAISettingsTab("上下文", in: content)
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.aiReasoningEffort"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiReasoningEffort"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.aiContextCharacterLimit"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiContextCharacterLimit"))
        try selectAISettingsTab("执行与权限", in: content)
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.confirmationPolicy",
            controlIdentifier: "Stacio.Settings.agentConfirmationPolicy",
            in: content
        )
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.executionMode"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.agentExecutionMode"))

        try selectSettingsSection("files", in: content)
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.filesTransferConflictPolicy.label",
            controlIdentifier: "Stacio.Settings.filesTransferConflictPolicy",
            in: content
        )

        try selectSettingsSection("metrics", in: content)
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.deviceMetricsRefreshIntervalSeconds.label",
            controlIdentifier: "Stacio.Settings.deviceMetricsRefreshIntervalSeconds",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.deviceMetricsDiskMountLimit.label",
            controlIdentifier: "Stacio.Settings.deviceMetricsDiskMountLimit",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.deviceMetricsHistorySampleCount.label",
            controlIdentifier: "Stacio.Settings.deviceMetricsHistorySampleCount",
            in: content
        )

        try selectSettingsSection("security", in: content)
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.confirmationPolicy",
            controlIdentifier: "Stacio.Settings.securityAgentConfirmationPolicy",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.diagnosticsAuditExportLimit",
            controlIdentifier: "Stacio.Settings.diagnosticsAuditExportLimit",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.diagnosticsAppLogLineLimit",
            controlIdentifier: "Stacio.Settings.diagnosticsAppLogLineLimit",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.credentialCenterNewLabel",
            controlIdentifier: "Stacio.Settings.credentialCenterNewLabel",
            in: content
        )
        try assertSettingsFormPair(
            labelIdentifier: "Stacio.Settings.formLabel.applicationSupport",
            controlIdentifier: "Stacio.Settings.path.applicationSupport",
            in: content
        )
    }

    func testSettingsPersistsVisibleAIAgentPreferencesWithoutMutatingLegacyModelCapabilities() throws {
        let suiteName = "StacioAISettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.aiReasoningEffort = .high
            settings.aiContextCharacterLimit = 16_000
        }
        let apiKeyStore = KeychainAIApiKeyStore(
            credentialStore: KeychainCredentialStore(backend: InMemoryKeychainBackend())
        )
        let controller = AppSettingsWindowController(settingsStore: store, aiAPIKeyStore: apiKeyStore)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiBaseURL"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiModel"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiAPIKey"))

        try selectAISettingsTab("上下文", in: content)
        let includeTranscriptButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.aiIncludeRecentTerminalTranscript") as? NSButton
        )
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiContextCharacterLimit"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiReasoningEffort"))

        try selectAISettingsTab("执行与权限", in: content)
        let confirmationControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.agentConfirmationPolicy") as? NSSegmentedControl
        )
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.agentExecutionMode"))
        let autoRunButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.aiAutoRunProposedCommands") as? NSButton
        )
        let allowPatternsField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.agentCommandAllowPatterns") as? NSTextField
        )
        let denyPatternsField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.agentCommandDenyPatterns") as? NSTextField
        )

        XCTAssertEqual(includeTranscriptButton.state, .on)
        XCTAssertEqual(confirmationControl.segmentCount, 4)
        XCTAssertEqual(confirmationControl.label(forSegment: 0), "全部自动")
        XCTAssertEqual(confirmationControl.label(forSegment: 1), "低风险自动")
        XCTAssertEqual(confirmationControl.label(forSegment: 2), "只读自动")
        XCTAssertEqual(confirmationControl.label(forSegment: 3), "每次确认")

        try selectAISettingsTab("上下文", in: content)
        includeTranscriptButton.state = .off
        includeTranscriptButton.sendAction(includeTranscriptButton.action, to: includeTranscriptButton.target)

        try selectAISettingsTab("执行与权限", in: content)
        confirmationControl.selectedSegment = 1
        confirmationControl.sendAction(confirmationControl.action, to: confirmationControl.target)
        autoRunButton.state = .off
        autoRunButton.sendAction(autoRunButton.action, to: autoRunButton.target)
        allowPatternsField.stringValue = "systemctl status\njournalctl"
        allowPatternsField.sendAction(allowPatternsField.action, to: allowPatternsField.target)
        denyPatternsField.stringValue = "rm -rf\nkubectl delete"
        denyPatternsField.sendAction(denyPatternsField.action, to: denyPatternsField.target)

        let snapshot = store.snapshot()
        XCTAssertFalse(snapshot.aiIncludeRecentTerminalTranscript)
        XCTAssertEqual(snapshot.aiContextCharacterLimit, 16_000)
        XCTAssertEqual(snapshot.aiReasoningEffort, .high)
        XCTAssertEqual(snapshot.agentConfirmationPolicy, .allowLowRiskWithoutPrompt)
        XCTAssertEqual(snapshot.agentExecutionMode, .visibleTerminal)
        XCTAssertFalse(snapshot.aiAutoRunProposedCommands)
        XCTAssertEqual(snapshot.agentCommandAllowPatterns, "systemctl status\njournalctl")
        XCTAssertEqual(snapshot.agentCommandDenyPatterns, "rm -rf\nkubectl delete")
    }

    func testSavingProviderEnvelopePreservesLegacyModelCapabilityFallbacks() throws {
        let suiteName = "StacioAIModelCatalogSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let providerID = UUID(uuidString: "61000000-0000-0000-0000-000000000001")!
        let provider = AIProviderConfiguration(
            id: providerID,
            profile: .openAICompatible,
            displayName: "Team Gateway",
            baseURL: "https://gateway.example/v1",
            models: [
                AIProviderModelConfiguration(
                    id: "qwen2.5-coder",
                    isEnabled: true,
                    isManual: true,
                    wasReturnedByLatestCatalog: false
                ),
                AIProviderModelConfiguration(
                    id: "gpt-4.1-mini",
                    isEnabled: true,
                    isManual: false,
                    wasReturnedByLatestCatalog: true
                )
            ],
            defaultModelID: "qwen2.5-coder",
            compatibilityProtocol: .responses,
            maxRetryCount: 1,
            requestTimeoutSeconds: 45,
            userAgent: "Stacio",
            isEnabled: true,
            lastVerifiedAt: nil,
            lastModelSyncAt: nil
        )

        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: providerID)
        )

        defaults.set("high", forKey: "Stacio.Settings.aiReasoningEffort")
        defaults.set(16_000, forKey: "Stacio.Settings.aiContextCharacterLimit")

        let envelope = try store.loadAIProviderSettings()
        let snapshot = store.snapshot()
        XCTAssertEqual(envelope.aiProviders, [provider, BuiltInAIProvider.defaultConfiguration])
        XCTAssertEqual(envelope.defaultAIProviderID, providerID)
        XCTAssertEqual(snapshot.aiProviderSettings, envelope)
        XCTAssertEqual(snapshot.aiReasoningEffort, .high)
        XCTAssertEqual(snapshot.aiContextCharacterLimit, 16_000)
    }

    func testSettingsPersistsManyModelsThroughAIProviderEnvelopeWithoutTruncating() throws {
        let suiteName = "StacioAIUnboundedModelSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let providerID = UUID(uuidString: "61000000-0000-0000-0000-000000000002")!
        let models = (1...120).map {
            AIProviderModelConfiguration(
                id: "ops-model-\($0)",
                isEnabled: true,
                isManual: true,
                wasReturnedByLatestCatalog: false
            )
        }
        let provider = AIProviderConfiguration(
            id: providerID,
            profile: .openAICompatible,
            displayName: "Large Catalog",
            baseURL: "https://catalog.example/v1",
            models: models,
            defaultModelID: models.first?.id,
            compatibilityProtocol: .chatCompletions,
            maxRetryCount: 1,
            requestTimeoutSeconds: 45,
            userAgent: "Stacio",
            isEnabled: true,
            lastVerifiedAt: nil,
            lastModelSyncAt: nil
        )

        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: providerID)
        )

        let persistedModels = try XCTUnwrap(store.loadAIProviderSettings().aiProviders.first).models
        XCTAssertEqual(persistedModels.count, 120)
        XCTAssertEqual(persistedModels.first?.id, "ops-model-1")
        XCTAssertEqual(persistedModels.last?.id, "ops-model-120")
        XCTAssertEqual(persistedModels.map(\.id), models.map(\.id))
    }

    func testAISettingsMountsModelManagerAndRemovesLegacyConnectionSurface() throws {
        let suiteName = "StacioAIConnectionSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiTestConnection"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiConnectionStatus"))
    }

    func testAISettingsPlacesTabsAtTopAndFillsContentHostWithModelManager() throws {
        let suiteName = "StacioAISettingsGeometryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.content"))
        let aiRoot = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.ai.tabs"))
        let aiContent = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.aiTabs.content"))
        let tabs = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.aiTabs.control"))
        let manager = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        let hostFrame = host.convert(host.bounds, to: content)
        let aiRootFrame = aiRoot.convert(aiRoot.bounds, to: content)
        let aiContentFrame = aiContent.convert(aiContent.bounds, to: content)
        let tabsFrame = tabs.convert(tabs.bounds, to: content)
        let managerFrame = manager.convert(manager.bounds, to: content)
        let frameSummary = "host=\(hostFrame) aiRoot=\(aiRootFrame) aiContent=\(aiContentFrame) tabs=\(tabsFrame) manager=\(managerFrame)"

        XCTAssertGreaterThan(
            tabsFrame.minY,
            hostFrame.midY,
            "AI tabs should remain in the upper half of the settings pane. \(frameSummary)"
        )
        XCTAssertGreaterThan(
            managerFrame.height,
            hostFrame.height * 0.5,
            "The provider manager should occupy the content below the tabs. \(frameSummary)"
        )
        XCTAssertLessThanOrEqual(managerFrame.minY, hostFrame.minY + 1)
        XCTAssertLessThan(managerFrame.maxY, tabsFrame.minY)
    }

    func testAISettingsShowsGroupedStatusAndAgentBridgeDetails() throws {
        let suiteName = "StacioAIGroupedSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiSummary"))

        try selectAISettingsTab("上下文", in: content)
        let contextHelp = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.aiContextHelp") as? NSTextField
        )
        XCTAssertTrue(contextHelp.stringValue.contains("模型管理"))

        try selectAISettingsTab("执行与权限", in: content)
        let executionGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiExecution"))
        let bridgeGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.agentBridge"))
        let bridgeSocket = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.agentBridgeSocket") as? NSTextField
        )
        let bridgeHint = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.agentBridgeHint") as? NSTextField
        )
        let executionHelp = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.aiExecutionHelp") as? NSTextField
        )
        let commandPatternHelp = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.agentCommandPatternHelp") as? NSTextField
        )

        XCTAssertGreaterThan(executionGroup.frame.height, 100)
        XCTAssertGreaterThan(bridgeGroup.frame.height, 80)
        XCTAssertTrue(bridgeSocket.stringValue.contains("agent-bridge.sock"))
        XCTAssertTrue(bridgeHint.stringValue.contains("stacio agent sessions"))
        XCTAssertTrue(bridgeHint.stringValue.contains("stacio 仍作为兼容命令保留"))
        XCTAssertTrue(executionHelp.stringValue.contains("当前终端标签页"))
        XCTAssertTrue(executionHelp.stringValue.contains("现有 SSH 或本地终端会话"))
        XCTAssertFalse(executionHelp.stringValue.contains("独立执行 runtime"))
        XCTAssertTrue(commandPatternHelp.stringValue.contains("禁止模式优先"))
        XCTAssertTrue(commandPatternHelp.stringValue.contains("从命令开头匹配"))
        XCTAssertTrue(commandPatternHelp.stringValue.contains("sudo"))

        let confirmationControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.agentConfirmationPolicy") as? NSSegmentedControl
        )
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.agentExecutionMode"))

        confirmationControl.selectedSegment = 3
        confirmationControl.sendAction(confirmationControl.action, to: confirmationControl.target)

        XCTAssertEqual(store.snapshot().agentConfirmationPolicy, .requireEveryCommand)
        XCTAssertEqual(store.snapshot().agentExecutionMode, .visibleTerminal)
    }

    func testAIAndSecuritySettingsShowApprovalRiskMatrix() throws {
        let suiteName = "StacioApprovalRiskMatrixSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()
        try selectAISettingsTab("执行与权限", in: content)

        let aiMatrix = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.agentApprovalRiskMatrix") as? NSTextField
        )
        XCTAssertTrue(aiMatrix.stringValue.contains("只读：自动放行"))
        XCTAssertTrue(aiMatrix.stringValue.contains("普通写入：自动放行"))
        XCTAssertTrue(aiMatrix.stringValue.contains("网络操作：需要确认"))
        XCTAssertTrue(aiMatrix.stringValue.contains("破坏性：需要确认"))

        let confirmationControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.agentConfirmationPolicy") as? NSSegmentedControl
        )
        confirmationControl.selectedSegment = 3
        confirmationControl.sendAction(confirmationControl.action, to: confirmationControl.target)
        XCTAssertTrue(aiMatrix.stringValue.contains("只读：需要确认"))
        XCTAssertTrue(aiMatrix.stringValue.contains("破坏性：需要确认"))

        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let securityMatrix = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securityApprovalRiskMatrix") as? NSTextField
        )
        XCTAssertTrue(securityMatrix.stringValue.contains("只读：需要确认"))
        XCTAssertTrue(securityMatrix.stringValue.contains("普通写入：需要确认"))
        XCTAssertTrue(securityMatrix.stringValue.contains("网络操作：需要确认"))
        XCTAssertTrue(securityMatrix.stringValue.contains("破坏性：需要确认"))
    }

    func testAISettingsRemovesLegacyProviderPopupAndCatalogSurface() throws {
        let suiteName = "StacioAIPresetSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.ai.tabs"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiPresets"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProvider"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiBaseURL"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiModel"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiModelCatalog"))
    }

    func testAISettingsKeepsLegacyModelCapabilityControlsOutOfContextTab() throws {
        let suiteName = "StacioAIModelCatalogUITests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.aiReasoningEffort = .high
            settings.aiContextCharacterLimit = 16_000
        }
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiModelCatalog"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiModelCatalog"))

        try selectAISettingsTab("上下文", in: content)

        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiContext"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiReasoningEffort"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiContextCharacterLimit"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.aiReasoningEffort"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.formLabel.aiContextCharacterLimit"))
        XCTAssertEqual(store.snapshot().aiReasoningEffort, .high)
        XCTAssertEqual(store.snapshot().aiContextCharacterLimit, 16_000)
    }

    func testAISettingsDoesNotExposeLegacyCustomModelList() throws {
        let suiteName = "StacioAIMultipleModelCatalogUITests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.aiProvider = "OpenAI Compatible"
            settings.aiModel = "ops-model-0"
            settings.aiCustomModels = []
        }
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("ai", in: content)

        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiModel"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiAddCustomModel"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiCustomModelList"))
    }

    func testAISettingsModelRefreshBelongsToProviderManager() throws {
        let suiteName = "StacioAIModelRefreshUITests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let loader = RecordingAIModelCatalogLoader(models: ["gpt-4.1-mini", "qwen2.5-coder"])
        let apiKeyStore = KeychainAIApiKeyStore(
            credentialStore: KeychainCredentialStore(backend: InMemoryKeychainBackend())
        )
        let controller = AppSettingsWindowController(
            settingsStore: store,
            aiAPIKeyStore: apiKeyStore,
            aiModelCatalogLoader: loader
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.refreshModels"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiRefreshModels"))
        XCTAssertTrue(loader.snapshots.isEmpty)
    }

    func testSettingsPersistsFilesAndSecurityPreferences() throws {
        let suiteName = "StacioFilesSecuritySettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let filesNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.files") as? NSButton
        )
        filesNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let directoryFollowCheckbox = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesDirectoryFollowDefault") as? NSButton
        )
        let showHiddenFilesCheckbox = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesShowHiddenFilesByDefault") as? NSButton
        )
        let remoteEditAutoDetectCheckbox = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesRemoteEditAutoDetectChanges") as? NSButton
        )
        XCTAssertEqual(directoryFollowCheckbox.title, "默认开启目录跟随")
        XCTAssertEqual(directoryFollowCheckbox.state, .on)
        XCTAssertEqual(showHiddenFilesCheckbox.title, "默认显示隐藏文件")
        XCTAssertEqual(showHiddenFilesCheckbox.state, .on)
        XCTAssertEqual(remoteEditAutoDetectCheckbox.title, "检测本地编辑副本变化")
        XCTAssertEqual(remoteEditAutoDetectCheckbox.state, .on)

        directoryFollowCheckbox.performClick(nil)
        showHiddenFilesCheckbox.performClick(nil)
        remoteEditAutoDetectCheckbox.performClick(nil)
        XCTAssertFalse(store.snapshot().filesDirectoryFollowDefault)
        XCTAssertFalse(store.snapshot().filesShowHiddenFilesByDefault)
        XCTAssertFalse(store.snapshot().filesRemoteEditAutoDetectChanges)

        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let securityConfirmationControl = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securityAgentConfirmationPolicy") as? NSSegmentedControl
        )
        let securityAllowPatternsField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securityAgentCommandAllowPatterns") as? NSTextField
        )
        let securityDenyPatternsField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securityAgentCommandDenyPatterns") as? NSTextField
        )
        XCTAssertEqual(securityConfirmationControl.segmentCount, 4)
        securityConfirmationControl.selectedSegment = 3
        securityConfirmationControl.sendAction(
            securityConfirmationControl.action,
            to: securityConfirmationControl.target
        )
        securityAllowPatternsField.stringValue = "uptime\nsystemctl status"
        securityAllowPatternsField.sendAction(
            securityAllowPatternsField.action,
            to: securityAllowPatternsField.target
        )
        securityDenyPatternsField.stringValue = "shutdown\nreboot"
        securityDenyPatternsField.sendAction(
            securityDenyPatternsField.action,
            to: securityDenyPatternsField.target
        )

        XCTAssertEqual(store.snapshot().agentConfirmationPolicy, .requireEveryCommand)
        XCTAssertEqual(store.snapshot().agentCommandAllowPatterns, "uptime\nsystemctl status")
        XCTAssertEqual(store.snapshot().agentCommandDenyPatterns, "shutdown\nreboot")
    }

    func testFilesSettingsExposeClearCacheActionWithSizeAndDirtyWarning() throws {
        let suiteName = "StacioFilesCacheSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let summary = StacioCacheSummary(totalBytes: 3_000_000, dirtyRemoteEditItemCount: 1)
        let cacheMaintenance = RecordingStacioCacheMaintenance(summary: summary)
        let cachePresenter = RecordingAppSettingsCacheClearPresenter(shouldConfirm: true)
        let controller = AppSettingsWindowController(
            settingsStore: store,
            cacheMaintenance: cacheMaintenance,
            cacheClearPresenter: cachePresenter
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let filesNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.files") as? NSButton
        )
        filesNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let cacheGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.filesCache"))
        let sizeLabel = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesCacheSize") as? NSTextField
        )
        let helpLabel = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesCacheHelp") as? NSTextField
        )
        let clearButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.clearCache") as? NSButton
        )
        let warningMessage = L10n.Settings.clearCacheConfirmMessage(
            cacheSize: "3 MB",
            dirtyItemCount: summary.dirtyRemoteEditItemCount
        )

        XCTAssertGreaterThan(cacheGroup.frame.height, 70)
        XCTAssertEqual(clearButton.title, "清除缓存...")
        XCTAssertTrue(sizeLabel.stringValue.contains("3 MB"))
        XCTAssertTrue(sizeLabel.stringValue.contains("未保存"))
        XCTAssertTrue(sizeLabel.stringValue.contains("1"))
        XCTAssertTrue(helpLabel.stringValue.contains("Remote Edit"))
        XCTAssertTrue(helpLabel.stringValue.contains("StacioRemoteFileCreate"))
        XCTAssertTrue(warningMessage.contains("未保存的远程编辑改动将丢失"))
        XCTAssertTrue(warningMessage.contains("1"))

        clearButton.performClick(nil)

        XCTAssertEqual(cachePresenter.confirmedSummaries, [summary])
        XCTAssertEqual(cacheMaintenance.clearCount, 1)
        XCTAssertEqual(cachePresenter.completedBytesCleared, [3_000_000])
        XCTAssertTrue(sizeLabel.stringValue.contains("0"))
    }

    func testSecuritySettingsPersistsDiagnosticsAuditExportPreferences() throws {
        let suiteName = "StacioSecurityDiagnosticsSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let auditLimitField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.diagnosticsAuditExportLimit") as? NSTextField
        )
        let appLogLimitField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.diagnosticsAppLogLineLimit") as? NSTextField
        )
        let includeLogsButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.diagnosticsIncludeAppLogs") as? NSButton
        )
        let summary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securitySummary.audit") as? NSTextField
        )
        let help = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securityAuditHelp") as? NSTextField
        )

        XCTAssertEqual(auditLimitField.stringValue, "20")
        XCTAssertEqual(appLogLimitField.stringValue, "200")
        XCTAssertEqual(includeLogsButton.state, .on)
        XCTAssertTrue(summary.stringValue.contains("最近 20 条"))
        XCTAssertTrue(summary.stringValue.contains("日志 200 行"))
        XCTAssertTrue(help.stringValue.contains("诊断包"))
        XCTAssertTrue(help.stringValue.contains("脱敏"))

        auditLimitField.stringValue = "75"
        auditLimitField.sendAction(auditLimitField.action, to: auditLimitField.target)
        appLogLimitField.stringValue = "450"
        appLogLimitField.sendAction(appLogLimitField.action, to: appLogLimitField.target)
        includeLogsButton.performClick(nil)

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.diagnosticsAuditExportLimit, 75)
        XCTAssertEqual(snapshot.diagnosticsAppLogLineLimit, 450)
        XCTAssertFalse(snapshot.diagnosticsIncludeAppLogs)
        XCTAssertTrue(summary.stringValue.contains("最近 75 条"))
        XCTAssertTrue(summary.stringValue.contains("不包含应用日志"))
    }

    func testSettingsShowsGroupedTerminalFilesAndSecurityStatus() throws {
        let suiteName = "StacioGroupedSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalAppearance"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.terminalBehavior"))

        let filesNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.files") as? NSButton
        )
        filesNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let filesSummary = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.filesSummary"))
        let filesDirectorySummary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesSummary.directoryFollow") as? NSTextField
        )
        let filesRemoteEditSummary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesSummary.remoteEditAutoDetect") as? NSTextField
        )
        let filesGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.filesNavigation"))
        XCTAssertGreaterThan(filesSummary.frame.height, 42)
        XCTAssertLessThan(filesSummary.frame.height, 130)
        XCTAssertGreaterThan(filesGroup.frame.height, 90)
        XCTAssertTrue(filesDirectorySummary.stringValue.contains("开启"))
        XCTAssertTrue(filesRemoteEditSummary.stringValue.contains("开启"))

        let directoryFollowCheckbox = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesDirectoryFollowDefault") as? NSButton
        )
        let showHiddenFilesCheckbox = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesShowHiddenFilesByDefault") as? NSButton
        )
        let remoteEditAutoDetectCheckbox = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesRemoteEditAutoDetectChanges") as? NSButton
        )
        let conflictPolicyPopup = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesTransferConflictPolicy") as? NSPopUpButton
        )
        let queueVisibilityCheckbox = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesTransferQueueVisibleByDefault") as? NSButton
        )
        directoryFollowCheckbox.performClick(nil)
        showHiddenFilesCheckbox.performClick(nil)
        remoteEditAutoDetectCheckbox.performClick(nil)
        conflictPolicyPopup.selectItem(withTitle: "保留两份")
        conflictPolicyPopup.sendAction(conflictPolicyPopup.action, to: conflictPolicyPopup.target)
        queueVisibilityCheckbox.performClick(nil)
        XCTAssertTrue(filesDirectorySummary.stringValue.contains("关闭"))
        XCTAssertTrue(filesDirectorySummary.stringValue.contains("隐藏文件：关闭"))
        XCTAssertTrue(filesRemoteEditSummary.stringValue.contains("关闭"))
        XCTAssertEqual(store.snapshot().filesTransferConflictPolicy, .keepBoth)
        XCTAssertFalse(store.snapshot().filesShowHiddenFilesByDefault)
        XCTAssertFalse(store.snapshot().filesTransferQueueVisibleByDefault)

        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let securitySummary = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.securitySummary"))
        let securityApprovalSummary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securitySummary.approval") as? NSTextField
        )
        let securityCredentialSummary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securitySummary.credentials") as? NSTextField
        )
        let securityAuditSummary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securitySummary.audit") as? NSTextField
        )
        let securityCommandPolicyHelp = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securityCommandPolicyHelp") as? NSTextField
        )
        let securityAuditHelp = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.securityAuditHelp") as? NSTextField
        )
        XCTAssertGreaterThan(securitySummary.frame.height, 42)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.securityApproval"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.securityAudit"))
        XCTAssertTrue(securityApprovalSummary.stringValue.contains("低风险自动"))
        XCTAssertTrue(securityCredentialSummary.stringValue.contains("Stacio 本地凭据库"))
        XCTAssertTrue(securityAuditSummary.stringValue.contains("本地审计"))
        XCTAssertTrue(securityCommandPolicyHelp.stringValue.contains("网络与破坏性命令仍需确认"))
        XCTAssertTrue(securityAuditHelp.stringValue.contains("本地追踪"))
    }

    func testFilesSettingsRowsStayCompactAndControlsAreVerticallyCentered() throws {
        let suiteName = "StacioFilesSettingsLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let filesNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.files") as? NSButton
        )
        filesNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let directoryFollowSwitch = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesDirectoryFollowDefault.switch") as? NSSwitch
        )
        let showHiddenFilesSwitch = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesShowHiddenFilesByDefault.switch") as? NSSwitch
        )
        let remoteEditSwitch = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesRemoteEditAutoDetectChanges.switch") as? NSSwitch
        )
        let conflictRow = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.filesTransferConflictPolicyRow"))
        let conflictLabel = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesTransferConflictPolicy.label") as? NSTextField
        )
        let conflictPopup = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesTransferConflictPolicy") as? NSPopUpButton
        )
        let queueSwitch = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.filesTransferQueueVisibleByDefault.switch") as? NSSwitch
        )

        XCTAssertLessThan(
            abs(frame(showHiddenFilesSwitch, in: content).minY - frame(directoryFollowSwitch, in: content).minY),
            90
        )
        XCTAssertLessThan(
            abs(frame(remoteEditSwitch, in: content).minY - frame(showHiddenFilesSwitch, in: content).minY),
            90
        )
        XCTAssertLessThan(
            abs(frame(conflictRow, in: content).minY - frame(remoteEditSwitch, in: content).minY),
            110
        )
        XCTAssertLessThan(
            abs(frame(queueSwitch, in: content).minY - frame(conflictRow, in: content).minY),
            95
        )
        XCTAssertEqual(
            frame(conflictLabel, in: content).midY,
            frame(conflictPopup, in: content).midY,
            accuracy: 1.5
        )
    }

    func testSettingsPersistsDeviceMetricsCollectionPreferences() throws {
        let suiteName = "StacioMetricsSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let metricsNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.metrics") as? NSButton
        )
        metricsNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let collectionGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.metricsCollection"))
        let displayGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.metricsDisplay"))
        let compatibilityGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.metricsCompatibility"))
        let alertsGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.metricsAlerts"))
        let intervalField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsRefreshIntervalSeconds") as? NSTextField
        )
        let keepLastButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsKeepLastSnapshotOnFailure") as? NSButton
        )
        let showNetworkButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsShowNetworkSection") as? NSButton
        )
        let showDiskButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsShowDiskSection") as? NSButton
        )
        let diskLimitField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsDiskMountLimit") as? NSTextField
        )
        let historyLimitField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsHistorySampleCount") as? NSTextField
        )
        let hideVirtualNetworksButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsHideVirtualNetworkInterfaces") as? NSButton
        )
        let alertsEnabledButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsAlertEnabled") as? NSButton
        )
        let cpuAlertField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsCPUAlertThresholdPercent") as? NSTextField
        )
        let memoryAlertField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsMemoryAlertThresholdPercent") as? NSTextField
        )
        let diskAlertField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsDiskAlertThresholdPercent") as? NSTextField
        )
        let consecutiveAlertField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsAlertConsecutiveRefreshCount") as? NSTextField
        )
        let summary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.metricsSummary.collection") as? NSTextField
        )
        let help = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.metricsCompatibilityHelp") as? NSTextField
        )

        assertAlignedSettingsGroups([collectionGroup, displayGroup, compatibilityGroup, alertsGroup])
        XCTAssertGreaterThan(collectionGroup.frame.height, 90)
        XCTAssertGreaterThan(displayGroup.frame.height, 150)
        XCTAssertGreaterThan(compatibilityGroup.frame.height, 90)
        XCTAssertGreaterThan(alertsGroup.frame.height, 170)
        XCTAssertEqual(intervalField.stringValue, "2")
        XCTAssertEqual(keepLastButton.state, .on)
        XCTAssertEqual(showNetworkButton.state, .on)
        XCTAssertEqual(showDiskButton.state, .on)
        XCTAssertEqual(diskLimitField.stringValue, "5")
        XCTAssertEqual(historyLimitField.stringValue, "42")
        XCTAssertEqual(hideVirtualNetworksButton.state, .on)
        XCTAssertEqual(alertsEnabledButton.state, .on)
        XCTAssertEqual(cpuAlertField.stringValue, "90")
        XCTAssertEqual(memoryAlertField.stringValue, "90")
        XCTAssertEqual(diskAlertField.stringValue, "90")
        XCTAssertEqual(consecutiveAlertField.stringValue, "2")
        XCTAssertTrue(summary.stringValue.contains("每 2 秒"))
        XCTAssertTrue(summary.stringValue.contains("网络开启"))
        XCTAssertTrue(summary.stringValue.contains("磁盘 5 个"))
        XCTAssertTrue(summary.stringValue.contains("告警开启"))
        XCTAssertTrue(summary.stringValue.contains("连续 2 次"))
        XCTAssertTrue(help.stringValue.contains("CentOS"))
        XCTAssertTrue(help.stringValue.contains("Rocky"))
        XCTAssertTrue(help.stringValue.contains("Fedora"))
        XCTAssertTrue(help.stringValue.contains("/proc"))
        XCTAssertTrue(help.stringValue.contains("df"))

        intervalField.stringValue = "9"
        intervalField.sendAction(intervalField.action, to: intervalField.target)
        keepLastButton.performClick(nil)
        showNetworkButton.performClick(nil)
        showDiskButton.performClick(nil)
        hideVirtualNetworksButton.performClick(nil)
        diskLimitField.stringValue = "8"
        diskLimitField.sendAction(diskLimitField.action, to: diskLimitField.target)
        historyLimitField.stringValue = "64"
        historyLimitField.sendAction(historyLimitField.action, to: historyLimitField.target)
        alertsEnabledButton.performClick(nil)
        cpuAlertField.stringValue = "88"
        cpuAlertField.sendAction(cpuAlertField.action, to: cpuAlertField.target)
        memoryAlertField.stringValue = "87"
        memoryAlertField.sendAction(memoryAlertField.action, to: memoryAlertField.target)
        diskAlertField.stringValue = "86"
        diskAlertField.sendAction(diskAlertField.action, to: diskAlertField.target)
        consecutiveAlertField.stringValue = "4"
        consecutiveAlertField.sendAction(consecutiveAlertField.action, to: consecutiveAlertField.target)

        XCTAssertEqual(store.snapshot().deviceMetricsRefreshIntervalSeconds, 9)
        XCTAssertFalse(store.snapshot().deviceMetricsKeepLastSnapshotOnFailure)
        XCTAssertFalse(store.snapshot().deviceMetricsShowNetworkSection)
        XCTAssertFalse(store.snapshot().deviceMetricsShowDiskSection)
        XCTAssertFalse(store.snapshot().deviceMetricsHideVirtualNetworkInterfaces)
        XCTAssertEqual(store.snapshot().deviceMetricsDiskMountLimit, 8)
        XCTAssertEqual(store.snapshot().deviceMetricsHistorySampleCount, 64)
        XCTAssertFalse(store.snapshot().deviceMetricsAlertEnabled)
        XCTAssertEqual(store.snapshot().deviceMetricsCPUAlertThresholdPercent, 88)
        XCTAssertEqual(store.snapshot().deviceMetricsMemoryAlertThresholdPercent, 87)
        XCTAssertEqual(store.snapshot().deviceMetricsDiskAlertThresholdPercent, 86)
        XCTAssertEqual(store.snapshot().deviceMetricsAlertConsecutiveRefreshCount, 4)
        XCTAssertTrue(summary.stringValue.contains("每 9 秒"))
        XCTAssertTrue(summary.stringValue.contains("失败时显示错误"))
        XCTAssertTrue(summary.stringValue.contains("网络关闭"))
        XCTAssertTrue(summary.stringValue.contains("磁盘关闭"))
        XCTAssertTrue(summary.stringValue.contains("告警关闭"))
    }

    func testMetricsSettingsRowsStayCompactAndControlsAreVerticallyCentered() throws {
        let suiteName = "StacioMetricsLayoutSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        try selectSettingsSection("metrics", in: content)
        content.layoutSubtreeIfNeeded()

        let intervalLabel = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsRefreshIntervalSeconds.label") as? NSTextField
        )
        let intervalField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsRefreshIntervalSeconds") as? NSTextField
        )
        let keepLastSwitch = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsKeepLastSnapshotOnFailure.switch") as? NSSwitch
        )
        let showNetworkSwitch = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsShowNetworkSection.switch") as? NSSwitch
        )
        let showDiskSwitch = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsShowDiskSection.switch") as? NSSwitch
        )
        let diskLimitRow = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsDiskMountLimitRow"))
        let diskLimitLabel = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsDiskMountLimit.label") as? NSTextField
        )
        let diskLimitField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsDiskMountLimit") as? NSTextField
        )
        let historyLimitRow = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsHistorySampleCountRow"))
        let hideVirtualNetworksSwitch = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.deviceMetricsHideVirtualNetworkInterfaces.switch") as? NSSwitch
        )

        XCTAssertLessThan(abs(frame(showDiskSwitch, in: content).minY - frame(showNetworkSwitch, in: content).minY), 95)
        XCTAssertLessThan(
            abs(frame(historyLimitRow, in: content).minY - frame(diskLimitRow, in: content).minY),
            95
        )
        XCTAssertLessThanOrEqual(frame(keepLastSwitch, in: content).height, 28)
        XCTAssertLessThanOrEqual(frame(hideVirtualNetworksSwitch, in: content).height, 28)
        XCTAssertEqual(frame(intervalLabel, in: content).midY, frame(intervalField, in: content).midY, accuracy: 1.5)
        XCTAssertEqual(frame(diskLimitLabel, in: content).midY, frame(diskLimitField, in: content).midY, accuracy: 1.5)
    }

    func testSecuritySettingsShowsCredentialCenterAndDeletesSelectedMetadata() throws {
        let suiteName = "StacioCredentialCenterSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let credentialStore = RecordingCredentialCenterStore(credentials: [
            CredentialRecord(
                id: "cred-1",
                kind: "password",
                label: "生产 SSH",
                keychainService: "Stacio",
                keychainAccount: "root@prod.example.com"
            ),
            CredentialRecord(
                id: "cred-2",
                kind: "privateKeyPassphrase",
                label: "跳板机密钥",
                keychainService: "Stacio",
                keychainAccount: "deploy@jump.example.com"
            )
        ])
        let controller = AppSettingsWindowController(
            settingsStore: store,
            credentialCenterStore: credentialStore
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let credentialGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.credentialCenter"))
        let list = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterList") as? NSPopUpButton
        )
        let summary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterSummary") as? NSTextField
        )
        let deleteButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterDelete") as? NSButton
        )

        XCTAssertGreaterThan(credentialGroup.frame.height, 90)
        XCTAssertEqual(list.numberOfItems, 2)
        XCTAssertTrue(list.itemTitle(at: 0).contains("生产 SSH"))
        XCTAssertTrue(list.itemTitle(at: 0).contains("root@prod.example.com"))
        XCTAssertFalse(list.itemTitle(at: 0).contains("secret"))
        XCTAssertTrue(summary.stringValue.contains("2 个凭据引用"))

        deleteButton.performClick(nil)

        XCTAssertEqual(credentialStore.deletedIDs, ["cred-1"])
        XCTAssertEqual(list.numberOfItems, 1)
        XCTAssertTrue(summary.stringValue.contains("1 个凭据引用"))
    }

    func testSecuritySettingsCanAddPasswordCredentialWithoutRenderingSecret() throws {
        let suiteName = "StacioCredentialCenterAddSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let credentialStore = RecordingCredentialCenterStore(credentials: [])
        let controller = AppSettingsWindowController(
            settingsStore: store,
            credentialCenterStore: credentialStore
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let labelField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewLabel") as? NSTextField
        )
        let accountField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewAccount") as? NSTextField
        )
        let secretField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewSecret") as? NSSecureTextField
        )
        let addButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterAddPassword") as? NSButton
        )
        let list = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterList") as? NSPopUpButton
        )
        let summary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterSummary") as? NSTextField
        )

        labelField.stringValue = "生产 SSH"
        labelField.sendAction(labelField.action, to: labelField.target)
        accountField.stringValue = "root@prod.example.com"
        accountField.sendAction(accountField.action, to: accountField.target)
        secretField.stringValue = "super-secret-password"
        secretField.sendAction(secretField.action, to: secretField.target)
        addButton.performClick(nil)

        XCTAssertEqual(credentialStore.saved.count, 1)
        XCTAssertEqual(credentialStore.saved[0].kind, "password")
        XCTAssertEqual(credentialStore.saved[0].label, "生产 SSH")
        XCTAssertEqual(credentialStore.saved[0].account, "root@prod.example.com")
        XCTAssertEqual(credentialStore.saved[0].secret, "super-secret-password")
        XCTAssertEqual(secretField.stringValue, "")
        XCTAssertEqual(list.numberOfItems, 1)
        XCTAssertTrue(list.itemTitle(at: 0).contains("生产 SSH"))
        XCTAssertFalse(list.itemTitle(at: 0).contains("super-secret-password"))
        XCTAssertTrue(summary.stringValue.contains("1 个凭据引用"))
        XCTAssertFalse(summary.stringValue.contains("super-secret-password"))
    }

    func testSecuritySettingsCanAddPrivateKeyPassphraseCredentialWithoutRenderingSecret() throws {
        let suiteName = "StacioCredentialCenterKeyPassphraseSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let credentialStore = RecordingCredentialCenterStore(credentials: [])
        let controller = AppSettingsWindowController(
            settingsStore: store,
            credentialCenterStore: credentialStore
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let labelField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewLabel") as? NSTextField
        )
        let accountField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewAccount") as? NSTextField
        )
        let secretField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewSecret") as? NSSecureTextField
        )
        let addButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterAddPrivateKeyPassphrase") as? NSButton
        )
        let list = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterList") as? NSPopUpButton
        )
        let summary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterSummary") as? NSTextField
        )

        labelField.stringValue = "跳板机密钥"
        labelField.sendAction(labelField.action, to: labelField.target)
        accountField.stringValue = "deploy@jump.example.com"
        accountField.sendAction(accountField.action, to: accountField.target)
        secretField.stringValue = "key-passphrase-secret"
        secretField.sendAction(secretField.action, to: secretField.target)
        addButton.performClick(nil)

        XCTAssertEqual(credentialStore.saved.count, 1)
        XCTAssertEqual(credentialStore.saved[0].kind, "private_key_passphrase")
        XCTAssertEqual(credentialStore.saved[0].label, "跳板机密钥")
        XCTAssertEqual(credentialStore.saved[0].account, "deploy@jump.example.com")
        XCTAssertEqual(credentialStore.saved[0].secret, "key-passphrase-secret")
        XCTAssertEqual(secretField.stringValue, "")
        XCTAssertEqual(list.numberOfItems, 1)
        XCTAssertTrue(list.itemTitle(at: 0).contains("跳板机密钥"))
        XCTAssertFalse(list.itemTitle(at: 0).contains("key-passphrase-secret"))
        XCTAssertTrue(summary.stringValue.contains("1 个凭据引用"))
        XCTAssertFalse(summary.stringValue.contains("key-passphrase-secret"))
    }

    func testSecuritySettingsCanAddTokenCredentialWithoutRenderingSecret() throws {
        let suiteName = "StacioCredentialCenterTokenSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let credentialStore = RecordingCredentialCenterStore(credentials: [])
        let controller = AppSettingsWindowController(
            settingsStore: store,
            credentialCenterStore: credentialStore
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let labelField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewLabel") as? NSTextField
        )
        let accountField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewAccount") as? NSTextField
        )
        let secretField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewSecret") as? NSSecureTextField
        )
        let addButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterAddToken") as? NSButton
        )
        let list = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterList") as? NSPopUpButton
        )
        let summary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterSummary") as? NSTextField
        )

        labelField.stringValue = "GitLab Token"
        labelField.sendAction(labelField.action, to: labelField.target)
        accountField.stringValue = "gitlab.example.com/deploy"
        accountField.sendAction(accountField.action, to: accountField.target)
        secretField.stringValue = "glpat-secret-token"
        secretField.sendAction(secretField.action, to: secretField.target)
        addButton.performClick(nil)

        XCTAssertEqual(credentialStore.saved.count, 1)
        XCTAssertEqual(credentialStore.saved[0].kind, "token")
        XCTAssertEqual(credentialStore.saved[0].label, "GitLab Token")
        XCTAssertEqual(credentialStore.saved[0].account, "gitlab.example.com/deploy")
        XCTAssertEqual(credentialStore.saved[0].secret, "glpat-secret-token")
        XCTAssertEqual(secretField.stringValue, "")
        XCTAssertEqual(list.numberOfItems, 1)
        XCTAssertTrue(list.itemTitle(at: 0).contains("GitLab Token"))
        XCTAssertFalse(list.itemTitle(at: 0).contains("glpat-secret-token"))
        XCTAssertTrue(summary.stringValue.contains("1 个凭据引用"))
        XCTAssertFalse(summary.stringValue.contains("glpat-secret-token"))
    }

    func testCredentialCenterAddButtonsEnableWhileTypingRequiredFields() throws {
        let suiteName = "StacioCredentialCenterLiveValidationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppSettingsWindowController(
            settingsStore: AppSettingsStore(defaults: defaults),
            credentialCenterStore: RecordingCredentialCenterStore(credentials: [])
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let accountField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewAccount") as? NSTextField
        )
        let secretField = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterNewSecret") as? NSSecureTextField
        )
        let addButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterAddPassword") as? NSButton
        )
        let addPrivateKeyButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterAddPrivateKeyPassphrase") as? NSButton
        )
        let addTokenButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.credentialCenterAddToken") as? NSButton
        )

        XCTAssertFalse(addButton.isEnabled)
        XCTAssertFalse(addPrivateKeyButton.isEnabled)
        XCTAssertFalse(addTokenButton.isEnabled)

        accountField.stringValue = "root@prod.example.com"
        accountField.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: accountField)
        )
        XCTAssertFalse(addButton.isEnabled)
        XCTAssertFalse(addPrivateKeyButton.isEnabled)
        XCTAssertFalse(addTokenButton.isEnabled)

        secretField.stringValue = "typed-secret"
        secretField.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: secretField)
        )

        XCTAssertTrue(addButton.isEnabled)
        XCTAssertTrue(addPrivateKeyButton.isEnabled)
        XCTAssertTrue(addTokenButton.isEnabled)
    }

    func testSecuritySettingsExplainsGlobalAndSessionPolicyOverrideOrder() throws {
        let suiteName = "StacioSecurityPolicySettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let policyGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.sessionPolicy"))
        let overrideSummary = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.sessionPolicyOverrideSummary") as? NSTextField
        )
        let sessionEntry = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.sessionPolicyEntry") as? NSTextField
        )

        XCTAssertGreaterThan(policyGroup.frame.height, 90)
        XCTAssertTrue(overrideSummary.stringValue.contains("全局命令确认"))
        XCTAssertTrue(overrideSummary.stringValue.contains("生产环境强制确认"))
        XCTAssertTrue(overrideSummary.stringValue.contains("会话 AI 执行策略"))
        XCTAssertTrue(sessionEntry.stringValue.contains("新建/编辑会话"))
    }

    func testSecuritySettingsShowsCopyableOperationalPaths() throws {
        let suiteName = "StacioSecurityPathSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let securityNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.security") as? NSButton
        )
        securityNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        let storageGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.securityStorage"))
        let appSupportPath = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.path.applicationSupport") as? NSTextField
        )
        let databasePath = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.path.database") as? NSTextField
        )
        let logPath = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.path.log") as? NSTextField
        )
        let copyDatabaseButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.copy.databasePath") as? NSButton
        )

        XCTAssertGreaterThan(storageGroup.frame.height, 120)
        XCTAssertTrue(appSupportPath.stringValue.contains("Stacio"))
        XCTAssertTrue(databasePath.stringValue.hasSuffix("Stacio.sqlite"))
        XCTAssertTrue(logPath.stringValue.hasSuffix("stacio.log"))

        NSPasteboard.general.clearContents()
        copyDatabaseButton.performClick(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), databasePath.stringValue)
    }

    func testAISettingsCanClearConversationHistory() throws {
        let suiteName = "StacioAIConversationHistorySettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let historyStore = RecordingSettingsAIConversationHistoryStore()
        let controller = AppSettingsWindowController(
            settingsStore: store,
            conversationHistoryStore: historyStore
        )

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()
        try selectAISettingsTab("历史", in: content)

        let historyGroup = try XCTUnwrap(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiConversationHistory"))
        let clearButton = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.clearAIConversationHistory") as? NSButton
        )

        XCTAssertGreaterThan(historyGroup.frame.height, 40)
        clearButton.performClick(nil)
        XCTAssertEqual(historyStore.clearCount, 1)
    }

    func testAISettingsUsesInternalTabScrollingAndOwnsHistoryControls() throws {
        let suiteName = "StacioScrollableSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)

        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let aiNavigation = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.nav.ai") as? NSButton
        )
        aiNavigation.performClick(nil)
        content.layoutSubtreeIfNeeded()

        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.contentScrollView"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.ai.tabs"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProviders.manager"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiProvider"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiBaseURL"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiModel"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiModelCatalog"))

        try selectAISettingsTab("执行与权限", in: content)
        let executionScrollView = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.ai.execution.scroll") as? NSScrollView
        )
        XCTAssertTrue(executionScrollView.hasVerticalScroller)
        XCTAssertFalse(executionScrollView.drawsBackground)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiExecution"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.agentBridge"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiConversationHistory"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.clearAIConversationHistory"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiConversationHistoryStatus"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiConversationHistoryHelp"))

        try selectAISettingsTab("历史", in: content)
        let historyScrollView = try XCTUnwrap(
            content.firstSubview(withIdentifier: "Stacio.Settings.ai.history.scroll") as? NSScrollView
        )
        XCTAssertTrue(historyScrollView.hasVerticalScroller)
        XCTAssertFalse(historyScrollView.drawsBackground)
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.aiConversationHistory"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.clearAIConversationHistory"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiConversationHistoryStatus"))
        XCTAssertNotNil(content.firstSubview(withIdentifier: "Stacio.Settings.aiConversationHistoryHelp"))
        XCTAssertNil(content.firstSubview(withIdentifier: "Stacio.Settings.group.agentBridge"))
    }

    func testTerminalPaneAppliesStoredFontSizeAndTheme() {
        let suiteName = "StacioPaneSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.terminalFontSize = 15
            settings.terminalFontFamily = .menlo
            settings.terminalTheme = .dark
            settings.terminalCursorShape = .bar
            settings.terminalCursorBlinkEnabled = false
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_settings",
            shellPath: "/bin/zsh",
            eventSink: RecordingSettingsTerminalEventSink(),
            settingsStore: store,
            autoStartProcess: false
        )

        controller.loadView()

        XCTAssertEqual(controller.terminalView.font.pointSize, 15)
        XCTAssertEqual(controller.terminalView.font.familyName, "Menlo")
        XCTAssertEqual(controller.terminalView.terminal.options.cursorStyle, .steadyBar)
        XCTAssertEqual(controller.terminalView.nativeBackgroundColor.portDeskHexString, TerminalColorTheme.portDeskDark.backgroundHex)
        XCTAssertEqual(controller.terminalView.nativeForegroundColor.portDeskHexString, TerminalColorTheme.portDeskDark.foregroundHex)
    }

    func testOpenTerminalPanesApplySettingsUpdatesLive() {
        let suiteName = "StacioLivePaneSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let local = TerminalPaneViewController(
            runtimeID: "term_local_settings",
            shellPath: "/bin/zsh",
            eventSink: RecordingSettingsTerminalEventSink(),
            settingsStore: store,
            autoStartProcess: false
        )
        let remote = RemoteTerminalPaneViewController(
            runtimeID: "term_remote_settings",
            title: "deploy@example.com",
            eventSink: RecordingSettingsTerminalEventSink(),
            settingsStore: store,
            startsPollingAutomatically: false
        )

        local.loadView()
        remote.loadView()
        store.update { settings in
            settings.terminalFontSize = 18
            settings.terminalTheme = .dark
        }

        XCTAssertEqual(local.terminalView.font.pointSize, 18)
        XCTAssertEqual(remote.terminalView.font.pointSize, 18)
        XCTAssertEqual(local.terminalView.nativeBackgroundColor.portDeskHexString, TerminalColorTheme.portDeskDark.backgroundHex)
        XCTAssertEqual(remote.terminalView.nativeForegroundColor.portDeskHexString, TerminalColorTheme.portDeskDark.foregroundHex)
    }
}

private final class RecordingSettingsTerminalEventSink: TerminalEventSink {
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidClose(runtimeID: String) throws {}
}

private final class RecordingAIModelCatalogLoader: AIModelCatalogLoading {
    let models: [String]
    private(set) var snapshots: [AIProviderConfiguration] = []

    init(models: [String]) {
        self.models = models
    }

    func listModels(
        for provider: AIProviderConfiguration,
        apiKey: String?
    ) throws -> [String] {
        snapshots.append(provider)
        return models
    }
}

private final class RecordingStacioCacheMaintenance: StacioCacheMaintaining {
    private(set) var summary: StacioCacheSummary
    private(set) var clearCount = 0

    init(summary: StacioCacheSummary) {
        self.summary = summary
    }

    func cacheSummary() throws -> StacioCacheSummary {
        summary
    }

    func clearAllCaches() throws -> StacioCacheClearResult {
        clearCount += 1
        let result = StacioCacheClearResult(bytesCleared: summary.totalBytes)
        summary = StacioCacheSummary(totalBytes: 0, dirtyRemoteEditItemCount: 0)
        return result
    }
}

@MainActor
private final class RecordingAppSettingsCacheClearPresenter: AppSettingsCacheClearPresenting {
    private let shouldConfirm: Bool
    private(set) var confirmedSummaries: [StacioCacheSummary] = []
    private(set) var completedBytesCleared: [UInt64] = []
    private(set) var errors: [Error] = []

    init(shouldConfirm: Bool) {
        self.shouldConfirm = shouldConfirm
    }

    func confirmClearCaches(summary: StacioCacheSummary, parentWindow: NSWindow?) -> Bool {
        confirmedSummaries.append(summary)
        return shouldConfirm
    }

    func presentClearCachesComplete(result: StacioCacheClearResult, parentWindow: NSWindow?) {
        completedBytesCleared.append(result.bytesCleared)
    }

    func presentClearCachesError(_ error: Error, parentWindow: NSWindow?) {
        errors.append(error)
    }
}

private final class RecordingCredentialCenterStore: CredentialCenterManaging {
    struct SavedCredential: Equatable {
        let kind: String
        let label: String
        let account: String
        let secret: String
    }

    private var credentials: [CredentialRecord]
    private(set) var deletedIDs: [String] = []
    private(set) var saved: [SavedCredential] = []

    init(credentials: [CredentialRecord]) {
        self.credentials = credentials
    }

    func listCredentials() throws -> [CredentialRecord] {
        credentials
    }

    func saveCredential(kind: String, label: String, account: String, secret: String) throws -> CredentialRecord {
        saved.append(SavedCredential(kind: kind, label: label, account: account, secret: secret))
        let record = CredentialRecord(
            id: "cred-\(saved.count)",
            kind: kind,
            label: label,
            keychainService: KeychainCredentialStore.serviceName,
            keychainAccount: account
        )
        credentials.append(record)
        return record
    }

    func deleteCredential(id: String) throws {
        deletedIDs.append(id)
        credentials.removeAll { $0.id == id }
    }
}

private final class RecordingSettingsAIConversationHistoryStore: AIAssistantConversationHistoryStoring {
    private(set) var clearCount = 0

    func appendConversationHistoryItem(
        runtimeID: String,
        role: AIConversationHistoryRole,
        content: String,
        requestID: String?
    ) throws -> AIConversationHistoryItemRecord {
        AIConversationHistoryItemRecord(
            id: UUID().uuidString,
            runtimeId: runtimeID,
            role: role.rawValue,
            content: content,
            requestId: requestID,
            createdAt: "2026-07-02T00:00:00Z"
        )
    }

    func listConversationHistory(runtimeID: String) throws -> [AIConversationHistoryItemRecord] {
        []
    }

    func clearConversationHistory() throws {
        clearCount += 1
    }
}

@MainActor
private final class RecordingUpdateChannelConfirmation: AppSettingsUpdateChannelConfirming {
    struct Change: Equatable {
        let from: ProductOpsReleaseChannel
        let to: ProductOpsReleaseChannel
    }

    private var decisions: [Bool]
    private(set) var requestedChanges: [Change] = []

    init(decisions: [Bool]) {
        self.decisions = decisions
    }

    func confirmUpdateChannelChange(
        from current: ProductOpsReleaseChannel,
        to proposed: ProductOpsReleaseChannel,
        parentWindow: NSWindow?
    ) -> Bool {
        requestedChanges.append(Change(from: current, to: proposed))
        return decisions.isEmpty ? false : decisions.removeFirst()
    }
}

private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }

        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }

        return nil
    }

    func firstTextField(containing text: String) -> NSTextField? {
        if let textField = self as? NSTextField, textField.stringValue.contains(text) {
            return textField
        }

        for subview in subviews {
            if let match = subview.firstTextField(containing: text) {
                return match
            }
        }

        return nil
    }

    func allSubviews<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            var matches = subview.allSubviews(ofType: type)
            if let typed = subview as? T {
                matches.insert(typed, at: 0)
            }
            return matches
        }
    }
}
