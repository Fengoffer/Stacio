import AppKit

@MainActor
final class WorkbenchCustomizationRoutingToolbar: NSToolbar {
    var customizationHandler: ((Any?) -> Void)?

    override func runCustomizationPalette(_ sender: Any?) {
        guard let customizationHandler else {
            super.runCustomizationPalette(sender)
            return
        }
        customizationHandler(sender)
    }
}

@MainActor
struct WorkbenchToolbarCustomizationDescriptor {
    let identifier: NSToolbarItem.Identifier
    let label: String
    let image: NSImage
    let allowsDuplicates: Bool
}

struct WorkbenchToolbarCustomizationEntry: Equatable {
    let id: UUID
    let identifier: NSToolbarItem.Identifier
}

struct WorkbenchToolbarCustomizationModel {
    private(set) var entries: [WorkbenchToolbarCustomizationEntry]
    let defaultIdentifiers: [NSToolbarItem.Identifier]
    let duplicateIdentifiers: Set<NSToolbarItem.Identifier>

    init(
        currentIdentifiers: [NSToolbarItem.Identifier],
        defaultIdentifiers: [NSToolbarItem.Identifier],
        duplicateIdentifiers: Set<NSToolbarItem.Identifier>
    ) {
        entries = currentIdentifiers.map {
            WorkbenchToolbarCustomizationEntry(id: UUID(), identifier: $0)
        }
        self.defaultIdentifiers = defaultIdentifiers
        self.duplicateIdentifiers = duplicateIdentifiers
    }

    var identifiers: [NSToolbarItem.Identifier] {
        entries.map(\.identifier)
    }

    func containsUniqueIdentifier(_ identifier: NSToolbarItem.Identifier) -> Bool {
        duplicateIdentifiers.contains(identifier) == false && identifiers.contains(identifier)
    }

    @discardableResult
    mutating func insert(_ identifier: NSToolbarItem.Identifier, at proposedIndex: Int) -> Bool {
        guard containsUniqueIdentifier(identifier) == false else { return false }
        let index = min(max(0, proposedIndex), entries.count)
        entries.insert(
            WorkbenchToolbarCustomizationEntry(id: UUID(), identifier: identifier),
            at: index
        )
        return true
    }

    @discardableResult
    mutating func remove(entryID: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        entries.remove(at: index)
        return true
    }

    @discardableResult
    mutating func move(entryID: UUID, to proposedIndex: Int) -> Bool {
        guard let sourceIndex = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        let entry = entries.remove(at: sourceIndex)
        var destinationIndex = min(max(0, proposedIndex), entries.count + 1)
        if destinationIndex > sourceIndex {
            destinationIndex -= 1
        }
        destinationIndex = min(max(0, destinationIndex), entries.count)
        entries.insert(entry, at: destinationIndex)
        return true
    }

    mutating func restoreDefault() {
        entries = defaultIdentifiers.map {
            WorkbenchToolbarCustomizationEntry(id: UUID(), identifier: $0)
        }
    }
}

@MainActor
final class WorkbenchToolbarCustomizationWindowController: NSWindowController {
    var onDismiss: (() -> Void)?

    private let descriptors: [WorkbenchToolbarCustomizationDescriptor]
    private let onApply: ([NSToolbarItem.Identifier]) -> Void
    private var model: WorkbenchToolbarCustomizationModel
    private let availableDropZone = ToolbarCustomizationAvailableDropZone()
    private let currentDropZone = ToolbarCustomizationCurrentDropZone()
    private let currentScrollView = NSScrollView()

    init(
        descriptors: [WorkbenchToolbarCustomizationDescriptor],
        currentIdentifiers: [NSToolbarItem.Identifier],
        defaultIdentifiers: [NSToolbarItem.Identifier],
        onApply: @escaping ([NSToolbarItem.Identifier]) -> Void
    ) {
        self.descriptors = descriptors
        self.onApply = onApply
        model = WorkbenchToolbarCustomizationModel(
            currentIdentifiers: currentIdentifiers,
            defaultIdentifiers: defaultIdentifiers,
            duplicateIdentifiers: [.space, .flexibleSpace]
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 840, height: 474)),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.Workbench.toolbarCustomizationTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        StacioDesignSystem.applyWindowChrome(panel)

        super.init(window: panel)
        buildInterface()
        reloadItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func beginSheet(for parentWindow: NSWindow) {
        guard let window, window.sheetParent == nil else { return }
        parentWindow.beginSheet(window)
    }

