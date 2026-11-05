import Foundation

public final class TerminalSensitiveInputStateMachine {
    private enum EscapeState {
        case text
        case escape
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
    }

    private static let maximumPendingLineByteCount = 2_048

    private let timeout: TimeInterval
    private let clock: () -> Date
    private var escapeState: EscapeState = .text
    private var pendingLineBytes: [UInt8] = []
    private var isDiscardingOversizedLine = false
    private var sensitiveInputDeadline: Date?
    private var protectsNextInputAfterExpiration = false
    private var redactsNextOutputLine = false
    private var allowsCurrentPromptOutputForObservation = false

    public init(
        timeout: TimeInterval = 120,
        clock: @escaping () -> Date = Date.init
    ) {
        self.timeout = max(1, timeout)
        self.clock = clock
    }

    public var isAwaitingSensitiveInput: Bool {
        expireIfNeeded()
        return sensitiveInputDeadline != nil
    }

    public var isSensitiveInputProtectionActive: Bool {
        expireIfNeeded()
        return sensitiveInputDeadline != nil || protectsNextInputAfterExpiration
    }

    public func ingestOutput(_ bytes: [UInt8]) {
        expireIfNeeded()
        allowsCurrentPromptOutputForObservation = false
        var endedWithLineBoundary = false
        for byte in bytes {
            switch escapeState {
            case .text:
                switch byte {
                case 0x1B:
                    escapeState = .escape
                case 0x0A, 0x0D:
                    pendingLineBytes.removeAll(keepingCapacity: true)
                    isDiscardingOversizedLine = false
                    endedWithLineBoundary = true
                case 0x08, 0x7F:
                    if isDiscardingOversizedLine == false {
                        removeLastPendingCharacter()
                    }
                    endedWithLineBoundary = false
                case 0x00..<0x20:
                    continue
                default:
                    if isDiscardingOversizedLine == false {
                        pendingLineBytes.append(byte)
                        discardPendingLineIfOversized()
                    }
                    endedWithLineBoundary = false
                }
            case .escape:
                switch byte {
                case 0x5B:
                    escapeState = .controlSequence
                case 0x5D:
                    escapeState = .operatingSystemCommand
                default:
                    escapeState = .text
                }
            case .controlSequence:
                if (0x40...0x7E).contains(byte) {
                    escapeState = .text
                }
            case .operatingSystemCommand:
                if byte == 0x07 {
                    escapeState = .text
                } else if byte == 0x1B {
                    escapeState = .operatingSystemCommandEscape
                }
            case .operatingSystemCommandEscape:
                escapeState = byte == 0x5C ? .text : .operatingSystemCommand
            }
        }

        let recognizedSensitivePrompt = sensitiveInputDeadline == nil
            && endedWithLineBoundary == false
            && isDiscardingOversizedLine == false
            && Self.isInteractiveSensitivePrompt(
                String(decoding: pendingLineBytes, as: UTF8.self)
            )
        if recognizedSensitivePrompt {
            sensitiveInputDeadline = clock().addingTimeInterval(timeout)
            protectsNextInputAfterExpiration = false
            allowsCurrentPromptOutputForObservation = true
            pendingLineBytes.removeAll(keepingCapacity: true)
        }
    }

    public func noteOrdinaryInput(_ bytes: [UInt8]) {
        guard bytes.contains(10) || bytes.contains(13) else { return }
        pendingLineBytes.removeAll(keepingCapacity: true)
        isDiscardingOversizedLine = false
    }

    public func clearExpiredProtectionAfterCommandCompletion() {
        expireIfNeeded()
        guard sensitiveInputDeadline == nil else { return }
        protectsNextInputAfterExpiration = false
    }

    @discardableResult
    public func consumeSensitiveInput(_ bytes: [UInt8]) -> Bool {
        consumeSensitiveInputBytes(bytes) != nil
    }

    public func consumeSensitiveInputBytes(_ bytes: [UInt8]) -> [UInt8]? {
        guard isSensitiveInputProtectionActive else { return nil }
        guard let terminatorIndex = bytes.firstIndex(where: { byte in
            byte == 3 || byte == 10 || byte == 13
        }) else {
            return bytes
        }
        let terminator = bytes[terminatorIndex]
        leaveSensitiveMode(redactPotentialEcho: terminator != 3)
        return Array(bytes[...terminatorIndex])
    }

