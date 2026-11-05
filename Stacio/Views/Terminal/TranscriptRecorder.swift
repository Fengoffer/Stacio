import Foundation

public final class TranscriptRecorder {
    public static let defaultMaximumByteCount = 2 * 1024 * 1024

    private var storage = ""
    private var storageByteCount = 0
    private let maximumByteCount: Int

    public init() {
        self.maximumByteCount = TranscriptRecorder.defaultMaximumByteCount
    }

    public init(maximumByteCount: Int) {
        self.maximumByteCount = max(0, maximumByteCount)
    }

    public var snapshot: String {
        storage
    }

    public func append(bytes: [UInt8]) {
        guard maximumByteCount > 0, bytes.isEmpty == false else {
            return
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let textByteCount = text.utf8.count
        guard textByteCount > 0 else {
            return
        }
        storage.append(text)
        storageByteCount += textByteCount
        retainRecentOutputIfNeeded()
    }

    public func reset() {
        storage.removeAll(keepingCapacity: true)
        storageByteCount = 0
    }

    private func retainRecentOutputIfNeeded() {
        guard storageByteCount > maximumByteCount else {
            return
        }

        let utf8 = storage.utf8
        var startIndex = utf8.index(utf8.endIndex, offsetBy: -maximumByteCount)
        while startIndex < utf8.endIndex,
              utf8[startIndex] & 0b1100_0000 == 0b1000_0000
        {
            startIndex = utf8.index(after: startIndex)
        }
        storage = String(decoding: utf8[startIndex...], as: UTF8.self)
        storageByteCount = storage.utf8.count
    }
}

public final class TimestampedRecorder {
    public private(set) var entries: [(t: Date, text: String)] = []

    /// Keep enough headroom for asciinema JSON framing so exports remain readable by the player.
    public static let defaultMaximumByteCount = AsciinemaV2RecordingParser.maximumFileSize / 2
    public static let defaultMaximumEntryCount = AsciinemaV2RecordingParser.maximumEventCount

    public private(set) var isTruncated = false

    private let maximumByteCount: Int
    private let maximumEntryCount: Int
    private var storedByteCount = 0
    private var pendingUTF8Bytes: [UInt8] = []
    private var pendingTimestamp: Date?

    public init(
        maximumByteCount: Int = TimestampedRecorder.defaultMaximumByteCount,
        maximumEntryCount: Int = TimestampedRecorder.defaultMaximumEntryCount
    ) {
        self.maximumByteCount = min(
            max(0, maximumByteCount),
            TimestampedRecorder.defaultMaximumByteCount
        )
        self.maximumEntryCount = min(
            max(0, maximumEntryCount),
            TimestampedRecorder.defaultMaximumEntryCount
        )
    }

    public func append(bytes: [UInt8], timestamp: Date) {
        guard bytes.isEmpty == false else { return }

        if isTruncated {
            return
        }

        let availableByteCount = maximumByteCount - storedByteCount
        guard availableByteCount > 0 else {
            isTruncated = true
            pendingUTF8Bytes.removeAll(keepingCapacity: false)
            pendingTimestamp = nil
            return
        }
        let acceptedByteLimit = availableByteCount + 3
        let acceptedBytes = bytes.count > acceptedByteLimit
            ? Array(bytes.prefix(acceptedByteLimit))
            : bytes
        let inputWasTruncated = acceptedBytes.count < bytes.count

        let textTimestamp = pendingTimestamp ?? timestamp
        var combined = pendingUTF8Bytes
        combined.append(contentsOf: acceptedBytes)

        if let suffixStart = Self.incompleteUTF8SuffixStart(in: combined) {
            pendingUTF8Bytes = Array(combined[suffixStart...])
            pendingTimestamp = textTimestamp
            combined.removeLast(combined.count - suffixStart)
        } else {
            pendingUTF8Bytes.removeAll(keepingCapacity: true)
            pendingTimestamp = nil
        }

        guard combined.isEmpty == false else { return }
        appendDecodedText(String(decoding: combined, as: UTF8.self), timestamp: textTimestamp)
        if inputWasTruncated {
            isTruncated = true
            pendingUTF8Bytes.removeAll(keepingCapacity: false)
            pendingTimestamp = nil
        }
    }

