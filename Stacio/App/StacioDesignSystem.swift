import AppKit
import ObjectiveC
import QuartzCore

public enum StacioDesignSystem {
    public struct Theme {
        public let windowBackgroundColor: NSColor
        public let toolbarBackgroundColor: NSColor
        public let sidebarBackgroundColor: NSColor
        public let workspaceBackgroundColor: NSColor
        public let panelBackgroundColor: NSColor
        public let elevatedPanelColor: NSColor
        public let controlBackgroundColor: NSColor
        public let controlHoverColor: NSColor
        public let accentColor: NSColor
        public let successColor: NSColor
        public let warningColor: NSColor
        public let dangerColor: NSColor
        public let focusRingColor: NSColor
        public let separatorColor: NSColor
        public let primaryTextColor: NSColor
        public let secondaryTextColor: NSColor
        public let windowCornerRadius: CGFloat
        public let panelCornerRadius: CGFloat
        public let controlCornerRadius: CGFloat
        public let fastAnimationDuration: TimeInterval
        public let standardAnimationDuration: TimeInterval

        public static let codex = Theme(
            windowBackgroundColor: .windowBackgroundColor,
            toolbarBackgroundColor: .windowBackgroundColor,
            sidebarBackgroundColor: .windowBackgroundColor,
            workspaceBackgroundColor: .windowBackgroundColor,
            panelBackgroundColor: .controlBackgroundColor,
            elevatedPanelColor: .textBackgroundColor,
            controlBackgroundColor: .controlBackgroundColor,
            controlHoverColor: .selectedControlColor,
            accentColor: .controlAccentColor,
            successColor: NSColor.systemGreen,
            warningColor: NSColor.systemYellow,
            dangerColor: NSColor.systemRed,
            focusRingColor: .keyboardFocusIndicatorColor,
            separatorColor: .separatorColor,
            primaryTextColor: .labelColor,
            secondaryTextColor: .secondaryLabelColor,
            windowCornerRadius: 14,
            panelCornerRadius: 8,
            controlCornerRadius: 7,
            fastAnimationDuration: 0.12,
            standardAnimationDuration: 0.18
        )
    }

    public static let theme = Theme.codex

    public static func applyWindowChrome(_ window: NSWindow) {
        window.appearance = nil
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = theme.windowBackgroundColor
        window.isMovableByWindowBackground = false
    }

    public static func applyRootSurface(_ view: NSView) {
        applySurface(
            view,
            color: theme.windowBackgroundColor,
            cornerRadius: 0,
            borderColor: nil,
            borderWidth: 0
        )
        view.setAccessibilityIdentifier("Stacio.Chrome.root")
    }

    public static func applySidebarSurface(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = nil
        view.layer?.cornerRadius = 0
        view.layer?.cornerCurve = .continuous
        view.layer?.borderColor = nil
        view.layer?.borderWidth = 0
        if let visualEffectView = view as? NSVisualEffectView {
            visualEffectView.material = .sidebar
            visualEffectView.blendingMode = .behindWindow
            visualEffectView.state = .active
            visualEffectView.isEmphasized = false
        }
        view.setAccessibilityIdentifier("Stacio.Sidebar.surface")
    }

    public static func applyWorkspaceSurface(_ view: NSView) {
        applySurface(view, color: theme.workspaceBackgroundColor, cornerRadius: 0)
    }

    public static func metricsFloatingSurfaceColor(for view: NSView) -> NSColor {
        metricsFloatingSurfaceColor(for: view.effectiveAppearance)
    }

    public static func metricsFloatingSurfaceColor(for appearance: NSAppearance) -> NSColor {
        let background = resolvedColor(theme.elevatedPanelColor, for: appearance)
        return background.withAlphaComponent(0.92)
    }

    public static func applyCommandSurface(_ view: NSView) {
        applySurface(
            view,
            color: NSColor.clear,
            cornerRadius: 0,
            borderColor: nil,
            borderWidth: 0
        )
    }

    public static func applyConnectionBarSurface(_ view: NSView) {
        applySurface(
            view,
            color: theme.elevatedPanelColor.withAlphaComponent(0.82),
            cornerRadius: theme.panelCornerRadius,
            borderColor: nil,
            borderWidth: 0
        )
    }

    public static func applyInspectorSurface(_ view: NSView) {
        applySurface(
            view,
            color: theme.windowBackgroundColor,
            cornerRadius: 0,
            borderColor: nil,
            borderWidth: 0
        )
        view.setAccessibilityIdentifier("Stacio.Inspector.surface")
    }

    public static func applyInspectorContentSurface(_ view: NSView) {
        applySurface(
            view,
            color: theme.windowBackgroundColor,
            cornerRadius: 0,
            borderColor: nil,
            borderWidth: 0
        )
    }

