import AppKit
import SwiftTerm

@MainActor
final class TerminalSearchController {
    let searchBarView = TerminalSearchBarView()
    let highlightOverlayView = TerminalSearchHighlightOverlayView()

    private let terminalView: TerminalView
    private weak var focusView: NSView?
    private var query = ""
    private var currentMatchIndex = 0
    private var totalMatchCount = 0
    private let searchOptions = SearchOptions(caseSensitive: false, regex: false, wholeWord: false)
    private weak var installedContainer: NSView?
    private weak var terminalOverlayView: NSView?
    private var searchBarConstraints: [NSLayoutConstraint] = []

    init(terminalView: TerminalView, focusView: NSView) {
        self.terminalView = terminalView
        self.focusView = focusView
        configureSearchBar()
    }

    var isVisible: Bool {
        searchBarView.isHidden == false
    }

    var summaryText: String {
        searchBarView.summaryText
    }

    var visibleHighlightCount: Int {
        highlightOverlayView.visibleHighlightCount
    }

    func install(in container: NSView, overlaying terminalView: NSView) {
        installedContainer = container
        terminalOverlayView = terminalView
        highlightOverlayView.translatesAutoresizingMaskIntoConstraints = false
        highlightOverlayView.isHidden = true
        searchBarView.translatesAutoresizingMaskIntoConstraints = false
        searchBarView.isHidden = true

        container.addSubview(highlightOverlayView)
        attachSearchBar(to: container)

        NSLayoutConstraint.activate([
            highlightOverlayView.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            highlightOverlayView.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            highlightOverlayView.topAnchor.constraint(equalTo: terminalView.topAnchor),
            highlightOverlayView.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor)
        ])
    }

    func show() {
        promoteSearchBarAboveWorkspaceOverlaysIfPossible()
        if let terminalOverlayView,
           let highlightSuperview = highlightOverlayView.superview
        {
            highlightSuperview.addSubview(highlightOverlayView, positioned: .above, relativeTo: terminalOverlayView)
        }
        searchBarView.superview?.addSubview(searchBarView, positioned: .above, relativeTo: nil)
        searchBarView.isHidden = false
        highlightOverlayView.isHidden = false
        searchBarView.focus()
        refreshSearch(resetSelection: query.isEmpty == false)
    }

    func close() {
        query = ""
        currentMatchIndex = 0
        totalMatchCount = 0
        searchBarView.searchText = ""
        searchBarView.updateSummary(current: 0, total: 0)
        searchBarView.isHidden = true
        highlightOverlayView.clear()
        highlightOverlayView.isHidden = true
        terminalView.clearSearch()
        restoreSearchBarToInstalledContainerIfNeeded()
        if let focusView {
            terminalView.window?.makeFirstResponder(focusView)
        }
    }

    func setQuery(_ value: String) {
        query = value
        if searchBarView.searchText != value {
            searchBarView.searchText = value
        }
        refreshSearch(resetSelection: true)
    }

    func selectNext() {
        guard query.isEmpty == false, totalMatchCount > 0 else {
            refreshSearch(resetSelection: true)
            return
        }
        guard terminalView.findNext(query, options: searchOptions) else {
            refreshSearch(resetSelection: true)
            return
        }
        currentMatchIndex = currentMatchIndex <= 0 ? 1 : (currentMatchIndex % totalMatchCount) + 1
        updateSearchPresentation()
    }

    func selectPrevious() {
        guard query.isEmpty == false, totalMatchCount > 0 else {
            refreshSearch(resetSelection: true)
            return
        }
        guard terminalView.findPrevious(query, options: searchOptions) else {
            refreshSearch(resetSelection: true)
            return
        }
        currentMatchIndex = currentMatchIndex <= 1 ? totalMatchCount : currentMatchIndex - 1
        updateSearchPresentation()
    }

    func terminalContentDidChange() {
        guard isVisible else { return }
        refreshSearch(resetSelection: false)
    }

    private func configureSearchBar() {
        searchBarView.onSearchTextChanged = { [weak self] text in
            self?.setQuery(text)
        }
        searchBarView.onNext = { [weak self] in
            self?.selectNext()
        }
        searchBarView.onPrevious = { [weak self] in
            self?.selectPrevious()
        }
        searchBarView.onClose = { [weak self] in
            self?.close()
        }
    }

    private func promoteSearchBarAboveWorkspaceOverlaysIfPossible() {
        guard let windowContentView = terminalOverlayView?.window?.contentView else {
            searchBarView.superview?.addSubview(searchBarView, positioned: .above, relativeTo: nil)
            return
        }
        guard searchBarView.superview !== windowContentView else {
            windowContentView.addSubview(searchBarView, positioned: .above, relativeTo: nil)
            return
        }
        attachSearchBar(to: windowContentView)
    }

    private func restoreSearchBarToInstalledContainerIfNeeded() {
        guard let installedContainer,
              searchBarView.superview !== installedContainer
        else { return }
        attachSearchBar(to: installedContainer)
    }

    private func attachSearchBar(to host: NSView) {
        NSLayoutConstraint.deactivate(searchBarConstraints)
        searchBarConstraints = []
        searchBarView.removeFromSuperview()
        searchBarView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(searchBarView, positioned: .above, relativeTo: nil)
        guard let terminalOverlayView else {
            return
        }
        searchBarConstraints = [
            searchBarView.topAnchor.constraint(equalTo: terminalOverlayView.topAnchor, constant: 12),
            searchBarView.trailingAnchor.constraint(equalTo: terminalOverlayView.trailingAnchor, constant: -12),
            searchBarView.leadingAnchor.constraint(greaterThanOrEqualTo: terminalOverlayView.leadingAnchor, constant: 12),
            searchBarView.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        ]
        NSLayoutConstraint.activate(searchBarConstraints)
    }

    private func refreshSearch(resetSelection: Bool) {
        totalMatchCount = Self.countMatches(in: terminalTextSnapshot(), query: query)
        if query.isEmpty || totalMatchCount == 0 {
            currentMatchIndex = 0
            terminalView.clearSearch()
            updateSearchPresentation()
            return
        }

        if resetSelection || currentMatchIndex == 0 {
            terminalView.clearSearch()
            currentMatchIndex = terminalView.findNext(query, options: searchOptions) ? 1 : 0
        } else {
            currentMatchIndex = min(currentMatchIndex, totalMatchCount)
        }
        updateSearchPresentation()
    }

    private func updateSearchPresentation() {
        searchBarView.updateSummary(current: currentMatchIndex, total: totalMatchCount)
        highlightOverlayView.update(query: query, terminalView: terminalView)
    }

    private func terminalTextSnapshot() -> String {
        String(data: terminalView.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
    }

    private static func countMatches(in text: String, query: String) -> Int {
        guard query.isEmpty == false else { return 0 }

        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(
            of: query,
            options: [.caseInsensitive],
            range: searchRange
        ) {
            count += 1
            guard match.upperBound < text.endIndex else { break }
            searchRange = match.upperBound..<text.endIndex
        }
        return count
    }

}

