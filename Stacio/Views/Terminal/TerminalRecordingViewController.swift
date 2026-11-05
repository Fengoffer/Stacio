import AppKit
import CoreFoundation
import Foundation
import ObjectiveC
import SwiftTerm
import UniformTypeIdentifiers

public struct TerminalRecordingEvent: Equatable, Sendable {
    public let time: TimeInterval
    public let text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

public struct TerminalRecording: Equatable, Sendable {
    public let title: String?
    public let width: Int
    public let height: Int
    public let events: [TerminalRecordingEvent]
    public let duration: TimeInterval

    public init(
        title: String?,
        width: Int,
        height: Int,
        events: [TerminalRecordingEvent],
        duration: TimeInterval? = nil
    ) {
        self.title = title
        self.width = width
        self.height = height
        self.events = events
        let finalEventTime = events.reduce(0) { current, event in
            event.time.isFinite ? max(current, event.time) : current
        }
        let requestedDuration: TimeInterval
        if let duration, duration.isFinite {
            requestedDuration = duration
        } else {
            requestedDuration = finalEventTime
        }
        self.duration = max(0, finalEventTime, requestedDuration)
    }
}

public enum TerminalRecordingError: Error, Equatable, LocalizedError {
    case fileTooLarge
    case invalidUTF8
    case missingHeader
    case invalidHeader
    case unsupportedVersion
    case invalidDimensions
    case invalidEvent(line: Int)
    case timestampMovedBackward(line: Int)
    case durationTooLong
    case tooManyLines
    case tooManyEvents

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "录制文件超过 32 MiB 限制。"
        case .invalidUTF8:
            "录制文件不是有效的 UTF-8 文本。"
        case .missingHeader:
            "录制文件缺少 asciinema v2 头信息。"
        case .invalidHeader:
            "录制文件头信息无效。"
        case .unsupportedVersion:
            "仅支持 asciinema v2 录制文件。"
        case .invalidDimensions:
            "录制文件的终端尺寸无效。"
        case let .invalidEvent(line):
            "录制文件第 \(line) 行的事件无效。"
        case let .timestampMovedBackward(line):
            "录制文件第 \(line) 行的时间戳早于上一事件。"
        case .durationTooLong:
            "录制文件的回放时长超过安全上限。"
        case .tooManyLines:
            "录制文件包含过多物理行。"
        case .tooManyEvents:
            "录制文件包含过多事件。"
        }
    }
}

public enum AsciinemaV2RecordingParser {
    public static let maximumFileSize = 32 * 1024 * 1024
    public static let maximumEventCount = 250_000
    public static let maximumLineCount = 500_000
    public static let maximumPhysicalLineCount = maximumLineCount
    public static let maximumRecordingDuration: TimeInterval = 30 * 24 * 60 * 60