    public static func applyPanelSurface(_ view: NSView) {
        applySurface(
            view,
            color: theme.panelBackgroundColor,
            cornerRadius: theme.panelCornerRadius,
            borderColor: theme.separatorColor.withAlphaComponent(0.55),
            borderWidth: 1
        )
    }

    public static func stylePrimaryButton(_ button: NSButton) {
        styleButton(button, backgroundColor: theme.controlBackgroundColor)
        button.contentTintColor = theme.primaryTextColor
    }

    public static func styleAccentButton(_ button: NSButton) {
        styleButton(button, backgroundColor: theme.accentColor)
        button.contentTintColor = .white
    }

    public static func styleIconButton(_ button: NSButton) {
        styleButton(button, backgroundColor: NSColor.clear)
        button.contentTintColor = theme.secondaryTextColor
    }

    public static func styleToolbarButton(_ button: NSButton) {
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = theme.controlCornerRadius
        button.layer?.cornerCurve = .continuous
        setLayerBackgroundColor(button, color: .clear)
        button.layer?.borderWidth = 0
        button.contentTintColor = theme.primaryTextColor
        if let hoverButton = button as? StacioHoverButton {
            hoverButton.setNormalBackgroundColor(.clear)
        }
    }

    public static func styleProminentButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = theme.controlCornerRadius
        button.layer?.cornerCurve = .continuous
        setLayerBackgroundColor(button, color: theme.accentColor)
        button.layer?.borderWidth = 0
        button.contentTintColor = .white
        if let hoverButton = button as? StacioHoverButton {
            hoverButton.setNormalBackgroundColor(theme.accentColor)
        }
    }

    public static func styleSearchField(_ searchField: NSSearchField) {
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = theme.controlCornerRadius
        setLayerBackgroundColor(searchField, color: theme.controlBackgroundColor)
        searchField.layer?.borderWidth = 0
        setLayerBorderColor(searchField, color: nil)
        searchField.focusRingType = .default
    }

    public static func styleTextField(_ textField: NSTextField) {
        if let comboBox = textField as? NSComboBox {
            styleComboBox(comboBox)
            return
        }
        installPaddedTextFieldCellIfNeeded(textField)
        textField.wantsLayer = false
        textField.layer?.backgroundColor = nil
        textField.layer?.borderColor = nil
        textField.layer?.borderWidth = 0
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.drawsBackground = true
        textField.focusRingType = .default
        textField.textColor = theme.primaryTextColor
        textField.backgroundColor = .textBackgroundColor
        textField.controlSize = .large
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
    }

    private static func styleComboBox(_ comboBox: NSComboBox) {
        comboBox.wantsLayer = false
        comboBox.layer?.backgroundColor = nil
        comboBox.layer?.borderColor = nil
        comboBox.layer?.borderWidth = 0
        comboBox.isBezeled = true
        comboBox.bezelStyle = .roundedBezel
        comboBox.drawsBackground = true
        comboBox.focusRingType = .default
        comboBox.textColor = theme.primaryTextColor
        comboBox.backgroundColor = .textBackgroundColor
        comboBox.controlSize = .large
        comboBox.font = .systemFont(ofSize: NSFont.systemFontSize)
    }

    public static func styleCompactTextField(_ textField: NSTextField) {
        styleTextField(textField)
        textField.controlSize = .regular
        textField.cell?.controlSize = .regular
    }

    public static func styleSheetButton(_ button: NSButton, isDefault: Bool = false) {
        button.bezelStyle = .rounded
        button.isBordered = true
        button.wantsLayer = false
        button.contentTintColor = nil
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        if isDefault {
            button.keyEquivalent = "\r"
        }
    }

    public static func styleConnectionTextField(_ textField: NSTextField) {
        textField.wantsLayer = true
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .default
        textField.textColor = theme.primaryTextColor
        textField.layer?.cornerRadius = theme.controlCornerRadius
        setLayerBackgroundColor(textField, color: NSColor.textBackgroundColor.withAlphaComponent(0.9))
        textField.layer?.borderWidth = 0
    }

    public static func stylePopupButton(_ popupButton: NSPopUpButton) {
        popupButton.bezelStyle = .rounded
        popupButton.isBordered = true
        popupButton.wantsLayer = false
        popupButton.controlSize = .large
        popupButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        popupButton.contentTintColor = theme.primaryTextColor
    }

    public static func styleSegmentedControl(_ segmentedControl: NSSegmentedControl) {
        segmentedControl.segmentStyle = .texturedRounded
        segmentedControl.wantsLayer = true
        segmentedControl.layer?.cornerRadius = theme.controlCornerRadius
        setLayerBackgroundColor(segmentedControl, color: .clear)
        segmentedControl.layer?.borderWidth = 0
    }

    public static func styleTable(_ tableView: NSTableView) {
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = false
    }

    public static func fadeIn(_ view: NSView) {
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = theme.standardAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
        }
    }

    private static func styleButton(_ button: NSButton, backgroundColor: NSColor) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = theme.controlCornerRadius
        setLayerBackgroundColor(button, color: backgroundColor)
        button.layer?.borderWidth = backgroundColor == NSColor.clear ? 0 : 1
        setLayerBorderColor(button, color: theme.separatorColor.withAlphaComponent(0.45))
        if let hoverButton = button as? StacioHoverButton {
            hoverButton.setNormalBackgroundColor(backgroundColor)
        }
    }

    private static func installPaddedTextFieldCellIfNeeded(_ textField: NSTextField) {
        if textField.cell is StacioPaddedTextFieldCell || textField.cell is StacioPaddedSecureTextFieldCell {
            return
        }
        let existingCell = textField.cell
        let currentValue = textField.stringValue
        let placeholder = textField.placeholderString
        let target = textField.target
        let action = textField.action
        let delegate = textField.delegate
        let paddedCell: NSTextFieldCell = textField is NSSecureTextField
            ? StacioPaddedSecureTextFieldCell(textCell: currentValue)
            : StacioPaddedTextFieldCell(textCell: currentValue)
        paddedCell.placeholderString = placeholder
        paddedCell.controlSize = .large
        paddedCell.font = .systemFont(ofSize: NSFont.systemFontSize)
        paddedCell.isEditable = existingCell?.isEditable ?? true
        paddedCell.isSelectable = existingCell?.isSelectable ?? true
        paddedCell.isBezeled = true
        paddedCell.isBordered = true
        paddedCell.drawsBackground = true
        paddedCell.backgroundColor = .textBackgroundColor
        paddedCell.usesSingleLineMode = true
        paddedCell.isScrollable = true
        textField.cell = paddedCell
        textField.stringValue = currentValue
        textField.target = target
        textField.action = action
        textField.delegate = delegate
    }

    private static func applySurface(
        _ view: NSView,
        color: NSColor,
        cornerRadius: CGFloat,
        borderColor: NSColor? = nil,
        borderWidth: CGFloat = 0
    ) {
        view.wantsLayer = true
        setLayerBackgroundColor(view, color: color)
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        setLayerBorderColor(view, color: borderColor)
        view.layer?.borderWidth = borderWidth
    }

    public static func setLayerBackgroundColor(_ view: NSView, color: NSColor?) {
        view.wantsLayer = true
        objc_setAssociatedObject(
            view,
            &StacioLayerColorAssociation.backgroundColor,
            color,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        view.layer?.backgroundColor = color.map { resolvedLayerColor($0, for: view) }
    }

    public static func setLayerBorderColor(_ view: NSView, color: NSColor?) {
        view.wantsLayer = true
        objc_setAssociatedObject(
            view,
            &StacioLayerColorAssociation.borderColor,
            color,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        view.layer?.borderColor = color.map { resolvedLayerColor($0, for: view) }
    }

    public static func refreshDynamicLayerColors(in root: NSView) {
        refreshDynamicLayerColor(for: root)
        root.needsDisplay = true
        for subview in root.subviews {
            refreshDynamicLayerColors(in: subview)
        }
    }

    public static func resolvedLayerColor(_ color: NSColor, for view: NSView) -> CGColor {
        var resolvedColor = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.cgColor
        }
        return resolvedColor
    }

    public static func resolvedColor(_ color: NSColor, for view: NSView) -> NSColor {
        resolvedColor(color, for: view.effectiveAppearance)
    }

    public static func resolvedColor(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var resolvedColor = color
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolvedColor
    }

    public static func dynamicColor(_ color: NSColor, alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            resolvedColor(color, for: appearance).withAlphaComponent(alpha)
        }
    }

    public static func refreshWindowDynamicColors(_ window: NSWindow) {
        window.appearance = nil
        window.backgroundColor = resolvedColor(theme.windowBackgroundColor, for: window.effectiveAppearance)
        if let contentView = window.contentView {
            contentView.appearance = window.effectiveAppearance
            refreshDynamicLayerColors(in: contentView)
            refreshEffectiveAppearanceHandlers(in: contentView)
        }
        window.toolbar?.validateVisibleItems()
        window.invalidateShadow()
    }

    public static func scheduleWindowDynamicColorsRefresh(_ window: NSWindow) {
        let delays: [TimeInterval] = [0, 0.02, 0.12, 0.35]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let window else { return }
                refreshWindowDynamicColors(window)
            }
        }
    }

    private static func refreshEffectiveAppearanceHandlers(in root: NSView) {
        (root as? StacioEffectiveAppearanceRefreshHandling)?.stacioRefreshEffectiveAppearance()
        for subview in root.subviews {
            refreshEffectiveAppearanceHandlers(in: subview)
        }
    }

    private static func refreshDynamicLayerColor(for view: NSView) {
        if let background = objc_getAssociatedObject(
            view,
            &StacioLayerColorAssociation.backgroundColor
        ) as? NSColor {
            view.layer?.backgroundColor = resolvedLayerColor(background, for: view)
        }
        if let border = objc_getAssociatedObject(
            view,
            &StacioLayerColorAssociation.borderColor
        ) as? NSColor {
            view.layer?.borderColor = resolvedLayerColor(border, for: view)
        }
    }
}

