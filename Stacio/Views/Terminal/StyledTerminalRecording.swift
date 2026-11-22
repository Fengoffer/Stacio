import AppKit
import CoreText
import CryptoKit
import SwiftTerm

/// Owned by a terminal pane, never by a replaceable transport/runtime ID.
/// All screen access occurs on the UI thread; file work uses a private queue.
final class StyledTerminalRecording: TerminalContentObserver {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stacio/Recordings", isDirectory: true)
    }
    static func suggestedFileName(title: String, date: Date = Date()) -> String {
        TerminalRTFWriter.suggestedFileName(title: title, date: date)
    }
    private static let active = NSHashTable<StyledTerminalRecording>.weakObjects()
    private var view: TerminalView?
    private let writer: TerminalRTFWriter
    private var pending: [RecordedTerminalRun] = []
    private var pendingSize = 0
    private var timer: Timer?
    private var screenIsDirty = true
    private(set) var isRecording = true
    var fileURL: URL { writer.destination }
    var error: Error? { writer.error }

    // Clear-screen and alternate-buffer transitions can expose a previously
    // recorded row again. Weak keys do not retain the scrollback or its text.
    private let committed = NSMapTable<BufferLine, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let initialRows = NSMapTable<BufferLine, InitialRow>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    private final class InitialRow {
        let runs: [RecordedTerminalRun]
        let glyphs: [RecordedTerminalGlyph]
        init(_ runs: [RecordedTerminalRun]) {
            self.runs = runs
            var glyphs = runs.flatMap { run in run.text.map { RecordedTerminalGlyph(character: $0, run: run) } }
            while glyphs.last?.character.isWhitespace == true { glyphs.removeLast() }
            self.glyphs = glyphs
        }
    }

    init(view: TerminalView, title: String, directory: URL = defaultDirectory, date: Date = Date(), fileURL: URL? = nil,
         onError: @escaping (Error) -> Void = { _ in }) throws {
        self.view = view
        writer = try TerminalRTFWriter(directory: directory, title: title, date: date, fileURL: fileURL,
                                       font: view.font, cellWidth: view.renderedCellWidth,
                                       cellHeight: view.renderedCellHeight,
                                       columns: view.getTerminal().cols, onError: onError)
        let terminal = view.getTerminal()
        // Existing scrollback is part of the content available when recording starts.
        for row in terminal.buffer.totalLinesTrimmed..<terminal.screenStartRow {
            if let line = terminal.getScrollInvariantLine(row: row) { append(line, terminal: terminal) }
        }
        for line in viewportLines(terminal) {
            initialRows.setObject(InitialRow(capture(line, terminal: terminal)), forKey: line)
        }
        terminal.contentObserver = self
        flush()
        persistViewport()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.persistViewport()
        }
        Self.active.add(self)
    }

    func terminal(_ terminal: Terminal, willScrollOut line: BufferLine) {
        guard isRecording else { return }
        append(line, terminal: terminal)
        screenIsDirty = true
    }

    func terminalWillDiscardScreen(_ terminal: Terminal) {
        guard isRecording else { return }
        for line in viewportLines(terminal) { append(line, terminal: terminal) }
        flush()
        screenIsDirty = true
    }

    func terminalDidUpdate(_ terminal: Terminal) {
        guard isRecording else { return }
        flush()
        screenIsDirty = true
    }

    func terminalDidResize(_ terminal: Terminal) {
        // The old layout was committed before reflow. Do not repeat unchanged
        // reflowed rows, but allow subsequent edits to those rows to be captured.
        for line in viewportLines(terminal) {
            committed.setObject(NSNumber(value: line.generation), forKey: line)
        }
        writer.clearTail()
        writer.updateColumns(terminal.cols)
        screenIsDirty = false
    }

    func finish() {
        guard isRecording else { return }
        if let terminal = view?.getTerminal() {
            terminalWillDiscardScreen(terminal)
            if terminal.contentObserver === self { terminal.contentObserver = nil }
        }
        isRecording = false
        timer?.invalidate()
        timer = nil
        writer.clearTail()
        writer.finish()
        Self.active.remove(self)
        view = nil
    }

    /// Application termination must not kill an outstanding asynchronous save.
    static func finishAllAndWait() {
        for recording in active.allObjects { recording.finish() }
        TerminalRTFWriter.saves.wait()
    }

    func waitUntilSaved() { writer.wait() }

    deinit {
        finish()
    }

    private func viewportLines(_ terminal: Terminal) -> [BufferLine] {
        var lines = (0..<terminal.rows).compactMap {
            terminal.getScrollInvariantLine(row: terminal.screenStartRow + $0)
        }
        // Exclude unused rows below the cursor, but preserve intentional blank lines.
        while lines.count > terminal.buffer.y + 1,
              let last = lines.last, !last.hasAnyContent() {
            lines.removeLast()
        }
        return lines
    }

    private func append(_ line: BufferLine, terminal: Terminal) {
        guard committed.object(forKey: line)?.uint64Value != line.generation else { return }
        let runs = capture(line, terminal: terminal)
        if let original = initialRows.object(forKey: line) {
            // Normally the existing prompt simply acquires a command suffix. If
            // it was overwritten instead, preserve the screen seen at Start too.
            let current = runs.flatMap { run in run.text.map { RecordedTerminalGlyph(character: $0, run: run) } }
            if !current.starts(with: original.glyphs) { enqueue(original.runs) }
            initialRows.removeObject(forKey: line)
        }
        enqueue(runs)
        committed.setObject(NSNumber(value: line.generation), forKey: line)
    }

    private func enqueue(_ runs: [RecordedTerminalRun]) {
        pending.append(contentsOf: runs)
        pendingSize += runs.reduce(0) { $0 + $1.text.utf8.count + $1.cells.count * MemoryLayout<RecordedTerminalCell>.stride + 64 }
        if pendingSize >= 64 * 1_024 { flush() }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        writer.append(pending, estimatedSize: pendingSize)
        pending.removeAll(keepingCapacity: true)
        pendingSize = 0
    }

    private func persistViewport() {
        guard isRecording, screenIsDirty, let terminal = view?.getTerminal() else { return }
        let runs = viewportLines(terminal).filter {
            committed.object(forKey: $0)?.uint64Value != $0.generation
        }.flatMap { capture($0, terminal: terminal) }
        writer.updateTail(runs)
        screenIsDirty = false
    }

    private func capture(_ line: BufferLine, terminal: Terminal) -> [RecordedTerminalRun] {
        guard let view else { return [] }
        var runs: [RecordedTerminalRun] = []
        var previous: Attribute?
        var run: RecordedTerminalRun?
        var column = 0
        // Keep trailing cells as well: background colors and table spacing matter.
        while column < min(line.count, terminal.cols) {
            let cell = line[column]
            let width = max(1, Int(cell.width))
            if cell.attribute != previous {
                if let run { runs.append(run) }
                let attributes = view.getAttributes(cell.attribute, withUrl: false) ?? [:]
                run = RecordedTerminalRun(
                    text: "", foreground: Self.rgb(attributes[.foregroundColor] as? NSColor ?? view.nativeForegroundColor),
                    background: Self.rgb(attributes[.backgroundColor] as? NSColor ?? view.nativeBackgroundColor),
                    flags: cell.attribute.style.rawValue,
                    underlineColor: Self.rgb(attributes[.underlineColor] as? NSColor ?? view.nativeForegroundColor),
                    underlineStyle: cell.attribute.underlineStyle.rawValue
                )
                previous = cell.attribute
            }
            let character = terminal.getCharacter(for: cell)
            if cell.attribute.style.contains(.invisible) || character == "\0" {
                run?.text += String(repeating: " ", count: width)
                run?.cells.append(contentsOf: repeatElement(RecordedTerminalCell(character: " ", width: 1), count: width))
            } else {
                run?.text.append(character)
                run?.cells.append(RecordedTerminalCell(character: character, width: UInt8(width)))
            }
            column += width
        }
        if var run {
            run.text += "\n"
            run.cells.append(RecordedTerminalCell(character: "\n", width: 0))
            runs.append(run)
        }
        return runs
    }

    private static func rgb(_ color: NSColor) -> UInt32 {
        let rgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) ?? .white
        func byte(_ value: CGFloat) -> UInt32 { UInt32(min(255, max(0, (value * 255).rounded()))) }
        return byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
    }
}

