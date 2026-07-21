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