private enum StacioLayerColorAssociation {
    static var backgroundColor: UInt8 = 0
    static var borderColor: UInt8 = 0
}

public protocol StacioEffectiveAppearanceRefreshHandling: AnyObject {
    func stacioRefreshEffectiveAppearance()
}

public final class StacioAppearanceRefreshView: NSView, StacioEffectiveAppearanceRefreshHandling {
    public var onEffectiveAppearanceRefresh: (() -> Void)?

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stacioRefreshEffectiveAppearance()
    }

    public func stacioRefreshEffectiveAppearance() {
        StacioDesignSystem.refreshDynamicLayerColors(in: self)
        onEffectiveAppearanceRefresh?()
    }
}

private class StacioPaddedTextFieldCell: NSTextFieldCell {
    private let horizontalInset: CGFloat = 10

    // AppKit 14 may query this private compatibility hook while measuring a cell.
    @objc(_usesCenteredLook)
    func stacioUsesCenteredLook() -> Bool { false }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        adjustedTextRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        adjustedTextRect(for: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: rect,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
        textObj.frame = adjustedTextRect(for: rect)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: rect,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
        textObj.frame = adjustedTextRect(for: rect)
    }

    private func adjustedTextRect(for rect: NSRect) -> NSRect {
        var adjusted = super.drawingRect(forBounds: rect)
        let activeFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let targetHeight = min(
            max(ceil(activeFont.ascender - activeFont.descender + activeFont.leading), 18),
            rect.height
        )
        adjusted.origin.x = rect.minX + horizontalInset
        adjusted.size.height = targetHeight
        adjusted.origin.y = rect.midY - targetHeight / 2
        adjusted.size.width = max(0, rect.width - horizontalInset * 2)
        return adjusted
    }
}

