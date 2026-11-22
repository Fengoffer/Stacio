import AppKit

/// A flipped container so vertical stacks grow downward from the top edge,
/// which is the natural reading order for a chat transcript.
public final class AIAssistantFlippedView: NSView {
    override public var isFlipped: Bool { true }
}

/// Stack variant of `AIAssistantFlippedView`.
public final class AIAssistantFlippedStackView: NSStackView {
    override public var isFlipped: Bool { true }
}

/// Wall-clock bounds for one collapsed group of process entries, used to
/// render the "processing / processed Ns" summary line.
public struct AIProcessGroupTiming {
    public let startedAt: Date
    public var completedAt: Date?

    public init(startedAt: Date, completedAt: Date? = nil) {
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