    private func buildInterface() {
        guard let window else { return }

        let root = NSVisualEffectView()
        root.material = .contentBackground
        root.blendingMode = .withinWindow
        root.state = .active
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.ToolbarCustomization.root")
        window.contentView = root

        let titleLabel = NSTextField(labelWithString: L10n.Workbench.toolbarCustomizationTitle)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(wrappingLabelWithString: L10n.Workbench.toolbarCustomizationSubtitle)
        subtitleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        subtitleLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let availableTitle = makeSectionTitle(L10n.Workbench.toolbarCustomizationAvailable)
        let availableSurface = makeSectionSurface(identifier: "Stacio.ToolbarCustomization.availableSurface")
        availableDropZone.translatesAutoresizingMaskIntoConstraints = false
        availableSurface.addSubview(availableDropZone)

        let currentTitle = makeSectionTitle(L10n.Workbench.toolbarCustomizationCurrent)
        let currentHint = NSTextField(labelWithString: L10n.Workbench.toolbarCustomizationRemoveHint)
        currentHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        currentHint.textColor = StacioDesignSystem.theme.secondaryTextColor
        currentHint.alignment = .right
        currentHint.translatesAutoresizingMaskIntoConstraints = false

        let currentSurface = makeSectionSurface(identifier: "Stacio.ToolbarCustomization.currentSurface")
        currentScrollView.drawsBackground = false
        currentScrollView.borderType = .noBorder
        currentScrollView.hasHorizontalScroller = true
        currentScrollView.hasVerticalScroller = false
        currentScrollView.autohidesScrollers = true
        currentScrollView.translatesAutoresizingMaskIntoConstraints = false
        currentScrollView.documentView = currentDropZone
        currentSurface.addSubview(currentScrollView)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(
            title: L10n.Common.cancel,
            target: self,
            action: #selector(cancelPressed(_:))
        )
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        cancelButton.setAccessibilityIdentifier("Stacio.ToolbarCustomization.cancel")

        let restoreButton = NSButton(
            title: L10n.Workbench.toolbarCustomizationRestoreDefault,
            target: self,
            action: #selector(restoreDefaultPressed(_:))
        )
        restoreButton.bezelStyle = .rounded
        restoreButton.setAccessibilityIdentifier("Stacio.ToolbarCustomization.restoreDefault")

        let doneButton = NSButton(
            title: L10n.Workbench.toolbarCustomizationDone,
            target: self,
            action: #selector(donePressed(_:))
        )
        doneButton.keyEquivalent = "\r"
        doneButton.bezelStyle = .rounded
        doneButton.setAccessibilityIdentifier("Stacio.ToolbarCustomization.done")

        let buttonSpacer = NSView()
        let buttonRow = NSStackView(views: [restoreButton, buttonSpacer, cancelButton, doneButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        [titleLabel, subtitleLabel, availableTitle, availableSurface, currentTitle, currentHint, currentSurface, separator, buttonRow]
            .forEach(root.addSubview)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            availableTitle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            availableTitle.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),

            availableSurface.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            availableSurface.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            availableSurface.topAnchor.constraint(equalTo: availableTitle.bottomAnchor, constant: 7),
            availableSurface.heightAnchor.constraint(equalToConstant: 150),

            availableDropZone.leadingAnchor.constraint(equalTo: availableSurface.leadingAnchor, constant: 8),
            availableDropZone.trailingAnchor.constraint(equalTo: availableSurface.trailingAnchor, constant: -8),
            availableDropZone.topAnchor.constraint(equalTo: availableSurface.topAnchor, constant: 8),
            availableDropZone.bottomAnchor.constraint(equalTo: availableSurface.bottomAnchor, constant: -8),

            currentTitle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            currentTitle.topAnchor.constraint(equalTo: availableSurface.bottomAnchor, constant: 16),
            currentHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            currentHint.centerYAnchor.constraint(equalTo: currentTitle.centerYAnchor),
            currentHint.leadingAnchor.constraint(greaterThanOrEqualTo: currentTitle.trailingAnchor, constant: 12),

            currentSurface.leadingAnchor.constraint(equalTo: availableSurface.leadingAnchor),
            currentSurface.trailingAnchor.constraint(equalTo: availableSurface.trailingAnchor),
            currentSurface.topAnchor.constraint(equalTo: currentTitle.bottomAnchor, constant: 7),
            currentSurface.heightAnchor.constraint(equalToConstant: 94),

            currentScrollView.leadingAnchor.constraint(equalTo: currentSurface.leadingAnchor, constant: 8),
            currentScrollView.trailingAnchor.constraint(equalTo: currentSurface.trailingAnchor, constant: -8),
            currentScrollView.topAnchor.constraint(equalTo: currentSurface.topAnchor, constant: 6),
            currentScrollView.bottomAnchor.constraint(equalTo: currentSurface.bottomAnchor, constant: -6),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: currentSurface.bottomAnchor, constant: 17),

            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttonRow.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            buttonSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])

        availableDropZone.onRemoveCurrentItem = { [weak self] entryID in
            self?.removeCurrentItem(entryID: entryID)
        }
        currentDropZone.onDropItem = { [weak self] payload, index in
            self?.handleDrop(payload, at: index)
        }
    }

    private func makeSectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = StacioDesignSystem.theme.primaryTextColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeSectionSurface(identifier: String) -> NSVisualEffectView {
        let surface = NSVisualEffectView()
        surface.material = .underWindowBackground
        surface.blendingMode = .withinWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 14
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 0.5
        surface.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.setAccessibilityIdentifier(identifier)
        return surface
    }

    private func reloadItems() {
        let identifiers = model.identifiers
        let availableViews = descriptors.map { descriptor in
            let isEnabled = descriptor.allowsDuplicates || identifiers.contains(descriptor.identifier) == false
            return ToolbarCustomizationItemView(
                descriptor: descriptor,
                payload: ToolbarCustomizationDragPayload(
                    source: .available,
                    identifier: descriptor.identifier.rawValue,
                    entryID: nil
                ),
                isDragEnabled: isEnabled,
                accessibilityIdentifier: "Stacio.ToolbarCustomization.available.\(descriptor.identifier.rawValue)"
            )
        }
        availableDropZone.setItemViews(availableViews)

        let descriptorsByIdentifier = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.identifier, $0) })
        let currentViews = model.entries.compactMap { entry -> ToolbarCustomizationItemView? in
            guard let descriptor = descriptorsByIdentifier[entry.identifier] else { return nil }
            let view = ToolbarCustomizationItemView(
                descriptor: descriptor,
                payload: ToolbarCustomizationDragPayload(
                    source: .current,
                    identifier: descriptor.identifier.rawValue,
                    entryID: entry.id.uuidString
                ),
                isDragEnabled: true,
                accessibilityIdentifier: "Stacio.ToolbarCustomization.current.\(entry.id.uuidString).\(descriptor.identifier.rawValue)"
            )
            view.onUnacceptedDragEnded = { [weak self] payload, screenPoint in
                self?.handleUnacceptedDragEnded(payload, at: screenPoint)
            }
            return view
        }
        currentDropZone.setItemViews(currentViews)
        layoutCurrentDropZone()
    }

    private func layoutCurrentDropZone() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let width = max(currentScrollView.contentSize.width, currentDropZone.requiredWidth)
        currentDropZone.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: max(72, currentScrollView.contentSize.height))
        )
        currentDropZone.needsLayout = true
    }

    @discardableResult
    private func handleDrop(
        _ payload: ToolbarCustomizationDragPayload,
        at index: Int
    ) -> Bool {
        var updatedModel = model
        let changed: Bool
        switch payload.source {
        case .available:
            changed = updatedModel.insert(
                NSToolbarItem.Identifier(payload.identifier),
                at: index
            )
        case .current:
            guard let entryID = payload.entryID.flatMap(UUID.init(uuidString:)) else {
                return false
            }
            changed = updatedModel.move(entryID: entryID, to: index)
        }
        guard changed else { return false }
        model = updatedModel
        reloadItems()
        return true
    }

    @discardableResult
    private func removeCurrentItem(entryID: UUID) -> Bool {
        var updatedModel = model
        guard updatedModel.remove(entryID: entryID) else { return false }
        model = updatedModel
        reloadItems()
        return true
    }

    @discardableResult
    private func handleUnacceptedDragEnded(
        _ payload: ToolbarCustomizationDragPayload,
        at screenPoint: NSPoint
    ) -> Bool {
        guard window?.frame.contains(screenPoint) == false,
              let entryID = payload.entryID.flatMap(UUID.init(uuidString:))
        else { return false }
        return removeCurrentItem(entryID: entryID)
    }

    var currentIdentifiersForTesting: [NSToolbarItem.Identifier] {
        model.identifiers
    }

    @discardableResult
    func dropAvailableItemForTesting(
        _ identifier: NSToolbarItem.Identifier,
        at index: Int
    ) -> Bool {
        handleDrop(
            ToolbarCustomizationDragPayload(
                source: .available,
                identifier: identifier.rawValue,
                entryID: nil
            ),
            at: index
        )
    }

    @discardableResult
    func moveCurrentItemForTesting(
        _ identifier: NSToolbarItem.Identifier,
        to index: Int
    ) -> Bool {
        guard let entry = model.entries.first(where: { $0.identifier == identifier }) else {
            return false
        }
        return handleDrop(
            ToolbarCustomizationDragPayload(
                source: .current,
                identifier: identifier.rawValue,
                entryID: entry.id.uuidString
            ),
            at: index
        )
    }

    @discardableResult
    func dropCurrentItemBackToAvailableForTesting(
        _ identifier: NSToolbarItem.Identifier
    ) -> Bool {
        guard let entryID = model.entries.first(where: { $0.identifier == identifier })?.id else {
            return false
        }
        return removeCurrentItem(entryID: entryID)
    }

    @discardableResult
    func dragCurrentItemOutsideForTesting(
        _ identifier: NSToolbarItem.Identifier
    ) -> Bool {
        guard let entryID = model.entries.first(where: { $0.identifier == identifier })?.id,
              let window
        else { return false }
        return handleUnacceptedDragEnded(
            ToolbarCustomizationDragPayload(
                source: .current,
                identifier: identifier.rawValue,
                entryID: entryID.uuidString
            ),
            at: NSPoint(x: window.frame.maxX + 1, y: window.frame.maxY + 1)
        )
    }

    @objc private func cancelPressed(_ sender: Any?) {
        finish(applyingChanges: false)
    }

    @objc private func restoreDefaultPressed(_ sender: Any?) {
        model.restoreDefault()
        reloadItems()
    }

    @objc private func donePressed(_ sender: Any?) {
        finish(applyingChanges: true)
    }

    private func finish(applyingChanges: Bool) {
        if applyingChanges {
            onApply(model.identifiers)
        }
        guard let window else {
            onDismiss?()
            return
        }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        }
        window.orderOut(nil)
        onDismiss?()
    }
}