    public static func parse(_ data: Data) throws -> TerminalRecording {
        guard data.count <= maximumFileSize else {
            throw TerminalRecordingError.fileTooLarge
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw TerminalRecordingError.invalidUTF8
        }

        var events: [TerminalRecordingEvent] = []
        events.reserveCapacity(4_096)
        var parsedEventCount = 0
        var lastTimestamp: TimeInterval?

        var header: (title: String?, width: Int, height: Int)?
        var parsingError: TerminalRecordingError?
        var physicalLineCount = 0

        contents.enumerateLines { line, stop in
            physicalLineCount += 1
            if physicalLineCount > maximumLineCount {
                parsingError = .tooManyLines
                stop = true
                return
            }

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.isEmpty == false else { return }

            if header == nil {
                do {
                    header = try parseHeader(trimmedLine)
                } catch let error as TerminalRecordingError {
                    parsingError = error
                    stop = true
                } catch {
                    parsingError = .invalidHeader
                    stop = true
                }
                return
            }

            parsedEventCount += 1
            guard parsedEventCount <= maximumEventCount else {
                parsingError = .tooManyEvents
                stop = true
                return
            }

            let lineNumber = physicalLineCount
            guard let lineData = trimmedLine.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: lineData),
                  let event = value as? [Any],
                  event.count >= 3 else {
                parsingError = .invalidEvent(line: lineNumber)
                stop = true
                return
            }

            guard let timestamp = jsonNumber(event[0]), timestamp.isFinite, timestamp >= 0 else {
                parsingError = .invalidEvent(line: lineNumber)
                stop = true
                return
            }
            guard timestamp <= maximumRecordingDuration else {
                parsingError = .durationTooLong
                stop = true
                return
            }
            guard let kind = event[1] as? String, let text = event[2] as? String else {
                parsingError = .invalidEvent(line: lineNumber)
                stop = true
                return
            }

            if let lastTimestamp, timestamp < lastTimestamp {
                parsingError = .timestampMovedBackward(line: lineNumber)
                stop = true
                return
            }
            lastTimestamp = timestamp

            if kind == "o", text.isEmpty == false {
                events.append(TerminalRecordingEvent(time: timestamp, text: text))
            }
        }

        if let parsingError {
            throw parsingError
        }
        guard let header else {
            throw TerminalRecordingError.missingHeader
        }

        return TerminalRecording(
            title: header.title,
            width: header.width,
            height: header.height,
            events: events,
            duration: lastTimestamp ?? 0
        )
    }

    private static func parseHeader(_ line: String) throws -> (title: String?, width: Int, height: Int) {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let header = value as? [String: Any],
              let version = jsonNumber(header["version"]) else {
            throw TerminalRecordingError.invalidHeader
        }
        guard version == 2 else {
            throw TerminalRecordingError.unsupportedVersion
        }
        guard let widthValue = jsonNumber(header["width"]),
              let heightValue = jsonNumber(header["height"]),
              widthValue.rounded() == widthValue,
              heightValue.rounded() == heightValue,
              (1 ... 1_000).contains(widthValue),
              (1 ... 1_000).contains(heightValue) else {
            throw TerminalRecordingError.invalidDimensions
        }
        if let title = header["title"], title is String == false {
            throw TerminalRecordingError.invalidHeader
        }
        let title = (header["title"] as? String).map { String($0.prefix(1_024)) }
        return (title, Int(widthValue), Int(heightValue))
    }

    private static func jsonNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.doubleValue
    }
}