private struct RecordedTerminalCell {
    let character: Character
    let width: UInt8
}

private struct RecordedTerminalRun {
    var text: String
    var cells: [RecordedTerminalCell] = []
    let foreground: UInt32
    let background: UInt32
    let flags: UInt8
    let underlineColor: UInt32
    let underlineStyle: UInt8
}

private struct RecordedTerminalGlyph: Equatable {
    let character: Character
    let foreground: UInt32
    let background: UInt32
    let flags: UInt8
    let underlineColor: UInt32
    let underlineStyle: UInt8
    init(character: Character, run: RecordedTerminalRun) {
        self.character = character
        foreground = run.foreground
        background = run.background
        flags = run.flags
        underlineColor = run.underlineColor
        underlineStyle = run.underlineStyle
    }
}

/// A streamed RTF body and a small replaceable viewport, not an in-memory history.
/// The color table is assembled at completion, then the body is copied in chunks.
/// Working files survive an I/O failure so a failed save never deletes the log.
private final class TerminalRTFWriter: @unchecked Sendable {
    static let saves = DispatchGroup()
    let destination: URL
    private let workingDirectory: URL
    private let bodyURL: URL
    private let tailURL: URL
    private let body: FileHandle
    private let queue = DispatchQueue(label: "cn.stacio.terminal.rtf.\(UUID().uuidString)", qos: .utility)
    private let lock = NSLock()
    private var failure: Error?
    private var finishing = false
    private var queuedBytes = 0
    private var colors: [UInt32] = []
    private var colorIndexes: [UInt32: Int] = [:]
    private var storedColorCount = 0
    private var lastSync = Date.distantPast
    private let fontName: String
    private let fontSize: Int
    private var paperWidth: Int
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat
    private let layoutFont: NSFont
    private var layoutFonts: [UInt8: NSFont] = [:]
    private struct GlyphKey: Hashable {
        let character: Character
        let style: UInt8
        let width: UInt8
    }
    private struct GlyphLayout {
        let advance: Double
        let fontSizeMillis: Int
        let baselineHalfPoints: Int
    }
    private struct StyledCell {
        let cell: RecordedTerminalCell
        let flags: CharacterStyle
        let style: String
    }
    private var glyphLayouts: [GlyphKey: GlyphLayout] = [:]
    private let onError: (Error) -> Void
    private let originalDestination: DestinationRevision?
    var error: Error? { lock.withLock { failure } }

