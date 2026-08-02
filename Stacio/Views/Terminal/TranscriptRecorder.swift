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

    public func exportAsciinema(title: String) -> String {
        var header: [String: Any] = [
            "version": 2,
            "width": 80,
            "height": 24,
            "title": String(title.prefix(1_024)),
            "env": ["TERM": "xterm-256color"]
        ]
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