public enum TerminalRecordingDocument {
    public static func load(from url: URL) throws -> TerminalRecording {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values.isRegularFile == false {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        if let fileSize = values.fileSize,
           fileSize > AsciinemaV2RecordingParser.maximumFileSize {
            throw TerminalRecordingError.fileTooLarge
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try AsciinemaV2RecordingParser.parse(data)
    }
}

public enum TerminalRecordingPlaybackSpeed: Double, CaseIterable, Sendable {
    case half = 0.5
    case normal = 1
    case double = 2
}

@MainActor
public final class TerminalRecordingPlayback {
    public static let maximumSeekOutputChunkByteCount = 64 * 1024

    public let recording: TerminalRecording
    public var speed: TerminalRecordingPlaybackSpeed = .normal
    public private(set) var position: TimeInterval = 0
    public private(set) var isPlaying = false
    public var onReset: (() -> Void)?
    public var onOutput: ((String) -> Void)?
    public var onPositionChanged: ((TimeInterval) -> Void)?
    public var onPlayingChanged: ((Bool) -> Void)?

    private var nextEventIndex = 0
    private var pendingSeekTask: Task<Void, Never>?
    private var seekGeneration = 0

    public init(recording: TerminalRecording) {
        self.recording = recording
    }

    public func play() {
        guard pendingSeekTask == nil else { return }
        cancelPendingSeek()
        guard recording.events.isEmpty == false else { return }
        if position >= recording.duration, nextEventIndex >= recording.events.count {
            seek(to: 0)
        }
        setPlaying(true)
    }

    public func pause() {
        setPlaying(false)
    }

    public func seek(to requestedPosition: TimeInterval) {
        cancelPendingSeek()
        performSynchronousSeek(to: requestedPosition)
    }

    /// Starts a seek without monopolizing the main run loop while a large cast is replayed.
    /// A newer request cancels the previous one before any more output is emitted.
    public func seekAsynchronously(to requestedPosition: TimeInterval) {
        cancelPendingSeek()
        setPlaying(false)
        let target = Self.clampedPosition(requestedPosition, duration: recording.duration)
        position = target
        nextEventIndex = 0
        onReset?()
        onPositionChanged?(position)

        let generation = seekGeneration
        pendingSeekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while nextEventIndex < recording.events.count,
                  recording.events[nextEventIndex].time <= target
            {
                guard Task.isCancelled == false, generation == seekGeneration else { return }
                await emitOutputInChunks(recording.events[nextEventIndex].text)
                nextEventIndex += 1
                if nextEventIndex.isMultiple(of: 32) {
                    await Task.yield()
                }
            }
            guard Task.isCancelled == false, generation == seekGeneration else { return }
            pendingSeekTask = nil
            if position >= recording.duration, nextEventIndex >= recording.events.count {
                setPlaying(false)
            }
        }
    }

    public func cancelPendingSeek() {
        seekGeneration &+= 1
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
    }

    private func performSynchronousSeek(to requestedPosition: TimeInterval) {
        let target = Self.clampedPosition(requestedPosition, duration: recording.duration)
        position = target
        nextEventIndex = 0
        onReset?()

        var outputBuffer: [UInt8] = []
        outputBuffer.reserveCapacity(Self.maximumSeekOutputChunkByteCount)
        while nextEventIndex < recording.events.count,
              recording.events[nextEventIndex].time <= target {
            appendToSynchronousOutputBuffer(
                recording.events[nextEventIndex].text,
                buffer: &outputBuffer
            )
            nextEventIndex += 1
        }
        if outputBuffer.isEmpty == false {
            onOutput?(String(decoding: outputBuffer, as: UTF8.self))
        }
        onPositionChanged?(position)
        if position >= recording.duration, nextEventIndex >= recording.events.count {
            setPlaying(false)
        }
    }

    public func advance(by wallClockInterval: TimeInterval) {
        guard isPlaying,
              pendingSeekTask == nil,
              wallClockInterval.isFinite,
              wallClockInterval > 0 else { return }

        let target = min(
            recording.duration,
            position + wallClockInterval * speed.rawValue
        )
        var outputBuffer: [UInt8] = []
        outputBuffer.reserveCapacity(Self.maximumSeekOutputChunkByteCount)
        while nextEventIndex < recording.events.count,
              recording.events[nextEventIndex].time <= target {
            appendToSynchronousOutputBuffer(
                recording.events[nextEventIndex].text,
                buffer: &outputBuffer
            )
            nextEventIndex += 1
        }
        if outputBuffer.isEmpty == false {
            onOutput?(String(decoding: outputBuffer, as: UTF8.self))
        }

        position = target
        onPositionChanged?(position)
        if position >= recording.duration, nextEventIndex >= recording.events.count {
            setPlaying(false)
        }
    }

    private func setPlaying(_ value: Bool) {
        guard isPlaying != value else { return }
        isPlaying = value
        onPlayingChanged?(value)
    }

    private static func clampedPosition(_ value: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return min(max(0, value), duration)
    }

    private func appendToSynchronousOutputBuffer(_ text: String, buffer: inout [UInt8]) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            if buffer.count == Self.maximumSeekOutputChunkByteCount {
                onOutput?(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            }

            let available = Self.maximumSeekOutputChunkByteCount - buffer.count
            var count = min(available, bytes.count - offset)
            while count > 0,
                  offset + count < bytes.count,
                  bytes[offset + count] & 0b1100_0000 == 0b1000_0000
            {
                count -= 1
            }
            if count == 0 {
                onOutput?(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            buffer.append(contentsOf: bytes[offset ..< (offset + count)])
            offset += count
        }
    }

    private func emitOutputInChunks(_ text: String) async {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            guard Task.isCancelled else { return }
            let limit = min(bytes.count, offset + Self.maximumSeekOutputChunkByteCount)
            var end = limit
            while end > offset,
                  end < bytes.count,
                  bytes[end] & 0b1100_0000 == 0b1000_0000
            {
                end -= 1
            }
            if end == offset {
                end = limit
            }
            onOutput?(String(decoding: bytes[offset ..< end], as: UTF8.self))
            offset = end
            if offset < bytes.count {
                await Task.yield()
            }
        }
    }
}

@MainActor
public final class TerminalRecordingViewController: NSViewController {
    public let terminalView: TerminalView
    let playback: TerminalRecordingPlayback
    let playPauseButton = NSButton()
    let progressSlider = NSSlider()
    let speedControl = NSSegmentedControl(labels: ["0.5x", "1x", "2x"], trackingMode: .selectOne, target: nil, action: nil)

