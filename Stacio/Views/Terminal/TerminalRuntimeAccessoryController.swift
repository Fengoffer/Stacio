import AppKit
import SwiftTerm

public final class TerminalLineInfoGutterView: NSView {
    private enum Metrics {
        static let leadingInset: CGFloat = 5
        static let trailingInset: CGFloat = 6
        static let separatorGap: CGFloat = 6
        static let separatorWidth: CGFloat = 1
        static let verticalInset: CGFloat = 0
        static let minLineNumberWidth: CGFloat = 28
        static let minTimestampWidth: CGFloat = 78
        static let minCombinedWidth: CGFloat = 108
    }

    private let separator = NSView()
    private var settings = AppSettings()
    private var visibleLineTexts: [Int: String] = [:]
    private var visibleLineTimestamps: [Int: Date] = [:]
    private var visibleLineValues: [String] = []
    private var cellSize: CGSize = .zero
    private var lineInfoFont: NSFont?
    private var lineInfoColor: NSColor?
    public private(set) var visibleTextForTesting = ""
    public private(set) var preferredWidthForTesting: CGFloat = 0
    public private(set) var usesTerminalSurfaceStyleForTesting = true
    public private(set) var lineInfoFontPointSizeForTesting: CGFloat = 0
    public private(set) var lineInfoLabelCountForTesting = 0
    public private(set) var lineInfoRowHeightForTesting: CGFloat = 0
    public var lineInfoColorForTesting: NSColor? {
        lineInfoColor.map { StacioDesignSystem.resolvedColor($0, for: self) }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("Stacio.Terminal.lineInfoGutter")
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: Metrics.separatorWidth)
        ])
        applySurfaceColors()
        isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func apply(settings: AppSettings, terminalView: TerminalView, date: Date = Date()) {
        self.settings = settings
        let rows = terminalView.getTerminal().getDims().rows
        preferredWidthForTesting = Self.preferredWidth(for: settings, rows: rows)
        isHidden = settings.terminalLineNumbersEnabled == false && settings.terminalTimestampsEnabled == false
        applySurfaceColors()
        rebuild(from: terminalView, date: date)
    }

    public func refresh(from terminalView: TerminalView, date: Date = Date()) {
        let rows = terminalView.getTerminal().getDims().rows
        preferredWidthForTesting = Self.preferredWidth(for: settings, rows: rows)
        rebuild(from: terminalView, date: date)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceColors()
    }

    public static func preferredWidth(for settings: AppSettings, rows: Int) -> CGFloat {
        guard settings.terminalLineNumbersEnabled || settings.terminalTimestampsEnabled else {
            return 0
        }
        let sample = sampleText(settings: settings, rows: rows)
        let measuredWidth = ceil((sample as NSString).size(withAttributes: [.font: lineInfoFont(for: settings)]).width)
        let chromeWidth = Metrics.leadingInset + Metrics.trailingInset + Metrics.separatorGap + Metrics.separatorWidth
        let minimumWidth: CGFloat
        switch (settings.terminalLineNumbersEnabled, settings.terminalTimestampsEnabled) {
        case (true, true):
            minimumWidth = Metrics.minCombinedWidth
        case (true, false):
            minimumWidth = Metrics.minLineNumberWidth
        case (false, true):
            minimumWidth = Metrics.minTimestampWidth
        case (false, false):
            minimumWidth = 0
        }
        return max(minimumWidth, measuredWidth + chromeWidth)
    }

    private func rebuild(from terminalView: TerminalView, date: Date = Date()) {
        guard isHidden == false else {
            visibleTextForTesting = ""
            visibleLineTexts.removeAll(keepingCapacity: true)
            visibleLineTimestamps.removeAll(keepingCapacity: true)
            visibleLineValues.removeAll(keepingCapacity: true)
            cellSize = .zero
            lineInfoLabelCountForTesting = 0
            lineInfoRowHeightForTesting = 0
            needsDisplay = true
            return
        }
        let terminal = terminalView.getTerminal()
        let rows = terminal.getDims().rows
        let visibleTexts = (0..<rows).map { row in
            terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
        }
        guard let lastContentRow = visibleTexts.lastIndex(where: { $0.isEmpty == false }) else {
            visibleTextForTesting = ""
            visibleLineTexts.removeAll(keepingCapacity: true)
            visibleLineTimestamps.removeAll(keepingCapacity: true)
            visibleLineValues.removeAll(keepingCapacity: true)
            cellSize = .zero
            lineInfoLabelCountForTesting = 0
            lineInfoRowHeightForTesting = 0
            needsDisplay = true
            return
        }
        visibleLineTexts = visibleLineTexts.filter { $0.key <= lastContentRow }
        visibleLineTimestamps = visibleLineTimestamps.filter { $0.key <= lastContentRow }
        for row in 0...lastContentRow where visibleLineTexts[row] != visibleTexts[row] {
            visibleLineTexts[row] = visibleTexts[row]
            visibleLineTimestamps[row] = date
        }
        let digitCount = max(2, String(lastContentRow + 1).count)
        let values = (0...lastContentRow).map { row -> String in
            let lineNumber = row + 1
            let timestamp = Self.timestampString(
                from: visibleLineTimestamps[row] ?? date,
                includeMilliseconds: settings.terminalTimestampMillisecondsEnabled
            )
            switch (settings.terminalLineNumbersEnabled, settings.terminalTimestampsEnabled) {
            case (true, true):
                return "\(timestamp)  \(Self.paddedRowNumber(lineNumber, digitCount: digitCount))"
            case (true, false):
                return Self.paddedRowNumber(lineNumber, digitCount: digitCount)
            case (false, true):
                return timestamp
            case (false, false):
                return ""
            }
        }
        visibleTextForTesting = values.joined(separator: "\n")
        let font = Self.lineInfoFont(for: settings)
        let rowHeight = Self.rowHeight(for: terminalView, font: font)
        visibleLineValues = values
        cellSize = CGSize(width: terminalView.caretFrame.size.width, height: rowHeight)
        lineInfoFont = font
        lineInfoColor = Self.lineInfoColor(for: settings)
        lineInfoFontPointSizeForTesting = font.pointSize
        lineInfoLabelCountForTesting = values.count
        lineInfoRowHeightForTesting = rowHeight
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHidden == false,
              visibleLineValues.isEmpty == false,
              let font = lineInfoFont,
              let color = lineInfoColor.map({ StacioDesignSystem.resolvedColor($0, for: self) }),
              cellSize.height > 0
        else {
            return
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        paragraphStyle.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        let textYOffset = max(0, (cellSize.height - textHeight) / 2)
        let textWidth = max(0, bounds.width - Metrics.leadingInset - Metrics.trailingInset - Metrics.separatorGap - Metrics.separatorWidth)

        for (row, value) in visibleLineValues.enumerated() {
            let rowY = bounds.height - CGFloat(row + 1) * cellSize.height
            guard rowY + cellSize.height >= dirtyRect.minY, rowY <= dirtyRect.maxY else { continue }
            let rect = NSRect(
                x: Metrics.leadingInset,
                y: rowY + textYOffset,
                width: textWidth,
                height: textHeight
            )
            (value as NSString).draw(in: rect, withAttributes: attributes)
        }
    }

    private static func timestampString(from date: Date, includeMilliseconds: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = includeMilliseconds ? "HH:mm:ss.SSS" : "HH:mm:ss"
        return "[\(formatter.string(from: date))]"
    }

    private static func sampleText(settings: AppSettings, rows: Int) -> String {
        let count = max(1, min(max(rows, 24), 80))
        let digitCount = max(2, String(count).count)
        let timestamp = settings.terminalTimestampMillisecondsEnabled ? "[88:88:88.888]" : "[88:88:88]"
        let row = String(repeating: "8", count: digitCount)
        switch (settings.terminalLineNumbersEnabled, settings.terminalTimestampsEnabled) {
        case (true, true):
            return "\(timestamp)  \(row)"
        case (true, false):
            return row
        case (false, true):
            return timestamp
        case (false, false):
            return ""
        }
    }

    private static func paddedRowNumber(_ row: Int, digitCount: Int) -> String {
        String(format: "%\(digitCount)d", row)
    }

    private static func lineInfoFont(for settings: AppSettings) -> NSFont {
        TerminalAppearanceApplier.font(for: settings)
    }

    private static func rowHeight(for terminalView: TerminalView, font: NSFont) -> CGFloat {
        let caretHeight = terminalView.caretFrame.size.height
        if caretHeight > 0 {
            return caretHeight
        }
        return ceil(font.ascender - font.descender + font.leading)
    }

    private static func terminalBackgroundColor(for settings: AppSettings) -> NSColor {
        switch settings.terminalTheme {
        case .dark:
            return TerminalColorTheme.resolvedBuiltInTheme(id: settings.terminalBuiltInThemeID).backgroundColor
        case .custom:
            return settings.customTerminalTheme?.backgroundColor ?? .textBackgroundColor
        case .system, .light:
            return .textBackgroundColor
        }
    }

    private static func lineInfoColor(for settings: AppSettings) -> NSColor {
        switch settings.terminalTheme {
        case .dark:
            return TerminalColorTheme.resolvedBuiltInTheme(id: settings.terminalBuiltInThemeID).foregroundColor.withAlphaComponent(0.48)
        case .custom:
            return (settings.customTerminalTheme?.foregroundColor ?? .secondaryLabelColor).withAlphaComponent(0.48)
        case .system:
            return StacioDesignSystem.dynamicColor(.secondaryLabelColor, alpha: 0.78)
        case .light:
            return .secondaryLabelColor.withAlphaComponent(0.78)
        }
    }

    private func applySurfaceColors() {
        let background = Self.terminalBackgroundColor(for: settings)
        let foreground = Self.lineInfoColor(for: settings)
        StacioDesignSystem.setLayerBackgroundColor(self, color: background)
        StacioDesignSystem.setLayerBackgroundColor(separator, color: foreground.withAlphaComponent(0.08))
        lineInfoColor = foreground
        needsDisplay = true
    }
}

