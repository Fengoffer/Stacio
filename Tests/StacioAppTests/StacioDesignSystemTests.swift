import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class StacioDesignSystemTests: XCTestCase {
    func testSystemAdaptiveThemeUsesMacOSSemanticColors() {
        let theme = StacioDesignSystem.Theme.codex

        XCTAssertEqual(theme.panelCornerRadius, 8)
        XCTAssertEqual(theme.controlCornerRadius, 7)
        XCTAssertEqual(theme.fastAnimationDuration, 0.12, accuracy: 0.01)
        XCTAssertEqual(theme.standardAnimationDuration, 0.18, accuracy: 0.01)
        XCTAssertEqual(theme.windowBackgroundColor, .windowBackgroundColor)
        XCTAssertEqual(theme.sidebarBackgroundColor, .windowBackgroundColor)
        XCTAssertEqual(theme.workspaceBackgroundColor, .windowBackgroundColor)
        XCTAssertEqual(theme.panelBackgroundColor, .controlBackgroundColor)
        XCTAssertEqual(theme.primaryTextColor, .labelColor)
        XCTAssertEqual(theme.secondaryTextColor, .secondaryLabelColor)
    }

    func testWorkbenchWindowUsesStandardMacDocumentChrome() throws {
        let controller = WorkbenchWindowController()

        controller.loadWindow()

        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
        XCTAssertNil(window.appearance)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertEqual(rootView.accessibilityIdentifier(), "Stacio.Chrome.root")
        XCTAssertEqual(rootView.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual(rootView.layer?.borderWidth ?? 0, 0)
        XCTAssertEqual(rootView.layer?.backgroundColor, StacioDesignSystem.Theme.codex.windowBackgroundColor.cgColor)
    }

    func testSidebarUsesNativeSourceListSurface() throws {
        let controller = SessionSidebarViewController()

        controller.loadView()

        XCTAssertEqual(controller.view.accessibilityIdentifier(), "Stacio.Sidebar.surface")
        XCTAssertEqual(controller.view.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual(controller.view.layer?.borderWidth ?? 0, 0)
        XCTAssertEqual((controller.view as? NSVisualEffectView)?.material, .sidebar)
        XCTAssertEqual((controller.view as? NSVisualEffectView)?.blendingMode, .behindWindow)
        XCTAssertNil(controller.view.layer?.backgroundColor)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.header"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.search"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.sessionOutline"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.a2Footer"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.compactQuickActions"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.quickConnect"))
    }

    func testInspectorUsesLightNativeSurface() throws {
        let controller = InspectorViewController(transferHistoryStore: NoOpSCPTransferHistoryStore())

        controller.loadView()

        XCTAssertEqual(controller.view.accessibilityIdentifier(), "Stacio.Inspector.surface")
        XCTAssertEqual(controller.view.layer?.borderWidth ?? 0, 0)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Inspector.header"))
        XCTAssertNil(controller.sectionControlForTesting.enclosingScrollView)
    }

    func testInspectorHeaderUsesEditorActionToolbarWithoutInspectorTitle() throws {
        let controller = InspectorViewController(transferHistoryStore: NoOpSCPTransferHistoryStore())

        controller.loadView()

        let header = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Inspector.header") as? NSStackView)
        XCTAssertEqual(header.orientation, .vertical)
        XCTAssertEqual(header.spacing, 10)
        XCTAssertNil(controller.view.firstTextField(withString: "检查器"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorClose"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorCollapse"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorBackup"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorRestore"))
        XCTAssertGreaterThanOrEqual(controller.sectionControlForTesting.segmentCount, 4)
        XCTAssertNil(controller.sectionControlForTesting.enclosingScrollView)
    }

    func testNativeTablesAvoidHeavyStripedBackgrounds() {
        let tableView = NSTableView()

        StacioDesignSystem.styleTable(tableView)

        XCTAssertFalse(tableView.usesAlternatingRowBackgroundColors)
        XCTAssertEqual(tableView.backgroundColor, .clear)
        XCTAssertEqual(tableView.gridStyleMask, [])
        XCTAssertEqual(tableView.selectionHighlightStyle, .regular)
    }

    func testDynamicLayerColorsRefreshWhenEffectiveAppearanceChanges() throws {
        let root = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let child = NSView(frame: root.bounds)
        root.addSubview(child)

        root.appearance = NSAppearance(named: .aqua)
        StacioDesignSystem.setLayerBackgroundColor(child, color: .textBackgroundColor)
        let lightColor = try XCTUnwrap(child.layer?.backgroundColor)

        root.appearance = NSAppearance(named: .darkAqua)
        StacioDesignSystem.refreshDynamicLayerColors(in: root)

        let darkColor = try XCTUnwrap(child.layer?.backgroundColor)
        XCTAssertNotEqual(lightColor, darkColor)
        XCTAssertEqual(
            darkColor,
            StacioDesignSystem.resolvedLayerColor(.textBackgroundColor, for: root)
        )
    }

    func testTextFieldsUseReadableNativeFormBackground() {
        let field = NSTextField(string: "")

        StacioDesignSystem.styleTextField(field)

        XCTAssertTrue(field.isBezeled)
        XCTAssertEqual(field.bezelStyle, .roundedBezel)
        XCTAssertEqual(field.backgroundColor, .textBackgroundColor)
        XCTAssertFalse(field.wantsLayer)
        XCTAssertNil(field.layer?.backgroundColor)
    }

    func testStyledTextFieldsKeepTextLeadingEdgeStableWhenEditing() throws {
        let field = NSTextField(string: "10.10.10.100")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 36)
        field.isEditable = true
        field.isSelectable = true

        StacioDesignSystem.styleTextField(field)

        let cell = try XCTUnwrap(field.cell as? NSTextFieldCell)
        let bounds = field.bounds
        let drawingRect = cell.drawingRect(forBounds: bounds)
        let titleRect = cell.titleRect(forBounds: bounds)
        let editor = NSTextView(frame: .zero)

        cell.edit(
            withFrame: bounds,
            in: field,
            editor: editor,
            delegate: nil,
            event: nil
        )
        let editLeading = editor.frame.minX

        cell.select(
            withFrame: bounds,
            in: field,
            editor: editor,
            delegate: nil,
            start: 0,
            length: field.stringValue.count
        )
        let selectLeading = editor.frame.minX

        XCTAssertEqual(drawingRect.minX, titleRect.minX, accuracy: 0.5)
        XCTAssertEqual(drawingRect.minX, editLeading, accuracy: 0.5)
        XCTAssertEqual(drawingRect.minX, selectLeading, accuracy: 0.5)
    }

    func testStyledTextFieldsApplyOpticalVerticalTextCorrection() throws {
        let field = NSTextField(string: "10.10.10.100")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 36)
        field.isEditable = true
        field.isSelectable = true

        StacioDesignSystem.styleTextField(field)

        let cell = try XCTUnwrap(field.cell as? NSTextFieldCell)
        let drawingRect = cell.drawingRect(forBounds: field.bounds)
        let editor = NSTextView(frame: .zero)

        cell.edit(
            withFrame: field.bounds,
            in: field,
            editor: editor,
            delegate: nil,
            event: nil
        )

        XCTAssertEqual(drawingRect.midY, field.bounds.midY, accuracy: 0.5)
        XCTAssertLessThanOrEqual(drawingRect.height, 22)
        XCTAssertEqual(editor.frame.midY, drawingRect.midY, accuracy: 0.5)
        XCTAssertEqual(editor.frame.minY, drawingRect.minY, accuracy: 0.5)
        XCTAssertEqual(editor.frame.height, drawingRect.height, accuracy: 0.5)
    }

    func testStyledTextFieldsKeepDisplayEditAndSelectContentVerticallyCentered() throws {
        let field = NSTextField(string: "deploy@example.com")
        field.frame = NSRect(x: 0, y: 0, width: 252, height: 36)
        field.isEditable = true
        field.isSelectable = true

        StacioDesignSystem.styleTextField(field)

        let cell = try XCTUnwrap(field.cell as? NSTextFieldCell)
        let bounds = field.bounds
        let displayRect = cell.drawingRect(forBounds: bounds)
        let editEditor = NSTextView(frame: .zero)
        let selectEditor = NSTextView(frame: .zero)

        cell.edit(
            withFrame: bounds,
            in: field,
            editor: editEditor,
            delegate: nil,
            event: nil
        )
        cell.select(
            withFrame: bounds,
            in: field,
            editor: selectEditor,
            delegate: nil,
            start: 0,
            length: field.stringValue.count
        )

        XCTAssertEqual(displayRect.midY, bounds.midY, accuracy: 0.5)
        XCTAssertEqual(editEditor.frame.midY, bounds.midY, accuracy: 0.5)
        XCTAssertEqual(selectEditor.frame.midY, bounds.midY, accuracy: 0.5)
        XCTAssertEqual(displayRect.minX, editEditor.frame.minX, accuracy: 0.5)
        XCTAssertEqual(displayRect.minX, selectEditor.frame.minX, accuracy: 0.5)
    }

    func testStyledSecureTextFieldsUseSameTextInsetForDisplayRectangles() throws {
        let field = NSSecureTextField(string: "secret")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 36)
        field.isEditable = true
        field.isSelectable = true

        StacioDesignSystem.styleTextField(field)

        let cell = try XCTUnwrap(field.cell as? NSTextFieldCell)
        let bounds = field.bounds
        let drawingRect = cell.drawingRect(forBounds: bounds)
        let titleRect = cell.titleRect(forBounds: bounds)

        XCTAssertEqual(drawingRect.minX, titleRect.minX, accuracy: 0.5)
        XCTAssertEqual(drawingRect.minX, 10, accuracy: 0.5)
        XCTAssertEqual(drawingRect.midY, field.bounds.midY, accuracy: 0.5)
        XCTAssertLessThanOrEqual(drawingRect.height, 22)
    }

    func testWorkspaceShowsCodexEmptyWorkbenchWhenNoSessionIsOpen() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)

        workspace.loadView()

        let emptyPrompt = try XCTUnwrap(
            workspace.view.firstSubview(withIdentifier: "Stacio.Workspace.emptyPrompt") as? NSTextField
        )
        XCTAssertEqual(emptyPrompt.stringValue, "开始连接")
        XCTAssertFalse(emptyPrompt.isHidden)

        try workspace.openLocalShell()

        XCTAssertTrue(emptyPrompt.isHidden)
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

    func firstTextField(withString value: String) -> NSTextField? {
        if let textField = self as? NSTextField,
           textField.stringValue == value
        {
            return textField
        }

        for subview in subviews {
            if let match = subview.firstTextField(withString: value) {
                return match
            }
        }
        return nil
    }
}