    private let sourceName: String
    let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let recordingTerminalSize: (columns: Int, rows: Int)
    private var playbackTimer: Timer?
    private var lastTickUptime: TimeInterval?

    public init(recording: TerminalRecording, sourceName: String) {
        terminalView = TerminalView(frame: .zero)
        playback = TerminalRecordingPlayback(recording: recording)
        self.sourceName = sourceName
        recordingTerminalSize = (recording.width, recording.height)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        playbackTimer?.invalidate()
    }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.setLayerBackgroundColor(root, color: StacioDesignSystem.theme.windowBackgroundColor)

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.setAccessibilityIdentifier("Stacio.TerminalRecording.terminal")
        terminalView.setAccessibilityLabel("录制回放：\(sourceName)")
        TerminalAppearanceApplier.apply(settings: AppSettingsStore.shared.snapshot(), to: terminalView)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.setLayerBackgroundColor(
            controls,
            color: StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.55)
        )

        configurePlayPauseButton()
        configureProgressSlider()
        configureSpeedControl()

        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        timeLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        timeLabel.alignment = .center
        timeLabel.lineBreakMode = .byClipping
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setAccessibilityIdentifier("Stacio.TerminalRecording.time")

        root.addSubview(terminalView)
        root.addSubview(separator)
        root.addSubview(controls)
        controls.addSubview(playPauseButton)
        controls.addSubview(timeLabel)
        controls.addSubview(progressSlider)
        controls.addSubview(speedControl)

        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: root.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: controls.topAnchor),

            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 46),

            playPauseButton.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 10),
            playPauseButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 30),
            playPauseButton.heightAnchor.constraint(equalToConstant: 30),

            timeLabel.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 8),
            timeLabel.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 132),

            progressSlider.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 8),
            progressSlider.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            progressSlider.trailingAnchor.constraint(equalTo: speedControl.leadingAnchor, constant: -10),

            speedControl.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -10),
            speedControl.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            speedControl.widthAnchor.constraint(equalToConstant: 142),
            speedControl.heightAnchor.constraint(equalToConstant: 28)
        ])

        view = root
        configurePlaybackCallbacks()
        if requiresAsynchronousReplay {
            playback.seekAsynchronously(to: 0)
        } else {
            playback.seek(to: 0)
        }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        enforceRecordingTerminalSize()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        playback.pause()
        playback.cancelPendingSeek()
        stopPlaybackTimer()
    }

    @objc
    func playPausePressed(_ sender: Any?) {
        if playback.isPlaying {
            playback.pause()
        } else {
            playback.play()
        }
    }

    @objc
    func progressChanged(_ sender: NSSlider) {
        playback.pause()
        playback.seekAsynchronously(to: sender.doubleValue)
        lastTickUptime = ProcessInfo.processInfo.systemUptime
    }

    @objc
    func speedChanged(_ sender: NSSegmentedControl) {
        let speeds = TerminalRecordingPlaybackSpeed.allCases
        guard speeds.indices.contains(sender.selectedSegment) else { return }
        playback.speed = speeds[sender.selectedSegment]
    }

    private func configurePlayPauseButton() {
        playPauseButton.target = self
        playPauseButton.action = #selector(playPausePressed(_:))
        playPauseButton.imagePosition = .imageOnly
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.setAccessibilityIdentifier("Stacio.TerminalRecording.playPause")
        StacioDesignSystem.styleIconButton(playPauseButton)
        updatePlayPauseButton(isPlaying: false)
    }

    private func configureProgressSlider() {
        progressSlider.minValue = 0
        progressSlider.maxValue = max(0, playback.recording.duration)
        progressSlider.doubleValue = 0
        progressSlider.isContinuous = false
        progressSlider.target = self
        progressSlider.action = #selector(progressChanged(_:))
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.setAccessibilityIdentifier("Stacio.TerminalRecording.progress")
        progressSlider.setAccessibilityLabel("回放进度")
    }

    private func configureSpeedControl() {
        speedControl.selectedSegment = 1
        speedControl.target = self
        speedControl.action = #selector(speedChanged(_:))
        speedControl.translatesAutoresizingMaskIntoConstraints = false
        speedControl.setAccessibilityIdentifier("Stacio.TerminalRecording.speed")
        speedControl.setAccessibilityLabel("回放速度")
        StacioDesignSystem.styleSegmentedControl(speedControl)
    }

    private func configurePlaybackCallbacks() {
        playback.onReset = { [weak self] in
            guard let self else { return }
            terminalView.resize(cols: playback.recording.width, rows: playback.recording.height)
            terminalView.feed(text: "\u{001B}c")
        }
        playback.onOutput = { [weak self] text in
            self?.terminalView.feed(text: text)
        }
        playback.onPositionChanged = { [weak self] position in
            self?.updateProgress(position: position)
        }
        playback.onPlayingChanged = { [weak self] isPlaying in
            guard let self else { return }
            updatePlayPauseButton(isPlaying: isPlaying)
            if isPlaying {
                startPlaybackTimer()
            } else {
                stopPlaybackTimer()
            }
        }
    }

    private func startPlaybackTimer() {
        guard playbackTimer == nil else { return }
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.playbackTimerFired()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        lastTickUptime = nil
    }

    private func playbackTimerFired() {
        let now = ProcessInfo.processInfo.systemUptime
        let previous = lastTickUptime ?? now
        lastTickUptime = now
        playback.advance(by: max(0, now - previous))
    }

    private func updatePlayPauseButton(isPlaying: Bool) {
        let label = isPlaying ? "暂停回放" : "播放录制"
        playPauseButton.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: label
        )
        playPauseButton.toolTip = label
        playPauseButton.setAccessibilityLabel(label)
    }

    private func updateProgress(position: TimeInterval) {
        progressSlider.doubleValue = position
        timeLabel.stringValue = "\(Self.formattedTime(position)) / \(Self.formattedTime(playback.recording.duration))"
    }

    private func enforceRecordingTerminalSize() {
        let terminal = terminalView.getTerminal()
        guard terminal.cols != recordingTerminalSize.columns || terminal.rows != recordingTerminalSize.rows else {
            return
        }
        terminal.resize(cols: recordingTerminalSize.columns, rows: recordingTerminalSize.rows)
        terminalView.needsDisplay = true
    }

    private var requiresAsynchronousReplay: Bool {
        let maximum = TerminalRecordingPlayback.maximumSeekOutputChunkByteCount
        let total = playback.recording.events.reduce(into: 0) { count, event in
            guard count <= maximum else { return }
            count = min(maximum + 1, count + event.text.utf8.count)
        }
        return total > maximum
    }

    private static func formattedTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "--:--" }
        let roundedSeconds = max(0, interval.rounded(.down))
        let totalSeconds = Int(min(roundedSeconds, Double(Int.max / 2)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(Self.twoDigit(hours)):\(Self.twoDigit(minutes)):\(Self.twoDigit(seconds))"
        }
        return "\(Self.twoDigit(minutes)):\(Self.twoDigit(seconds))"
    }

    private static func twoDigit(_ value: Int) -> String {
        let text = String(value)
        guard text.count < 2 else { return text }
        return "0" + text
    }
}

