import Foundation

/// Samples byte counters over a bounded time window, independently of redraw frequency.
/// The first counter is a baseline: already transferred/resumed bytes are never a new burst.
struct TransferRateSampler {
    private struct Sample {
        let bytes: UInt64
        let time: Date
    }

    private var samples: [Sample] = []
    private var latest: Sample?
    private var lastProgressAt: Date?
    private var measuredRate: Double?
    private var baselineID: UUID?

    mutating func update(bytesDone: UInt64, status: String, at time: Date, baselineID: UUID? = nil) -> Double? {
        if self.baselineID != baselineID {
            self = Self()
            self.baselineID = baselineID
        }
        let sample = Sample(bytes: bytesDone, time: time)
        guard status == "running" || status == "resuming" else {
            self = Self()
            return nil
        }
        guard let previous = latest, bytesDone >= previous.bytes, time >= previous.time else {
            samples = [sample]
            latest = sample
            lastProgressAt = nil
            measuredRate = nil
            return nil
        }
        latest = sample
        if bytesDone > previous.bytes { lastProgressAt = time }

        // Keep the last accepted sample until enough time accumulates. Updating it
        // on every 100 ms poll (or duplicate repaint) loses the measurement interval.
        guard let last = samples.last, time.timeIntervalSince(last.time) >= 0.2 else {
            return measuredRate
        }
        samples.append(sample)
        while samples.count > 2, time.timeIntervalSince(samples[1].time) >= 1 {
            samples.removeFirst()
        }
        if let lastProgressAt, time.timeIntervalSince(lastProgressAt) >= 1.5 {
            measuredRate = 0
        } else if let first = samples.first, bytesDone > first.bytes {
            measuredRate = Double(bytesDone - first.bytes) / time.timeIntervalSince(first.time)
        }
        return measuredRate
    }
}