    public func reset() {
        entries.removeAll(keepingCapacity: true)
        storedByteCount = 0
        isTruncated = false
        pendingUTF8Bytes.removeAll(keepingCapacity: true)
        pendingTimestamp = nil
    }

    public func exportAsciinema(
        title: String,
        width: Int = 80,
        height: Int = 24
    ) -> String {
        let safeWidth = min(max(width, 1), 1_000)
        let safeHeight = min(max(height, 1), 1_000)
        var header: [String: Any] = [
            "version": 2,
            "width": safeWidth,
            "height": safeHeight,
            "title": String(title.prefix(1_024)),
            "env": ["TERM": "xterm-256color"]
        ]
        if isTruncated {
            // asciinema ignores unknown header fields; this makes an intentionally
            // bounded recording loss explicit to Stacio and other tooling.
            header["stacio_truncated"] = true
        }
        let firstTimestamp = entries.first?.t ?? pendingTimestamp
        if let firstTimestamp {
            header["timestamp"] = Self.unixTimestamp(for: firstTimestamp)
        }

        var output = Self.jsonLine(header) + "\n"
        output.reserveCapacity(min(
            AsciinemaV2RecordingParser.maximumFileSize,
            max(output.utf8.count, storedByteCount + entries.count * 32)
        ))
        guard let firstTimestamp else { return output }

        var lastOffset: TimeInterval = 0
        for entry in entries {
            let candidateOffset = entry.t.timeIntervalSince(firstTimestamp)
            if candidateOffset.isFinite {
                lastOffset = max(lastOffset, max(0, candidateOffset))
            }
            output.append(Self.jsonLine([lastOffset, "o", entry.text]))
            output.append("\n")
        }
        if pendingUTF8Bytes.isEmpty == false,
           isTruncated == false,
           entries.count < maximumEntryCount
        {
            let pendingText = String(decoding: pendingUTF8Bytes, as: UTF8.self)
            let pendingTimestamp = pendingTimestamp ?? entries.last?.t ?? firstTimestamp
            let candidateOffset = pendingTimestamp.timeIntervalSince(firstTimestamp)
            if candidateOffset.isFinite {
                lastOffset = max(lastOffset, max(0, candidateOffset))
            }
            if pendingText.isEmpty == false {
                output.append(Self.jsonLine([lastOffset, "o", pendingText]))
                output.append("\n")
            }
        }
        return output
    }

    public func markTruncated() {
        isTruncated = true
        pendingUTF8Bytes.removeAll(keepingCapacity: false)
        pendingTimestamp = nil
    }

    private func appendDecodedText(_ text: String, timestamp: Date) {
        guard text.isEmpty == false else { return }
        guard maximumEntryCount > 0, maximumByteCount > storedByteCount else {
            isTruncated = true
            pendingUTF8Bytes.removeAll(keepingCapacity: true)
            pendingTimestamp = nil
            return
        }
        guard entries.count < maximumEntryCount else {
            isTruncated = true
            pendingUTF8Bytes.removeAll(keepingCapacity: true)
            pendingTimestamp = nil
            return
        }

        let bytes = Array(text.utf8)
        let availableByteCount = maximumByteCount - storedByteCount
        let retainedByteCount = Self.validUTF8PrefixLength(bytes, maximumByteCount: availableByteCount)
        guard retainedByteCount > 0 else {
            isTruncated = true
            pendingUTF8Bytes.removeAll(keepingCapacity: true)
            pendingTimestamp = nil
            return
        }

        let retainedText = String(decoding: bytes.prefix(retainedByteCount), as: UTF8.self)
        entries.append((t: timestamp, text: retainedText))
        storedByteCount += retainedText.utf8.count

        if retainedByteCount < bytes.count {
            isTruncated = true
            pendingUTF8Bytes.removeAll(keepingCapacity: true)
            pendingTimestamp = nil
        }
    }