private extension NSPasteboard.PasteboardType {
    static let stacioToolbarCustomizationItem = NSPasteboard.PasteboardType(
        "com.stacio.toolbar-customization-item"
    )
}

private struct ToolbarCustomizationDragPayload: Codable {
    enum Source: String, Codable {
        case available
        case current
    }

    let source: Source
    let identifier: String
    let entryID: String?

    static func read(from draggingInfo: NSDraggingInfo) -> Self? {
        guard let data = draggingInfo.draggingPasteboard.data(forType: .stacioToolbarCustomizationItem) else {
            return nil
        }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

@MainActor
protocol WorkbenchToolbarCustomizationDragOperationProviding: AnyObject {
    var permittedToolbarCustomizationDragOperations: NSDragOperation { get }
}

@MainActor
private final class ToolbarCustomizationItemView: NSView, NSDraggingSource,
    WorkbenchToolbarCustomizationDragOperationProviding
{
    let payload: ToolbarCustomizationDragPayload
    var onUnacceptedDragEnded: ((ToolbarCustomizationDragPayload, NSPoint) -> Void)?

    private let isDragEnabled: Bool
    private var mouseDownPoint: NSPoint?
    private var isDragging = false
    private var trackingAreaReference: NSTrackingArea?

    init(
        descriptor: WorkbenchToolbarCustomizationDescriptor,
        payload: ToolbarCustomizationDragPayload,
        isDragEnabled: Bool,
        accessibilityIdentifier: String
    ) {
        self.payload = payload
        self.isDragEnabled = isDragEnabled
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 72, height: 64)))

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        setAccessibilityIdentifier(accessibilityIdentifier)
        setAccessibilityLabel(descriptor.label)
        alphaValue = isDragEnabled ? 1 : 0.38