private final class StacioPaddedSecureTextFieldCell: NSSecureTextFieldCell {
    private let horizontalInset: CGFloat = 10

    @objc(_usesCenteredLook)
    func stacioUsesCenteredLook() -> Bool { false }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        adjustedTextRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        adjustedTextRect(for: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: rect,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
        textObj.frame = adjustedTextRect(for: rect)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: rect,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
        textObj.frame = adjustedTextRect(for: rect)
    }

    private func adjustedTextRect(for rect: NSRect) -> NSRect {
        var adjusted = super.drawingRect(forBounds: rect)
        let activeFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let targetHeight = min(
            max(ceil(activeFont.ascender - activeFont.descender + activeFont.leading), 18),
            rect.height
        )
        adjusted.origin.x = rect.minX + horizontalInset
        adjusted.size.height = targetHeight
        adjusted.origin.y = rect.midY - targetHeight / 2
        adjusted.size.width = max(0, rect.width - horizontalInset * 2)
        return adjusted
    }
}

public final class StacioHoverButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var normalBackgroundColor: NSColor = StacioDesignSystem.theme.controlBackgroundColor

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        animateBackground(to: StacioDesignSystem.theme.controlHoverColor)
    }

    public override func mouseExited(with event: NSEvent) {
        animateBackground(to: normalBackgroundColor)
    }

    public override func mouseDown(with event: NSEvent) {
        animateScale(to: 0.97)
        super.mouseDown(with: event)
        animateScale(to: 1.0)
    }

    public func setNormalBackgroundColor(_ color: NSColor) {
        normalBackgroundColor = color
        wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(self, color: color)
    }

    private func animateBackground(to color: NSColor) {
        guard let layer else { return }
        let resolvedColor = StacioDesignSystem.resolvedLayerColor(color, for: self)
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        animation.toValue = resolvedColor
        animation.duration = StacioDesignSystem.theme.fastAnimationDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.backgroundColor = resolvedColor
        layer.add(animation, forKey: "Stacio.hover.background")
    }

    private func animateScale(to scale: CGFloat) {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        animation.toValue = scale
        animation.duration = StacioDesignSystem.theme.fastAnimationDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        layer.add(animation, forKey: "Stacio.press.scale")
    }
}
