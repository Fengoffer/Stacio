import Foundation

/// Coalesces token-level deltas before waking the UI. The interval limits the
/// refresh rate; the character target lets a slow, character-at-a-time source
/// accumulate a readable batch. Maximum latency keeps short replies responsive.
final class StreamingDeltaCoalescer {
    private let lock = NSLock()
    // Take this gate before draining the buffer, so concurrent flushers cannot
    // take successive payloads and then emit them in the opposite order.
    private let emitGate = NSLock()
    private var buffer = ""
    private var bufferStartedAt: DispatchTime?
    private var hasPendingFlush = false
    private var flushGeneration: UInt = 0
    private let minimumCharacterCount: Int
    private let interval: TimeInterval
    private let maximumLatency: TimeInterval
    private let emit: (String) -> Void
    private var isClosed = false

    init(
        interval: TimeInterval = 0.016,
        minimumCharacterCount: Int = 0,
        maximumLatency: TimeInterval? = nil,
        emit: @escaping (String) -> Void
    ) {
        // Frame-paced by default. A character quota looked calmer on paper,
        // but a relay emitting under two characters per event then held text
        // back for hundreds of milliseconds: the answer arrived in visible
        // jumps and finished long after the server stopped sending.
        let interval = max(0.001, interval)
        self.minimumCharacterCount = max(0, minimumCharacterCount)
        self.interval = interval
        self.maximumLatency = max(interval, maximumLatency ?? interval * 2)
        self.emit = emit
    }

    func append(_ fragment: String) {
        guard fragment.isEmpty == false else { return }
        lock.lock()
        guard isClosed == false else {
            lock.unlock()
            return
        }
        if buffer.isEmpty {
            bufferStartedAt = .now()
        }
        buffer += fragment
        guard hasPendingFlush == false else {
            lock.unlock()
            return
        }
        hasPendingFlush = true
        flushGeneration &+= 1
        let generation = flushGeneration
        lock.unlock()
        scheduleFlush(generation: generation, after: interval)
    }

    /// Explicit flushes bypass the batching target, including the final tail.
    /// Returns only after all earlier emissions and this payload are delivered.
    func flush() {
        emitGate.lock()
        defer { emitGate.unlock() }
        lock.lock()
        let payload = drainBuffer()
        lock.unlock()
        if payload.isEmpty == false {
            emit(payload)
        }
    }

    private func scheduleFlush(generation: UInt, after delay: TimeInterval) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flushScheduled(generation: generation)
        }
    }

    private func flushScheduled(generation: UInt) {
        emitGate.lock()
        defer { emitGate.unlock() }
        lock.lock()
        guard generation == flushGeneration, hasPendingFlush, isClosed == false else {
            lock.unlock()
            return
        }
        let elapsed = bufferStartedAt.map {
            Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000
        } ?? maximumLatency
        if buffer.count < minimumCharacterCount, elapsed < maximumLatency {
            let delay = min(interval, maximumLatency - elapsed)
            lock.unlock()
            scheduleFlush(generation: generation, after: delay)
            return
        }
        let payload = drainBuffer()
        lock.unlock()
        if payload.isEmpty == false {
            emit(payload)
        }
    }

    /// The caller holds lock. A generation also invalidates callbacks from a
    /// batch that was explicitly flushed before its scheduled deadline.
    private func drainBuffer() -> String {
        let payload = buffer
        buffer = ""
        bufferStartedAt = nil
        hasPendingFlush = false
        flushGeneration &+= 1
        return payload
    }

    func finish() {
        lock.lock()
        isClosed = true
        lock.unlock()
        flush()
    }
}
