import AppKit
import SwiftTerm

public enum TerminalLinkInteraction {
    public enum CursorStyle: Equatable {
        case text
        case link
    }

    public static func handleEvent(in terminalView: TerminalView, event: NSEvent) -> NSEvent? {
        guard isEventInsideTerminal(terminalView, event: event) else {
            return event
        }

        switch event.type {
        case .leftMouseUp:
            guard let link = commandClickLink(in: terminalView, event: event) else {
                return event
            }
            terminalView.terminalDelegate?.requestOpenLink(source: terminalView, link: link, params: [:])
            return nil
        case .mouseMoved, .flagsChanged:
            updateCursor(in: terminalView, event: event)
            return event
        default:
            return event
        }
    }

    public static func commandClickLink(in terminalView: TerminalView, event: NSEvent) -> String? {
        guard event.modifierFlags.contains(.command) else {
            return nil
        }
        return link(in: terminalView, event: event)
    }

    public static func updateCursor(in terminalView: TerminalView, event: NSEvent? = nil) {
        switch cursorStyle(in: terminalView, event: event) {
        case .text:
            NSCursor.iBeam.set()
        case .link:
            NSCursor.pointingHand.set()
        }
    }

    public static func cursorStyle(in terminalView: TerminalView, event: NSEvent? = nil) -> CursorStyle {
        let flags = event?.modifierFlags ?? NSEvent.modifierFlags
        guard flags.contains(.command),
              let link = event.flatMap({ link(in: terminalView, event: $0) })
                ?? linkAtCurrentMouseLocation(in: terminalView),
              isActionable(link)
        else {
            return .text
        }
        return .link
    }

    public static func link(in terminalView: TerminalView, event: NSEvent) -> String? {
        link(in: terminalView, at: terminalView.convert(event.locationInWindow, from: nil))
    }

    public static func link(in terminalView: TerminalView, at point: NSPoint) -> String? {
        guard terminalView.bounds.contains(point),
              let position = screenPosition(in: terminalView, at: point)
        else {
            return nil
        }

        if let swiftTermLink = terminalView.terminal.link(at: .screen(position), mode: .explicitAndImplicit),
           TerminalLinkURLNormalizer.browserURL(from: swiftTermLink) != nil {
            return swiftTermLink
        }
        return bareLink(in: terminalView, at: position)
    }

    private static func isEventInsideTerminal(_ terminalView: TerminalView, event: NSEvent) -> Bool {
        terminalView.bounds.contains(terminalView.convert(event.locationInWindow, from: nil))
    }

    private static func linkAtCurrentMouseLocation(in terminalView: TerminalView) -> String? {
        guard let window = terminalView.window else {
            return nil
        }
        return link(
            in: terminalView,
            at: terminalView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        )
    }

    private static func screenPosition(in terminalView: TerminalView, at point: NSPoint) -> Position? {
        let cols = max(terminalView.terminal.cols, 1)
        let rows = max(terminalView.terminal.rows, 1)
        guard terminalView.bounds.width > 0,
              terminalView.bounds.height > 0
        else {
            return nil
        }
        let col = min(max(Int((point.x / terminalView.bounds.width) * CGFloat(cols)), 0), cols - 1)
        let row = min(max(Int(((terminalView.bounds.height - point.y) / terminalView.bounds.height) * CGFloat(rows)), 0), rows - 1)
        return Position(col: col, row: row)
    }

    private static func bareLink(in terminalView: TerminalView, at position: Position) -> String? {
        guard let line = terminalView.terminal.getLine(row: position.row) else {
            return nil
        }
        let text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
        guard text.isEmpty == false else {
            return nil
        }
        return bareLink(in: text, atColumn: position.col)
    }

    private static func bareLink(in text: String, atColumn column: Int) -> String? {
        let matches = bareLinkRegex.matches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        for match in matches {
            guard let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            guard column >= start && column < end else {
                continue
            }
            let candidate = String(text[range])
            if isActionable(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func isActionable(_ link: String) -> Bool {
        TerminalLinkURLNormalizer.browserURL(from: link) != nil
            || TerminalLinkURLNormalizer.terminalPath(from: link) != nil
    }

    private static let bareLinkRegex: NSRegularExpression = {
        let host =
            #"(?:(?:localhost)|(?:(?:\d{1,3}\.){3}\d{1,3})|(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{1,62})"#
        let port = #"(?::\d{1,5})?"#
        let path = #"(?:/[^\s<>"']*)?"#
        let filesystemPath = #"(?:(?:/|\./|\../|~/?)[A-Za-z0-9._~+\-/%:@]+)"#
        let pattern = #"(?<![A-Za-z0-9@._-])("# + host + port + path + #"|"# + filesystemPath + #")"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()
}