    public func redactOutputForObservation(_ bytes: [UInt8]) -> [UInt8] {
        if redactsNextOutputLine {
            guard let boundary = bytes.firstIndex(where: { $0 == 10 || $0 == 13 }) else {
                if allowsCurrentPromptOutputForObservation {
                    redactsNextOutputLine = false
                    allowsCurrentPromptOutputForObservation = false
                    return bytes
                }
                return []
            }
            var suffixStart = bytes.index(after: boundary)
            while suffixStart < bytes.endIndex, bytes[suffixStart] == 10 || bytes[suffixStart] == 13 {
                suffixStart = bytes.index(after: suffixStart)
            }
            redactsNextOutputLine = false
            allowsCurrentPromptOutputForObservation = false
            return Array(bytes[suffixStart...])
        }
        if allowsCurrentPromptOutputForObservation {
            allowsCurrentPromptOutputForObservation = false
            return bytes
        }
        if isSensitiveInputProtectionActive {
            return []
        }
        return bytes
    }

    public func reset() {
        escapeState = .text
        pendingLineBytes.removeAll(keepingCapacity: false)
        isDiscardingOversizedLine = false
        sensitiveInputDeadline = nil
        protectsNextInputAfterExpiration = false
        redactsNextOutputLine = false
        allowsCurrentPromptOutputForObservation = false
    }

    var retainedOutputByteCountForTesting: Int {
        pendingLineBytes.count
    }

    private func expireIfNeeded() {
        guard let sensitiveInputDeadline,
              clock() >= sensitiveInputDeadline
        else { return }
        self.sensitiveInputDeadline = nil
        protectsNextInputAfterExpiration = true
        pendingLineBytes.removeAll(keepingCapacity: true)
        isDiscardingOversizedLine = false
    }

    private func leaveSensitiveMode(redactPotentialEcho: Bool) {
        sensitiveInputDeadline = nil
        protectsNextInputAfterExpiration = false
        pendingLineBytes.removeAll(keepingCapacity: true)
        isDiscardingOversizedLine = false
        redactsNextOutputLine = redactPotentialEcho
        allowsCurrentPromptOutputForObservation = false
    }

    private func removeLastPendingCharacter() {
        guard pendingLineBytes.isEmpty == false else { return }
        var scalarStart = pendingLineBytes.index(before: pendingLineBytes.endIndex)
        while scalarStart > pendingLineBytes.startIndex,
              pendingLineBytes[scalarStart] & 0xC0 == 0x80 {
            scalarStart = pendingLineBytes.index(before: scalarStart)
        }
        pendingLineBytes.removeSubrange(scalarStart...)
    }

    private func discardPendingLineIfOversized() {
        guard pendingLineBytes.count > Self.maximumPendingLineByteCount else { return }
        pendingLineBytes.removeAll(keepingCapacity: true)
        isDiscardingOversizedLine = true
    }

    private static func isInteractiveSensitivePrompt(_ line: String) -> Bool {
        let candidate = line.trimmingCharacters(in: .whitespaces)
        guard candidate.isEmpty == false else { return false }
        let lowered = candidate.lowercased()
        let rejectedMarkers = [
            "authentication failed",
            "incorrect password",
            "invalid password",
            "password policy",
            "错误密码",
            "密码错误",
            "密码失败"
        ]
        guard rejectedMarkers.contains(where: lowered.contains) == false else {
            return false
        }
        let hasSensitivePromptMarker = lowered.contains("password")
            || lowered.contains("passphrase")
            || candidate.contains("密码")
        guard hasSensitivePromptMarker,
              candidate.hasSuffix(":") || candidate.hasSuffix("：")
        else { return false }
        let patterns = [
            #"(?i)^(?:\((?:current|old|new)\)\s*)?(?:(?:enter|type|retype|repeat|confirm)\s+)?(?:(?:current|old|new)\s+)?(?:unix\s+)?password(?:\s*\((?:again|current|old|new)\))?\s*:\s*$"#,
            #"(?i)^(?:\[[^\]]{1,32}\]\s*)?(?:enter\s+)?(?:ssh\s+)?password(?:\s+for\s+[^:\r\n]{1,160})?\s*:\s*$"#,
            #"(?i)^[^\s\r\n]{1,240}'s\s+password\s*:\s*$"#,
            #"(?i)^(?:enter\s+)?passphrase(?:\s+for\s+(?:key\s+)?[^:\r\n]{1,200})?\s*:\s*$"#,
            #"^(?:(?:请)?(?:重新|再次)?(?:输入|键入)|(?:请)?确认)?\s*(?:当前|原|旧|新|新的|确认|再次)?\s*(?:[^：:\r\n]{1,64}的\s*)?密码\s*[：:]\s*$"#,
            #"^(?:(?:请)?(?:输入|键入))?\s*(?:[^：:\r\n]{1,64}的\s*)?密码\s*[：:]\s*$"#
        ]
        return patterns.contains { pattern in
            candidate.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