        let imageView = NSImageView(image: descriptor.image)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: descriptor.label)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(label)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            imageView.widthAnchor.constraint(equalToConstant: 28),
            imageView.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { false }

    var permittedToolbarCustomizationDragOperations: NSDragOperation {
        payload.source == .available ? .copy : [.move, .delete]
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard isDragEnabled else { return }
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isDragEnabled else { return }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragEnabled, isDragging == false, let mouseDownPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        guard hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y) >= 3 else { return }
        guard let data = try? JSONEncoder().encode(payload) else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: .stacioToolbarCustomizationItem)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: dragPreviewImage())
        isDragging = true
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        permittedToolbarCustomizationDragOperations
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        mouseDownPoint = nil
        if operation.isEmpty, payload.source == .current {
            onUnacceptedDragEnded?(payload, screenPoint)
        }
    }

    private func dragPreviewImage() -> NSImage {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

@MainActor
private final class ToolbarCustomizationAvailableDropZone: NSView {
    var onRemoveCurrentItem: ((UUID) -> Void)?
    private var itemViews: [ToolbarCustomizationItemView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.stacioToolbarCustomizationItem])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setItemViews(_ views: [ToolbarCustomizationItemView]) {
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = views
        views.forEach(addSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let itemSize = NSSize(width: 72, height: 64)
        let horizontalSpacing: CGFloat = 5
        let verticalSpacing: CGFloat = 4
        let columns = max(1, Int((bounds.width + horizontalSpacing) / (itemSize.width + horizontalSpacing)))
        for (index, itemView) in itemViews.enumerated() {
            let column = index % columns
            let row = index / columns
            itemView.frame = NSRect(
                x: CGFloat(column) * (itemSize.width + horizontalSpacing),
                y: bounds.height - itemSize.height - CGFloat(row) * (itemSize.height + verticalSpacing),
                width: itemSize.width,
                height: itemSize.height
            )
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ToolbarCustomizationDragPayload.read(from: sender)?.source == .current else { return [] }
        return .delete
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ToolbarCustomizationDragPayload.read(from: sender)?.source == .current
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = ToolbarCustomizationDragPayload.read(from: sender),
              payload.source == .current,
              let entryID = payload.entryID.flatMap(UUID.init(uuidString:))
        else { return false }
        onRemoveCurrentItem?(entryID)
        return true
    }
}

@MainActor
private final class ToolbarCustomizationCurrentDropZone: NSView {
    var onDropItem: ((ToolbarCustomizationDragPayload, Int) -> Void)?
    private var itemViews: [ToolbarCustomizationItemView] = []
    private let insertionMarker = NSView()

    var requiredWidth: CGFloat {
        max(1, 20 + CGFloat(itemViews.count) * 77)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.stacioToolbarCustomizationItem])
        insertionMarker.wantsLayer = true
        insertionMarker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionMarker.layer?.cornerRadius = 1.5
        insertionMarker.isHidden = true
        addSubview(insertionMarker)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setItemViews(_ views: [ToolbarCustomizationItemView]) {
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = views
        views.forEach { addSubview($0, positioned: .below, relativeTo: insertionMarker) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 10
        let itemSize = NSSize(width: 72, height: 64)
        let y = max(0, (bounds.height - itemSize.height) / 2)
        for itemView in itemViews {
            itemView.frame = NSRect(origin: NSPoint(x: x, y: y), size: itemSize)
            x += itemSize.width + 5
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateInsertionMarker(for: sender)
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateInsertionMarker(for: sender)
        return operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionMarker.isHidden = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        operation(for: sender).isEmpty == false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { insertionMarker.isHidden = true }
        guard let payload = ToolbarCustomizationDragPayload.read(from: sender) else { return false }
        onDropItem?(payload, insertionIndex(for: sender))
        return true
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = ToolbarCustomizationDragPayload.read(from: sender) else { return [] }
        return payload.source == .available ? .copy : .move
    }

    private func insertionIndex(for sender: NSDraggingInfo) -> Int {
        let point = convert(sender.draggingLocation, from: nil)
        for (index, itemView) in itemViews.enumerated() where point.x < itemView.frame.midX {
            return index
        }
        return itemViews.count
    }

    private func updateInsertionMarker(for sender: NSDraggingInfo) {
        let index = insertionIndex(for: sender)
        let x: CGFloat
        if itemViews.isEmpty {
            x = 10
        } else if index >= itemViews.count {
            x = itemViews[itemViews.count - 1].frame.maxX + 2.5
        } else {
            x = itemViews[index].frame.minX - 2.5
        }
        insertionMarker.frame = NSRect(x: x, y: 8, width: 3, height: max(24, bounds.height - 16))
        insertionMarker.isHidden = false
    }
}