    private struct DestinationRevision: Equatable {
        let fileID: UInt64
        let size: UInt64
        let modified: Date

        static func read(_ url: URL) throws -> Self {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let fileID = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else {
                throw CocoaError(.fileWriteFileExists)
            }
            return Self(fileID: fileID.uint64Value, size: size.uint64Value, modified: modified)
        }
    }

    static func suggestedFileName(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let sanitized = title.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) ? "_" : String($0)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var name = ""
        for character in sanitized.isEmpty ? "Terminal" : sanitized {
            guard name.utf8.count + String(character).utf8.count <= 180 else { break }
            name.append(character)
        }
        if name.isEmpty { name = "Terminal" }
        return "\(formatter.string(from: date))_\(name).rtf"
    }

    init(directory: URL, title: String, date: Date, fileURL: URL?, font: NSFont, cellWidth: CGFloat, cellHeight: CGFloat, columns: Int,
         onError: @escaping (Error) -> Void) throws {
        let directory = fileURL?.deletingLastPathComponent() ?? directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suggestedName = Self.suggestedFileName(title: title, date: date)
        let stem = String(suggestedName.dropLast(4))
        originalDestination = try fileURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path) ? try DestinationRevision.read(url) : nil
        }
        // Reserve a hidden working directory atomically; the final document only
        // appears after close, with no empty placeholder for the user to open.
        var candidate = fileURL ?? directory.appendingPathComponent(suggestedName)
        let caseSensitive = (try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? false
        func workingURL(for destination: URL) -> URL {
            let name = destination.lastPathComponent.precomposedStringWithCanonicalMapping
            let key = caseSensitive ? name : name.lowercased()
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return directory.appendingPathComponent(".stacio-\(digest).recording", isDirectory: true)
        }
        var working = workingURL(for: candidate)
        while true {
            if fileURL != nil || !FileManager.default.fileExists(atPath: candidate.path) {
                if Darwin.mkdir(working.path, S_IRWXU) == 0 { break }
                // An explicit destination must not silently turn into a different
                // filename when another recording already owns that location.
                if fileURL != nil { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            candidate = directory.appendingPathComponent(stem + "_" + String(UUID().uuidString.prefix(8)) + ".rtf")
            working = workingURL(for: candidate)
        }
        destination = candidate
        workingDirectory = working
        bodyURL = workingDirectory.appendingPathComponent("body")
        tailURL = workingDirectory.appendingPathComponent("tail")
        fontName = font.fontName
        fontSize = Int((font.pointSize * 2).rounded())
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        layoutFont = NSFont(name: font.fontName, size: CGFloat(fontSize) / 2) ?? font
        paperWidth = max(12_240, Int(CGFloat(columns + 4) * cellWidth * 20))
        self.onError = onError
        do {
            try Data().write(to: bodyURL)
            body = try FileHandle(forWritingTo: bodyURL)
        } catch {
            try? FileManager.default.removeItem(at: workingDirectory)
            throw error
        }
    }

    func append(_ runs: [RecordedTerminalRun], estimatedSize: Int) {
        // Bound queued work without a byte-count truncation limit. In the unusual
        // case of a slow disk, apply backpressure instead of silently dropping text.
        if lock.withLock({ queuedBytes > 8 * 1_024 * 1_024 }) { queue.sync {} }
        lock.withLock { queuedBytes += estimatedSize }
        queue.async { [self] in
            defer { lock.withLock { queuedBytes -= estimatedSize } }
            perform {
                let encoded = encode(runs)
                try storePalette()
                try body.write(contentsOf: encoded)
                if Date().timeIntervalSince(lastSync) >= 2 {
                    try body.synchronize()
                    lastSync = Date()
                }
            }
        }
    }

    func updateTail(_ runs: [RecordedTerminalRun]) {
        queue.async { [self] in
            perform {
                let encoded = encode(runs)
                try storePalette()
                try encoded.write(to: tailURL, options: .atomic)
            }
        }
    }

    func finish() {
        guard lock.withLock({ if finishing { return false }; finishing = true; return true }) else { return }
        Self.saves.enter()
        queue.async { [self] in
            defer { Self.saves.leave(); try? body.close() }
            perform {
                try body.synchronize()
                // Explicit finish has appended the final viewport to body. A
                // teardown fallback uses the last periodically persisted viewport.
                let output = workingDirectory.appendingPathComponent("complete.rtf")
                try Data(header().utf8).write(to: output)
                let handle = try FileHandle(forWritingTo: output)
                defer { try? handle.close() }
                try handle.seekToEnd()
                let input = try FileHandle(forReadingFrom: bodyURL)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 256 * 1_024), !chunk.isEmpty {
                    try handle.write(contentsOf: chunk)
                }
                if FileManager.default.fileExists(atPath: tailURL.path) {
                    try handle.write(contentsOf: Data(contentsOf: tailURL))
                }
                try handle.write(contentsOf: Data("}".utf8))
                try handle.synchronize()
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                if let originalDestination {
                    // The save panel authorized replacing this version only. A
                    // long recording must not overwrite a later external edit.
                    guard try DestinationRevision.read(destination) == originalDestination else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: output)
                } else {
                    try FileManager.default.moveItem(at: output, to: destination)
                }
                try FileManager.default.removeItem(at: workingDirectory)
            }
        }
    }

    func clearTail() {
        queue.async { [self] in perform { try Data().write(to: tailURL, options: .atomic) } }
    }

    func updateColumns(_ columns: Int) {
        queue.async { [self] in
            perform {
                paperWidth = max(paperWidth, Int(CGFloat(columns + 4) * cellWidth * 20))
                try storePalette(force: true)
            }
        }
    }

    func wait() { queue.sync {} }

    private func perform(_ action: () throws -> Void) {
        guard error == nil else { return }
        do { try action() } catch {
            lock.withLock { failure = error }
            let reported = NSError(domain: "Stacio.TerminalRecording", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "终端录制无法写入文件：\(error.localizedDescription)",
                NSLocalizedRecoverySuggestionErrorKey: "已写入的内容保留在 \(workingDirectory.path)。请检查可用磁盘空间和目录权限。终端连接仍会继续。"
            ])
            DispatchQueue.main.async { [onError] in onError(reported) }
        }
    }

    private func colorIndex(_ color: UInt32) -> Int {
        if let index = colorIndexes[color] { return index }
        colors.append(color)
        colorIndexes[color] = colors.count
        return colors.count
    }

    private func storePalette(force: Bool = false) throws {
        guard force || storedColorCount != colors.count else { return }
        // Also stores enough information to reconstruct an interrupted recording.
        let metadata: [String: Any] = ["colors": colors, "font": fontName, "fontSize": fontSize,
                                       "paperWidth": paperWidth, "lineHeight": Int((cellHeight * 20).rounded()),
                                       "destination": destination.lastPathComponent]
        try JSONSerialization.data(withJSONObject: metadata).write(
            to: workingDirectory.appendingPathComponent("metadata.json"), options: .atomic)
        storedColorCount = colors.count
    }

    private func header() -> String {
        let palette = colors.map { "\\red\(($0 >> 16) & 255)\\green\(($0 >> 8) & 255)\\blue\($0 & 255);" }.joined()
        // AppKit treats the legacy table as calibrated RGB. Its expanded table
        // preserves the actual sRGB colors instead of shifting them on import.
        let expanded = colors.map { color in
            func component(_ shift: UInt32) -> Int { Int((Double((color >> shift) & 255) / 255 * 100_000).rounded()) }
            return "\\cssrgb\\c\(component(16))\\c\(component(8))\\c\(component(0));"
        }.joined()
        return "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fmodern \(Self.escape(fontName));}}{\\colortbl;\(palette)}{\\*\\expandedcolortbl;\(expanded)}\\paperw\(paperWidth)\\margl120\\margr120\\viewkind4\\uc1\\pard\\sl-\(Int((cellHeight * 20).rounded()))\\slmult0\\f0\\fs\(fontSize)\\CocoaLigature0 "
    }

    private func encode(_ runs: [RecordedTerminalRun]) -> Data {
        var result = ""
        var row: [StyledCell] = []
        for run in runs {
            let flags = CharacterStyle(rawValue: run.flags)
            let background = colorIndex(run.background)
            var style = "\\cf\(colorIndex(run.foreground))\\cb\(background)\\highlight\(background)"
            style += flags.contains(.bold) ? "\\b" : "\\b0"
            style += flags.contains(.italic) ? "\\i" : "\\i0"
            style += flags.contains(.crossedOut) ? "\\strike" : "\\strike0"
            if flags.contains(.underline) {
                let variants: [UInt8: String] = [2: "\\uldb", 3: "\\ulwave", 4: "\\uld", 5: "\\uldash"]
                style += (variants[run.underlineStyle] ?? "\\ul") + "\\ulc\(colorIndex(run.underlineColor))"
            } else { style += "\\ulnone" }
            for cell in run.cells {
                if cell.character == "\n" {
                    result += encodeRow(row)
                    row.removeAll(keepingCapacity: true)
                } else {
                    row.append(StyledCell(cell: cell, flags: flags, style: style))
                }
            }
        }
        // Captured rows always end in a newline; keep this safe for a partial row.
        if !row.isEmpty { result += encodeRow(row) }
        return Data(result.utf8)
    }

    private func encodeRow(_ row: [StyledCell]) -> String {
        // RTF character backgrounds follow text advances. Keep every origin
        // on the cell grid: shifting a glyph through indentation or the previous
        // character's tracking also shifts that character's background boundary.
        var result = "\\fi0 "
        var actualX = 0.0
        var columnX = 0.0
        var previousStyle: String?
        var previousSize: Int?
        var previousBaseline: Int?
        var previousTracking: Int?
        for value in row {
            let layout = glyphLayout(value.cell, flags: value.flags)
            if value.style != previousStyle {
                result += value.style + " "
                previousStyle = value.style
            }
            if layout.fontSizeMillis != previousSize {
                // Standard RTF has half-point sizes. AppKit's fsmilli preserves
                // the smaller adjustment needed to fit a fallback glyph.
                result += "\\fs\(Int((Double(layout.fontSizeMillis) / 500).rounded()))\\fsmilli\(layout.fontSizeMillis) "
                previousSize = layout.fontSizeMillis
            }
            if layout.baselineHalfPoints != previousBaseline {
                result += "\\up\(layout.baselineHalfPoints) "
                previousBaseline = layout.baselineHalfPoints
            }
            columnX += Double(value.cell.width) * cellWidth
            let tracking = Int(((columnX - actualX - layout.advance) * 20).rounded())
            if tracking != previousTracking {
                // A zero expansion alone restores automatic CJK/Latin spacing.
                result += tracking == 0 ? "\\expndtw0\\kerning0 " : "\\kerning1\\expndtw\(tracking) "
                previousTracking = tracking
            }
            result += Self.escape(String(value.cell.character))
            actualX += layout.advance + Double(tracking) / 20
        }
        // Keep the base font on the newline so fallback-only rows share a baseline.
        result += "\\fs\(fontSize)\\fsmilli\(fontSize * 500)\\up0\\par\n"
        return result
    }

    private func glyphLayout(_ cell: RecordedTerminalCell, flags: CharacterStyle) -> GlyphLayout {
        let style = flags.intersection([.bold, .italic]).rawValue
        let key = GlyphKey(character: cell.character, style: style, width: cell.width)
        if let layout = glyphLayouts[key] { return layout }
        let font: NSFont
        if let cached = layoutFonts[style] { font = cached }
        else {
            var traits: CTFontSymbolicTraits = []
            if flags.contains(.bold) { traits.insert(.traitBold) }
            if flags.contains(.italic) { traits.insert(.traitItalic) }
            if let styled = CTFontCreateCopyWithSymbolicTraits(layoutFont, 0, nil, traits, [.traitBold, .traitItalic]) {
                font = styled as NSFont
            } else { font = layoutFont }
            layoutFonts[style] = font
        }
        func measure(_ sizeMillis: Int) -> (advance: Double, ink: CGRect, needsFit: Bool) {
            let sizedFont = CTFontCreateCopyWithAttributes(font, CGFloat(sizeMillis) / 1_000, nil, nil)
            let text = NSAttributedString(string: String(cell.character), attributes: [.font: sizedFont, .kern: 0, .ligature: 0])
            let line = CTLineCreateWithAttributedString(text)
            let needsFit = cell.width >= 2 || (CTLineGetGlyphRuns(line) as! [CTRun]).contains { run in
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName] as! CTFont
                return !CTFontGetSymbolicTraits(runFont).contains(.traitMonoSpace)
            }
            return (CTLineGetTypographicBounds(line, nil, nil, nil),
                    CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]), needsFit)
        }
        let slotWidth = Double(cell.width) * cellWidth
        var sizeMillis = fontSize * 500
        var metrics = measure(sizeMillis)
        let needsFit = metrics.needsFit && !metrics.ink.isEmpty && !metrics.ink.isNull
        if needsFit {
            // Match the renderer's fit within a terminal slot. Remeasure after
            // scaling: bitmap/fallback font advances need not scale linearly.
            for _ in 0..<3 {
                // Include the right bearing so ink fits from the fixed cell
                // origin, without shifting adjacent background boundaries.
                let inkWidth = max(metrics.ink.width, metrics.ink.maxX)
                let scale = min(1, min(slotWidth / inkWidth, cellHeight / metrics.ink.height))
                guard scale < 1, sizeMillis > 1_000 else { break }
                sizeMillis = max(1_000, Int((Double(sizeMillis) * scale).rounded(.down)))
                metrics = measure(sizeMillis)
            }
        }
        var baseline = 0
        if needsFit {
            if sizeMillis != fontSize * 500 {
                let baselineFromBottom = ceil(CTFontGetDescent(layoutFont) + CTFontGetLeading(layoutFont))
                baseline = Int(((cellHeight / 2 - baselineFromBottom - metrics.ink.midY) * 2).rounded())
            }
        }
        let layout = GlyphLayout(advance: metrics.advance,
                                 fontSizeMillis: sizeMillis, baselineHalfPoints: baseline)
        // Bound the cache for long recordings containing many distinct glyphs.
        if glyphLayouts.count >= 2_048 { glyphLayouts.removeAll(keepingCapacity: true) }
        glyphLayouts[key] = layout
        return layout
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        for unit in value.utf16 {
            switch unit {
            case 10: result += "\\line\n"
            case 92, 123, 125: result += "\\" + String(UnicodeScalar(unit)!)
            case 32...126: result += String(UnicodeScalar(unit)!)
            default: result += "\\u\(Int16(bitPattern: unit))?"
            }
        }
        return result
    }
}