public enum TerminalPastePreparation {
    public static func preparedPasteString(
        settings: AppSettings,
        pasteboard: NSPasteboard = .general,
        confirmer: (String) -> Bool = TerminalPastePreparation.confirmMultiLinePaste
    ) -> String? {
        if settings.terminalPasteImageAsPathEnabled,
           let path = firstFilePath(from: pasteboard) {
            return path
        }
        guard let string = pasteboard.string(forType: .string) else {
            return nil
        }
        guard string.contains("\n") || string.contains("\r") else {
            return string
        }
        if settings.terminalMultiLinePasteConfirmationEnabled == false {
            return string
        }
        return confirmer(string) ? string : nil
    }

    public static func pastePreparedString(
        into terminalView: TerminalView,
        settings: AppSettings,
        pasteboard: NSPasteboard = .general,
        confirmer: (String) -> Bool = TerminalPastePreparation.confirmMultiLinePaste
    ) -> Bool {
        guard let string = preparedPasteString(
            settings: settings,
            pasteboard: pasteboard,
            confirmer: confirmer
        ) else {
            return false
        }
        let generalPasteboard = NSPasteboard.general
        let originalItems = (generalPasteboard.pasteboardItems ?? []).map(PasteboardItemSnapshot.init)
        generalPasteboard.clearContents()
        generalPasteboard.writeObjects([string as NSString])
        terminalView.paste(terminalView)
        generalPasteboard.clearContents()
        if originalItems.isEmpty == false {
            generalPasteboard.writeObjects(originalItems.map { $0.makePasteboardItem() })
        }
        return true
    }

    private static func firstFilePath(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let fileURL = urls.first(where: { $0.isFileURL }) {
            return fileURL.path
        }
        if let fileName = pasteboard.propertyList(forType: .fileURL) as? String,
           let url = URL(string: fileName),
           url.isFileURL {
            return url.path
        }
        return nil
    }

    public static func confirmMultiLinePaste(_ string: String) -> Bool {
        let lineCount = max(1, string.components(separatedBy: .newlines).count)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认粘贴多行内容？"
        alert.informativeText = "即将向终端粘贴 \(lineCount) 行内容，可能会立即执行其中的命令。"
        alert.addButton(withTitle: L10n.Common.ok)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private struct PasteboardItemSnapshot {
        private let entries: [(type: NSPasteboard.PasteboardType, data: Data)]

        init(item: NSPasteboardItem) {
            entries = item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type, data: data)
            }
        }

        func makePasteboardItem() -> NSPasteboardItem {
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }
    }
}
