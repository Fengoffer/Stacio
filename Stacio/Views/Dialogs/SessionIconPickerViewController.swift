import AppKit

@MainActor
final class SessionIconPickerViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private struct Section {
        let title: String
        let iconIDs: [String?]
    }

    private let searchField = NSSearchField()
    private let collectionView = NSCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "没有匹配的图标")
    private let confirmButton = NSButton(title: "选择", target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.Common.cancel, target: nil, action: nil)
    private let itemSize = NSSize(width: 76, height: 72)
    private var sections: [Section] = []
    private var selectedIconID: String?

    var onConfirm: ((String?) -> Void)?
    var onCancel: (() -> Void)?

    init(selectedIconID: String?) {
        self.selectedIconID = SessionIconCatalog.definition(id: selectedIconID)?.id
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 460))
        container.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "搜索图标"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("Stacio.SessionIconPicker.search")

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = itemSize
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 8, left: 10, bottom: 14, right: 10)
        layout.headerReferenceSize = NSSize(width: 100, height: 24)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            SessionIconPickerItem.self,
            forItemWithIdentifier: SessionIconPickerItem.identifier
        )
        collectionView.register(
            SessionIconPickerHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: SessionIconPickerHeaderView.identifier
        )
        let doubleClickRecognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(confirmSelection(_:))
        )
        doubleClickRecognizer.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClickRecognizer)
        collectionView.setAccessibilityIdentifier("Stacio.SessionIconPicker.collection")

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        confirmButton.target = self
        confirmButton.action = #selector(confirmSelection(_:))
        confirmButton.keyEquivalent = "\r"
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.setAccessibilityIdentifier("Stacio.SessionIconPicker.confirm")
        StacioDesignSystem.styleSheetButton(confirmButton, isDefault: true)

        cancelButton.target = self
        cancelButton.action = #selector(cancelSelection(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setAccessibilityIdentifier("Stacio.SessionIconPicker.cancel")
        StacioDesignSystem.styleSheetButton(cancelButton)

        let footer = NSStackView(views: [NSView(), cancelButton, confirmButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            confirmButton.widthAnchor.constraint(equalToConstant: 86),
            cancelButton.widthAnchor.constraint(equalToConstant: 86)
        ])

        view = container
        rebuildSections(query: "")
        selectCurrentItemIfVisible()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].iconIDs.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: SessionIconPickerItem.identifier,
            for: indexPath
        ) as! SessionIconPickerItem
        let iconID = sections[indexPath.section].iconIDs[indexPath.item]
        if let iconID, let definition = SessionIconCatalog.definition(id: iconID) {
            item.configure(
                image: SessionIconCatalog.image(for: iconID, size: NSSize(width: 32, height: 32)),
                title: definition.displayName,
                accessibilityLabel: definition.displayName
            )
        } else {
            item.configure(
                image: SessionTabIconDescriptor.sshDefault.image(size: NSSize(width: 32, height: 32)),
                title: "默认",
                accessibilityLabel: "默认会话图标"
            )
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let header = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: SessionIconPickerHeaderView.identifier,
            for: indexPath
        ) as! SessionIconPickerHeaderView
        header.title = sections[indexPath.section].title
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        selectedIconID = sections[indexPath.section].iconIDs[indexPath.item]
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        rebuildSections(query: sender.stringValue)
    }

    @objc private func confirmSelection(_ sender: Any?) {
        onConfirm?(selectedIconID)
    }

    @objc private func cancelSelection(_ sender: Any?) {
        onCancel?()
    }

    private func rebuildSections(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sections = [
                Section(title: "默认", iconIDs: [nil]),
                Section(title: SessionIconGroup.operatingSystem.displayName, iconIDs: SessionIconCatalog.operatingSystems.map { Optional($0.id) }),
                Section(title: SessionIconGroup.cloudPlatform.displayName, iconIDs: SessionIconCatalog.cloudPlatforms.map { Optional($0.id) })
            ]
        } else {
            let matches = SessionIconCatalog.matching(trimmed)
            sections = SessionIconGroup.allCases.compactMap { group in
                let iconIDs = matches.filter { $0.group == group }.map { Optional($0.id) }
                return iconIDs.isEmpty ? nil : Section(title: group.displayName, iconIDs: iconIDs)
            }
        }
        collectionView.reloadData()
        emptyLabel.isHidden = !sections.isEmpty
        selectCurrentItemIfVisible()
    }

    private func selectCurrentItemIfVisible() {
        for (sectionIndex, section) in sections.enumerated() {
            if let itemIndex = section.iconIDs.firstIndex(where: { $0 == selectedIconID }) {
                collectionView.selectItems(
                    at: [IndexPath(item: itemIndex, section: sectionIndex)],
                    scrollPosition: []
                )
                return
            }
        }
    }

    var sectionTitlesForTesting: [String] {
        sections.map(\.title)
    }

    var selectedIconIDForTesting: String? {
        selectedIconID
    }

    var visibleIconIDsForTesting: [String] {
        sections.flatMap(\.iconIDs).compactMap { $0 }
    }

    var itemSizeForTesting: NSSize {
        itemSize
    }

    func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        rebuildSections(query: query)
    }

    func selectForTesting(iconID: String?) {
        selectedIconID = SessionIconCatalog.definition(id: iconID)?.id
        selectCurrentItemIfVisible()
    }

    func confirmForTesting() {
        confirmSelection(nil)
    }

    func cancelForTesting() {
        cancelSelection(nil)
    }
}

private final class SessionIconPickerItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("SessionIconPickerItem")

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4)
        ])
        view = container
        updateSelectionAppearance()
    }

    func configure(image: NSImage?, title: String, accessibilityLabel: String) {
        iconView.image = image
        titleLabel.stringValue = title
        view.setAccessibilityLabel(accessibilityLabel)
        view.setAccessibilityRole(.button)
    }

    private func updateSelectionAppearance() {
        guard isViewLoaded else { return }
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
        StacioDesignSystem.setLayerBackgroundColor(
            view,
            color: isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.10) : .clear
        )
    }
}

private final class SessionIconPickerHeaderView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("SessionIconPickerHeader")
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