    private static func validUTF8PrefixLength(_ bytes: [UInt8], maximumByteCount: Int) -> Int {
        let count = min(bytes.count, max(0, maximumByteCount))
        guard count > 0 else { return 0 }
        var end = count
        while end > 0, end < bytes.count, bytes[end] & 0b1100_0000 == 0b1000_0000 {
            end -= 1
        }
        return end
    }

    private static func incompleteUTF8SuffixStart(in bytes: [UInt8]) -> Int? {
        guard bytes.isEmpty == false else { return nil }
        let firstCandidate = max(0, bytes.count - 4)
        for start in stride(from: bytes.count - 1, through: firstCandidate, by: -1) {
            let lead = bytes[start]
            let expectedLength: Int
            switch lead {
            case 0xC2 ... 0xDF: expectedLength = 2
            case 0xE0 ... 0xEF: expectedLength = 3
            case 0xF0 ... 0xF4: expectedLength = 4
            default: continue
            }

            let actualLength = bytes.count - start
            guard actualLength < expectedLength else { continue }
            guard bytes[(start + 1) ..< bytes.count].allSatisfy({ $0 & 0b1100_0000 == 0b1000_0000 }) else {
                continue
            }
            if actualLength >= 2,
               Self.isInvalidSecondByte(lead: lead, second: bytes[start + 1])
            {
                continue
            }
            return start
        }
        return nil
    }

    private static func isInvalidSecondByte(lead: UInt8, second: UInt8) -> Bool {
        switch lead {
        case 0xE0: return second < 0xA0
        case 0xED: return second > 0x9F
        case 0xF0: return second < 0x90
        case 0xF4: return second > 0x8F
        default: return false
        }
    }

    private static func unixTimestamp(for date: Date) -> Int64 {
        let value = date.timeIntervalSince1970.rounded(.down)
        guard value.isFinite else { return 0 }
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value)
    }

    private static func jsonLine(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return line
    }
}

/// Owns one terminal's recording lifecycle. Output is accepted into a small
/// protected buffer and drained on a utility queue. State reads and stop never
/// wait for that queue, so a high-throughput terminal cannot freeze AppKit.
public final class TerminalRecordingSession: @unchecked Sendable {
    public static let maximumPendingByteCount = 512 * 1024
    public static let maximumPendingChunkCount = 512

    private struct PendingOutput {
        let bytes: [UInt8]
        let timestamp: Date
    }

    private let queue = DispatchQueue(
        label: "com.stacio.terminal-recording-session",
        qos: .utility
    )
    private let stateLock = NSLock()
    private let recorder: TimestampedRecorder
    private let hub: TerminalOutputBroadcastHub?
    private let runtimeID: String?
    private var subscription: TerminalOutputBroadcastHub.Subscription?
    private var pendingOutputs: [PendingOutput] = []
    private var pendingByteCount = 0
    private var drainScheduled = false
    private var recording = false
    private var recordedOutput = false
    private var unsavedOutput = false
    private var didTruncateOutput = false
    private var saveInFlight = false
    private var closed = false
    private var recordingWidth = 80
    private var recordingHeight = 24
    private let pendingByteLimit: Int
    private let pendingChunkLimit: Int

    public convenience init(
        recorder: TimestampedRecorder = TimestampedRecorder(),
        runtimeID: String? = nil,
        hub: TerminalOutputBroadcastHub? = nil
    ) {
        self.init(
            recorder: recorder,
            runtimeID: runtimeID,
            hub: hub,
            pendingByteLimit: Self.maximumPendingByteCount,
            pendingChunkLimit: Self.maximumPendingChunkCount
        )
    }

    internal init(
        recorder: TimestampedRecorder,
        runtimeID: String? = nil,
        hub: TerminalOutputBroadcastHub? = nil,
        pendingByteLimit: Int,
        pendingChunkLimit: Int
    ) {
        self.recorder = recorder
        self.runtimeID = runtimeID
        self.hub = runtimeID == nil ? nil : (hub ?? .shared)
        self.pendingByteLimit = min(max(0, pendingByteLimit), Self.maximumPendingByteCount)
        self.pendingChunkLimit = min(max(0, pendingChunkLimit), Self.maximumPendingChunkCount)
        pendingOutputs.reserveCapacity(self.pendingChunkLimit)
    }