@MainActor
public final class TerminalRecordingWindowController: NSWindowController {
    var onClose: (() -> Void)?

    public init(recording: TerminalRecording, sourceName: String) {
        let viewController = TerminalRecordingViewController(
            recording: recording,
            sourceName: sourceName
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let recordingTitle = recording.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let recordingTitle, recordingTitle.isEmpty == false {
            window.title = recordingTitle
        } else {
            window.title = sourceName
        }
        window.minSize = NSSize(width: 620, height: 360)
        window.contentViewController = viewController
        window.setFrameAutosaveName("Stacio.TerminalRecording.window")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}

extension TerminalRecordingWindowController: NSWindowDelegate {}

@MainActor
public final class TerminalRecordingSessionRegistry {
    public static let shared = TerminalRecordingSessionRegistry()

    private final class OwnerReference {
        weak var owner: AnyObject?

        init(owner: AnyObject?) {
            self.owner = owner
        }
    }

    private final class OwnerCleanupStore {
        var tokens: [String: OwnerCleanupToken] = [:]
    }

    private final class OwnerCleanupToken {
        weak var registry: TerminalRecordingSessionRegistry?
        weak var session: TerminalRecordingSession?
        let runtimeID: String

        init(
            registry: TerminalRecordingSessionRegistry,
            session: TerminalRecordingSession,
            runtimeID: String
        ) {
            self.registry = registry
            self.session = session
            self.runtimeID = runtimeID
        }

        deinit {
            guard let registry = self.registry,
                  let session = self.session
            else {
                return
            }
            let runtimeID = self.runtimeID
            Task { @MainActor in
                registry.remove(runtimeID: runtimeID, ifMatches: session)
            }
        }
    }

    private static var ownerCleanupStoreKey: UInt8 = 0

    private var sessions: [String: TerminalRecordingSession] = [:]
    private var owners: [String: OwnerReference] = [:]

    public func session(
        for runtimeID: String,
        title: String,
        owner: AnyObject? = nil
    ) -> TerminalRecordingSession {
        prune()
        if let existing = sessions[runtimeID] {
            owners[runtimeID] = OwnerReference(owner: owner)
            bindOwner(owner, runtimeID: runtimeID, session: existing)
            return existing
        }
        let session = TerminalRecordingSession(runtimeID: runtimeID)
        sessions[runtimeID] = session
        owners[runtimeID] = OwnerReference(owner: owner)
        bindOwner(owner, runtimeID: runtimeID, session: session)
        return session
    }

    public func existingSession(for runtimeID: String) -> TerminalRecordingSession? {
        prune()
        return sessions[runtimeID]
    }

    public func remove(runtimeID: String) {
        sessions.removeValue(forKey: runtimeID)?.close()
        owners.removeValue(forKey: runtimeID)
    }

    private func remove(runtimeID: String, ifMatches expectedSession: TerminalRecordingSession) {
        guard sessions[runtimeID] === expectedSession else { return }
        remove(runtimeID: runtimeID)
    }

    private func prune() {
        for (runtimeID, owner) in owners where owner.owner == nil {
            remove(runtimeID: runtimeID)
        }
    }

    private func bindOwner(
        _ owner: AnyObject?,
        runtimeID: String,
        session: TerminalRecordingSession
    ) {
        guard let owner else { return }
        let store: OwnerCleanupStore
        if let existing = objc_getAssociatedObject(owner, &Self.ownerCleanupStoreKey) as? OwnerCleanupStore {
            store = existing
        } else {
            let created = OwnerCleanupStore()
            objc_setAssociatedObject(
                owner,
                &Self.ownerCleanupStoreKey,
                created,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            store = created
        }
        if store.tokens[runtimeID]?.session === session {
            return
        }
        store.tokens[runtimeID] = OwnerCleanupToken(
            registry: self,
            session: session,
            runtimeID: runtimeID
        )
    }
}

@MainActor
public final class TerminalRecordingWindowCoordinator: NSObject, NSMenuItemValidation {
    public static let shared = TerminalRecordingWindowCoordinator()

    private let windowProvider: @MainActor () -> NSWindow?
    private var windowController: TerminalRecordingWindowController?
    private var loadingTask: Task<Void, Never>?
    private var loadRequestID: UUID?

    public init(windowProvider: @escaping @MainActor () -> NSWindow? = { NSApplication.shared.keyWindow }) {
        self.windowProvider = windowProvider
        super.init()
    }

    @objc
    public func startRecordingCurrentTerminal(_ sender: Any?) {
        guard let target = currentTerminalTarget() else { return }
        let session = TerminalRecordingSessionRegistry.shared.session(
            for: target.runtimeID,
            title: target.agentTitle,
            owner: target as AnyObject
        )
        let dimensions = terminalDimensions(for: target)
        _ = session.start(width: dimensions.width, height: dimensions.height)
    }

    @objc
    public func stopRecordingCurrentTerminal(_ sender: Any?) {
        guard let target = currentTerminalTarget(),
              let session = TerminalRecordingSessionRegistry.shared.existingSession(for: target.runtimeID)
        else { return }
        _ = session.stop()
    }

    @objc
    public func saveRecordingCurrentTerminal(_ sender: Any?) {
        guard let target = currentTerminalTarget(),
              let session = TerminalRecordingSessionRegistry.shared.existingSession(for: target.runtimeID),
              session.hasOutput
        else { return }
        _ = session.stop()

        let panel = NSSavePanel()
        panel.title = "保存录制"
        panel.message = "保存当前终端的 asciinema v2 录制文件。"
        panel.prompt = "保存"
        panel.nameFieldStringValue = "\(target.runtimeID).cast"
        if let castType = UTType(filenameExtension: "cast") {
            panel.allowedContentTypes = [castType]
        }
        let completion: (NSApplication.ModalResponse) -> Void = { [session, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            session.save(to: url, title: target.agentTitle) { result in
                if case let .failure(error) = result {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
        if let window = windowProvider(), window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    public static func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "打开录制文件"
        panel.message = "选择 asciinema v2 .cast 录制文件。"
        panel.prompt = "打开"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let castType = UTType(filenameExtension: "cast") {
            panel.allowedContentTypes = [castType]
        }
        return panel
    }

    @objc
    public func openRecordingFile(_ sender: Any?) {
        cancelPendingLoad()
        let panel = Self.makeOpenPanel()
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            self?.loadRecording(at: url)
        }
        if let parentWindow = NSApp.keyWindow, parentWindow.isVisible {
            panel.beginSheetModal(for: parentWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func loadRecording(at url: URL) {
        cancelPendingLoad()
        let requestID = UUID()
        loadRequestID = requestID
        loadingTask = Task { [weak self] in
            do {
                let recording = try await Task.detached(priority: .userInitiated) {
                    try TerminalRecordingDocument.load(from: url)
                }.value
                guard Task.isCancelled == false,
                      let self,
                      loadRequestID == requestID else { return }
                loadingTask = nil
                present(recording: recording, sourceURL: url)
            } catch is CancellationError {
                return
            } catch {
                guard Task.isCancelled == false,
                      let self,
                      loadRequestID == requestID else { return }
                loadingTask = nil
                presentLoadError(error)
            }
        }
    }

    private func present(recording: TerminalRecording, sourceURL: URL) {
        if let previousController = windowController {
            previousController.onClose = nil
            previousController.close()
            windowController = nil
        }
        let controller = TerminalRecordingWindowController(
            recording: recording,
            sourceName: sourceURL.lastPathComponent
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, windowController === controller else { return }
            windowController = nil
        }
        windowController = controller
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
    }

    private func presentLoadError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法打开录制文件"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        if let parentWindow = NSApp.keyWindow, parentWindow.isVisible {
            alert.beginSheetModal(for: parentWindow) { _ in }
        } else {
            _ = alert.runModal()
        }
    }

    private func cancelPendingLoad() {
        loadingTask?.cancel()
        loadingTask = nil
        loadRequestID = nil
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(TerminalRecordingWindowCoordinator.startRecordingCurrentTerminal(_:))
                || menuItem.action == #selector(TerminalRecordingWindowCoordinator.stopRecordingCurrentTerminal(_:))
                || menuItem.action == #selector(TerminalRecordingWindowCoordinator.saveRecordingCurrentTerminal(_:))
        else {
            return true
        }
        guard let target = currentTerminalTarget() else { return false }
        let session = TerminalRecordingSessionRegistry.shared.existingSession(for: target.runtimeID)

        switch menuItem.action {
        case #selector(TerminalRecordingWindowCoordinator.startRecordingCurrentTerminal(_:)):
            return session?.canStart ?? true
        case #selector(TerminalRecordingWindowCoordinator.stopRecordingCurrentTerminal(_:)):
            return session?.isRecording ?? false
        case #selector(TerminalRecordingWindowCoordinator.saveRecordingCurrentTerminal(_:)):
            return session?.hasOutput == true && session?.isSaving == false
        default:
            return true
        }
    }

    private func currentTerminalTarget() -> AgentTerminalTarget? {
        guard let window = windowProvider(),
              let root = window.contentViewController
        else { return nil }
        let firstResponder = window.firstResponder as? NSView

        func descendants(of controller: NSViewController) -> [NSViewController] {
            [controller] + controller.children.flatMap(descendants)
        }

        let controllers = descendants(of: root)
        if let workspace = controllers.first(where: { $0 is WorkspaceViewController }) as? WorkspaceViewController {
            // Workspace owns the selected tab/split state. A toolbar, AI panel,
            // or file pane may be first responder without changing that choice.
            return workspace.currentAgentTerminalTarget
        }

        let candidates = controllers.compactMap { controller -> (AgentTerminalTarget, NSViewController)? in
            guard let target = controller as? AgentTerminalTarget,
                  controller.view.window === window
            else { return nil }
            return (target, controller)
        }
        if let firstResponder {
            if let current = candidates.first(where: { _, controller in
                controller.view === firstResponder || firstResponder.isDescendant(of: controller.view)
            }) {
                return current.0
            }
        }
        return candidates.first?.0
    }

    private func terminalDimensions(for target: AgentTerminalTarget) -> (width: Int, height: Int) {
        let dimensions: (Int, Int)
        if let local = target as? TerminalPaneViewController {
            let terminal = local.terminalView.getTerminal()
            dimensions = (terminal.cols, terminal.rows)
        } else if let remote = target as? RemoteTerminalPaneViewController {
            let terminal = remote.terminalView.getTerminal()
            dimensions = (terminal.cols, terminal.rows)
        } else {
            dimensions = (80, 24)
        }
        return (
            min(max(dimensions.0, 1), 1_000),
            min(max(dimensions.1, 1), 1_000)
        )
    }
}