final class TerminalSearchBarView: NSView, NSSearchFieldDelegate {
    var onSearchTextChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let searchField = NSSearchField()
    private let summaryLabel = NSTextField(labelWithString: L10n.TerminalSearch.matchSummary(current: 0, total: 0))
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    var searchText: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    var summaryText: String {
        summaryLabel.stringValue
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func focus() {
        window?.makeFirstResponder(searchField)
    }

    func updateSummary(current: Int, total: Int) {
        summaryLabel.stringValue = L10n.TerminalSearch.matchSummary(current: current, total: total)
    }

    private func setup() {
        StacioDesignSystem.applyPanelSurface(self)
        setAccessibilityIdentifier("Stacio.Terminal.searchBar")

        searchField.placeholderString = L10n.TerminalSearch.placeholder
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("Stacio.Terminal.searchField")
        StacioDesignSystem.styleSearchField(searchField)

        summaryLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.alignment = .right
        summaryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        summaryLabel.setAccessibilityIdentifier("Stacio.Terminal.searchSummary")

        configureButton(
            previousButton,
            symbol: "chevron.up",
            tooltip: L10n.TerminalSearch.previousMatch,
            action: #selector(previousPressed(_:)),
            identifier: "Stacio.Terminal.searchPrevious"
        )
        configureButton(
            nextButton,
            symbol: "chevron.down",
            tooltip: L10n.TerminalSearch.nextMatch,
            action: #selector(nextPressed(_:)),
            identifier: "Stacio.Terminal.searchNext"
        )
        configureButton(
            closeButton,
            symbol: "xmark",
            tooltip: L10n.Common.close,
            action: #selector(closePressed(_:)),
            identifier: "Stacio.Terminal.searchClose"
        )

        let stack = NSStackView(views: [
            searchField,
            summaryLabel,
            previousButton,
            nextButton,
            closeButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            summaryLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 92)
        ])
    }