    public var isRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recording
    }

    public var hasOutput: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedOutput
    }

    public var canStart: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recording == false && unsavedOutput == false && saveInFlight == false && closed == false
    }

    public var hasUnsavedOutput: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return unsavedOutput
    }

    public var isSaving: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return saveInFlight
    }

    // Kept internal for deterministic pressure tests without exposing queue state to UI.
    var pendingByteCountForTesting: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingByteCount
    }

    var pendingChunkCountForTesting: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingOutputs.count
    }

    var didTruncateOutputForTesting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return didTruncateOutput
    }

    /// Starts a fresh recording. Repeated starts and starts with unsaved output are no-ops.
    @MainActor
    @discardableResult
    public func start(width: Int = 80, height: Int = 24) -> Bool {
        stateLock.lock()
        guard recording == false,
              unsavedOutput == false,
              saveInFlight == false,
              closed == false
        else {
            stateLock.unlock()
            return false
        }
        recording = true
        recordedOutput = false
        didTruncateOutput = false
        pendingOutputs.removeAll(keepingCapacity: true)
        pendingByteCount = 0
        recordingWidth = Self.clampedDimension(width)
        recordingHeight = Self.clampedDimension(height)
        // Queue reset is ordered before any newly scheduled drain and does not
        // block the main actor behind a previous export.
        queue.async { [weak self] in
            self?.recorder.reset()
        }
        stateLock.unlock()

        guard let runtimeID,
              let hub,
              subscription == nil
        else {
            return true
        }
        subscription = hub.subscribe(runtimeID: runtimeID) { [weak self] event in
            guard event.kind == .output else { return }
            self?.append(bytes: event.bytes, timestamp: event.createdAt)
        }
        return true
    }

    @MainActor
    @discardableResult
    public func stop() -> Bool {
        stateLock.lock()
        guard recording else {
            stateLock.unlock()
            return false
        }
        recording = false
        let subscription = self.subscription
        self.subscription = nil
        stateLock.unlock()

        if let runtimeID, let hub, let subscription {
            hub.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        return true
    }

    @MainActor
    public func close() {
        stateLock.lock()
        recording = false
        closed = true
        let subscription = self.subscription
        self.subscription = nil
        let shouldResetRecorder = saveInFlight == false
        // A save already queued owns the immutable lifecycle until its write
        // completes. Do not discard its accepted pending output here.
        if shouldResetRecorder {
            pendingOutputs.removeAll(keepingCapacity: false)
            pendingByteCount = 0
            recordedOutput = false
            unsavedOutput = false
            didTruncateOutput = false
        }
        stateLock.unlock()

        if let runtimeID, let hub, let subscription {
            hub.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        if shouldResetRecorder {
            queue.async { [weak self] in
                self?.recorder.reset()
            }
        }
    }

    /// Accepts at most the configured pending capacity. The terminal callback
    /// performs only a lock, bounded copy, and one queue scheduling operation.
    public func append(bytes: [UInt8], timestamp: Date = Date()) {
        guard bytes.isEmpty == false else { return }
        var shouldScheduleDrain = false

        stateLock.lock()
        guard recording, closed == false, didTruncateOutput == false else {
            stateLock.unlock()
            return
        }
        let availableByteCount = pendingByteLimit - pendingByteCount
        guard availableByteCount > 0,
              pendingOutputs.count < pendingChunkLimit
        else {
            didTruncateOutput = true
            if drainScheduled == false {
                drainScheduled = true
                shouldScheduleDrain = true
            }
            stateLock.unlock()
            if shouldScheduleDrain {
                queue.async { [weak self] in
                    self?.drainPendingOutputs()
                }
            }
            return
        }

        let acceptedByteCount = min(bytes.count, availableByteCount)
        guard acceptedByteCount > 0 else {
            didTruncateOutput = true
            if drainScheduled == false {
                drainScheduled = true
                shouldScheduleDrain = true
            }
            stateLock.unlock()
            if shouldScheduleDrain {
                queue.async { [weak self] in
                    self?.drainPendingOutputs()
                }
            }
            return
        }
        // Copy only the accepted prefix so an oversized caller-owned backing
        // buffer cannot stay alive through a bounded pending chunk.
        let accepted = Array(bytes.prefix(acceptedByteCount))
        pendingOutputs.append(PendingOutput(bytes: accepted, timestamp: timestamp))
        pendingByteCount += accepted.count
        recordedOutput = true
        unsavedOutput = true
        if acceptedByteCount < bytes.count {
            didTruncateOutput = true
        }
        if drainScheduled == false {
            drainScheduled = true
            shouldScheduleDrain = true
        }
        if shouldScheduleDrain {
            queue.async { [weak self] in
                self?.drainPendingOutputs()
            }
        }
        stateLock.unlock()
    }

    public func exportAsciinema(
        title: String,
        width: Int? = nil,
        height: Int? = nil
    ) -> String {
        queue.sync {
            let dimensions = dimensionsSnapshot()
            return recorder.exportAsciinema(
                title: title,
                width: width ?? dimensions.width,
                height: height ?? dimensions.height
            )
        }
    }

    public func save(
        to url: URL,
        title: String,
        width: Int? = nil,
        height: Int? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            DispatchQueue.main.async {
                completion(.failure(NSError(
                    domain: "Stacio.TerminalRecordingSession",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "录制会话已关闭。"]
                )))
            }
            return
        }
        if saveInFlight {
            stateLock.unlock()
            DispatchQueue.main.async {
                completion(.failure(NSError(
                    domain: "Stacio.TerminalRecordingSession",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "当前录制正在保存。"]
                )))
            }
            return
        }
        saveInFlight = true
        stateLock.unlock()

        // Strongly capture the session for the whole drain/export/write. This
        // also guarantees exactly one completion if the owner window closes.
        queue.async { [self] in
            let result: Result<URL, Error>
            do {
                let dimensions = dimensionsSnapshot()
                let data = Data(
                    recorder.exportAsciinema(
                        title: title,
                        width: width ?? dimensions.width,
                        height: height ?? dimensions.height
                    ).utf8
                )
                try data.write(to: url, options: .atomic)
                result = .success(url)
            } catch {
                result = .failure(error)
            }

            stateLock.lock()
            saveInFlight = false
            let shouldResetAfterClose = closed
            if case .success = result {
                unsavedOutput = false
            }
            if shouldResetAfterClose {
                recordedOutput = false
                unsavedOutput = false
                didTruncateOutput = false
                pendingOutputs.removeAll(keepingCapacity: false)
                pendingByteCount = 0
            }
            stateLock.unlock()

            if shouldResetAfterClose {
                recorder.reset()
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func drainPendingOutputs() {
        while true {
            let output: PendingOutput
            let shouldFinalizeTruncation: Bool
            stateLock.lock()
            if pendingOutputs.isEmpty {
                shouldFinalizeTruncation = didTruncateOutput && recorder.isTruncated == false
                drainScheduled = false
                stateLock.unlock()
                if shouldFinalizeTruncation {
                    recorder.markTruncated()
                }
                return
            }
            output = pendingOutputs.removeFirst()
            pendingByteCount -= output.bytes.count
            stateLock.unlock()

            recorder.append(bytes: output.bytes, timestamp: output.timestamp)
            if recorder.isTruncated {
                stateLock.lock()
                didTruncateOutput = true
                stateLock.unlock()
            }
        }
    }

    private func dimensionsSnapshot() -> (width: Int, height: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (recordingWidth, recordingHeight)
    }

    private static func clampedDimension(_ dimension: Int) -> Int {
        min(max(dimension, 1), 1_000)
    }

    deinit {
        if let runtimeID, let hub, let subscription {
            Task { @MainActor in
                hub.unsubscribe(runtimeID: runtimeID, subscription: subscription)
            }
        }
    }
}
