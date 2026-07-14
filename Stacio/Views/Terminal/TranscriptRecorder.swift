import Foundation

public final class TranscriptRecorder {
    private var storage = ""

    public init() {}

    public var snapshot: String {
        storage
    }

    public func append(bytes: [UInt8]) {
        let text = String(decoding: bytes, as: UTF8.self)
        storage.append(text)
    }

    public func reset() {
        storage.removeAll(keepingCapacity: true)
    }
}