    private func configureButton(
        _ button: NSButton,
        symbol: String,
        tooltip: String,
        action: Selector,
        identifier: String
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.title = ""
        button.target = self
        button.action = action
        button.toolTip = tooltip
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier(identifier)
        StacioDesignSystem.styleIconButton(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            onPrevious?()
        } else {
            onNext?()
        }
    }

    @objc private func previousPressed(_ sender: NSButton) {
        onPrevious?()
    }

    @objc private func nextPressed(_ sender: NSButton) {
        onNext?()
    }

    @objc private func closePressed(_ sender: NSButton) {
        onClose?()
    }

    func controlTextDidChange(_ obj: Notification) {
        onSearchTextChanged?(searchField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.moveDown(_:)):
            onNext?()
            return true
        case #selector(NSResponder.moveUp(_:)):
            onPrevious?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

final class TerminalSearchHighlightOverlayView: NSView {
    private struct Highlight {
        let row: Int
        let col: Int
        let length: Int
    }

    private var highlights: [Highlight] = []
    private var cellSize: CGSize = .zero

    var visibleHighlightCount: Int {
        highlights.count
    }

    override var isFlipped: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func clear() {
        highlights = []
        needsDisplay = true
    }

    func update(query: String, terminalView: TerminalView) {
        guard query.isEmpty == false else {
            clear()
            return
        }

        let terminal = terminalView.getTerminal()
        let dimensions = terminal.getDims()
        cellSize = terminalView.caretFrame.size
        highlights = (0..<dimensions.rows).flatMap { row in
            visibleHighlights(
                in: terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "",
                query: query,
                row: row
            )
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard cellSize.width > 0, cellSize.height > 0 else { return }

        let fillColor = StacioDesignSystem.theme.warningColor.withAlphaComponent(0.28)
        let strokeColor = StacioDesignSystem.theme.accentColor.withAlphaComponent(0.62)
        for highlight in highlights {
            let rect = NSRect(
                x: CGFloat(highlight.col) * cellSize.width,
                y: bounds.height - CGFloat(highlight.row + 1) * cellSize.height,
                width: CGFloat(max(1, highlight.length)) * cellSize.width,
                height: cellSize.height
            ).insetBy(dx: 1, dy: 1)
            fillColor.setFill()
            rect.fill()
            strokeColor.setStroke()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).stroke()
        }
    }

    private func visibleHighlights(in line: String, query: String, row: Int) -> [Highlight] {
        guard line.isEmpty == false else { return [] }

        var matches: [Highlight] = []
        var searchRange = line.startIndex..<line.endIndex
        while let match = line.range(
            of: query,
            options: [.caseInsensitive],
            range: searchRange
        ) {
            let col = line.distance(from: line.startIndex, to: match.lowerBound)
            let length = line.distance(from: match.lowerBound, to: match.upperBound)
            matches.append(Highlight(row: row, col: col, length: length))

            guard match.upperBound < line.endIndex else { break }
            searchRange = match.upperBound..<line.endIndex
        }
        return matches
    }
}
