import Foundation

public enum TerminalSemanticHighlightProfile: Equatable, Sendable {
    case generalPurpose
    case networkDeviceConsole
}

public enum TerminalSemanticOutputHighlighter {
    private struct Rule {
        let group: String
        let pattern: String
        let role: TerminalHighlightSemanticRole
        let options: NSRegularExpression.Options
        let captureGroup: Int
        let bold: Bool
        let underline: Bool
        let background: Bool

        init(
            group: String,
            pattern: String,
            role: TerminalHighlightSemanticRole,
            options: NSRegularExpression.Options = [.caseInsensitive],
            captureGroup: Int = 0,
            bold: Bool = false,
            underline: Bool = false,
            background: Bool = false
        ) {
            self.group = group
            self.pattern = pattern
            self.role = role
            self.options = options
            self.captureGroup = captureGroup
            self.bold = bold
            self.underline = underline
            self.background = background
        }

        var regex: NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    private struct CompiledRule {
        let rule: Rule
        let regex: NSRegularExpression
    }

    private struct VisiblePromptProjection {
        let text: String
        let sourceOffsets: [Int]

        func sourceRange(for visibleRange: NSRange) -> NSRange? {
            guard visibleRange.location >= 0,
                  visibleRange.length > 0,
                  visibleRange.location < sourceOffsets.count
            else {
                return nil
            }
            let lastVisibleOffset = visibleRange.location + visibleRange.length - 1
            guard lastVisibleOffset < sourceOffsets.count else {
                return nil
            }
            let start = sourceOffsets[visibleRange.location]
            let end = sourceOffsets[lastVisibleOffset] + 1
            guard end > start else {
                return nil
            }
            return NSRange(location: start, length: end - start)
        }
    }

    private static let maximumHighlightedLineLength = 8_192
    private static let maximumHighlightedByteCount = 512 * 1_024
    private static let portDeskMarkupStartPayload = "777;StacioHighlight=start"
    private static let portDeskMarkupEndPayload = "777;StacioHighlight=end"

    private static let compiledRules: [CompiledRule] = ruleGroups
        .flatMap { $0 }
        .map { CompiledRule(rule: $0, regex: $0.regex) }

    private static let compiledPromptRules: [CompiledRule] = compiledRules
        .filter { $0.rule.group == "prompt" }

    private static let compiledIncompleteLineRules: [CompiledRule] = compiledRules
        .filter { ["prompt", "status", "time", "network", "git"].contains($0.rule.group) }

    private static let compiledNetworkDeviceRules: [CompiledRule] = networkDeviceRuleGroups
        .flatMap { $0 }
        .map { CompiledRule(rule: $0, regex: $0.regex) }

    private static let ruleGroups: [[Rule]] = [
        [
            Rule(group: "prompt", pattern: #"^\r?(\[[A-Za-z0-9._-]{1,64}@[A-Za-z0-9._-]{1,128}\s+(?:~(?:/[^\]\r\n]{0,160})?|/[^\]\r\n]{0,240}|[^\]\r\n$#%]{1,160})\][#$]\s?)"#, role: .prompt, captureGroup: 1, bold: true, background: true),
            Rule(group: "prompt", pattern: #"^\r?([A-Za-z0-9._-]{1,64}@[A-Za-z0-9._-]{1,128}:(?:~(?:/[^\s\r\n$#%]{0,160})?|/[^\s\r\n$#%]{0,240}|[^\s\r\n$#%]{1,160})[#$%]\s?)"#, role: .prompt, captureGroup: 1, bold: true, background: true),
            Rule(group: "prompt", pattern: #"^\r?([A-Za-z0-9._-]{1,64}@[A-Za-z0-9._-]{1,128}\s+(?:~(?:/[^\s\r\n$#%]{0,160})?|/[^\s\r\n$#%]{0,240}|[^\s\r\n$#%]{1,160})\s+[$#%]\s?)"#, role: .prompt, captureGroup: 1, bold: true, background: true)
        ],
        [
            Rule(group: "links", pattern: #"https?://[^\s<>"']+"#, role: .link, underline: true)
        ],
        [
            Rule(group: "motd", pattern: #"\b(system information|information)\b"#, role: .info, bold: true),
            Rule(group: "motd", pattern: #"\b(release|do-release-upgrade)\b"#, role: .flag, bold: true),
            Rule(group: "motd", pattern: #"(?<!\S)(--update|--upgradable)\b"#, role: .flag, captureGroup: 1, bold: true)
        ],
        [
            Rule(group: "status", pattern: #"\b(Error response from daemon|No such container|command not found|permission denied|access denied|denied|failed|failure|fatal|panic|error|fail)\b"#, role: .error, bold: true),
            Rule(group: "status", pattern: #"\b(warn|warning|level=warn|level=warning)\b"#, role: .warning, bold: true),
            Rule(group: "status", pattern: #"\b(ok|success|succeeded|pass|passed|level=info|info)\b"#, role: .success, bold: true),
            Rule(group: "status", pattern: #"\b(active\s+\(running\)|enabled|running)(?=\s|;|,|$)"#, role: .success, bold: true),
            Rule(group: "status", pattern: #"\b(inactive|disabled|exited|stopped)\b"#, role: .warning)
        ],
        [
            Rule(group: "time", pattern: #"\btime=\"[^\"]+\""#, role: .time),
            Rule(group: "time", pattern: #"\b\d{4}-\d{2}-\d{2}[T ][0-9:.+-]*Z?\b"#, role: .time),
            Rule(group: "time", pattern: #"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}(?:\s+\d{2}:\d{2}:\d{2})?\b"#, role: .time),
            Rule(group: "time", pattern: #"\bsince\s+[^\n;]+"#, role: .time)
        ],
        [
            Rule(group: "version", pattern: #"(?<![\w.-])\d+(?:\.\d+){1,2}(?:-[A-Za-z0-9._+-]+)*(?![\w.%+-])"#, role: .version, bold: true)
        ],
        [
            Rule(group: "network", pattern: #"\[[0-9A-Fa-f:.]+\](?::\d{1,5})"#, role: .address),
            Rule(group: "network", pattern: #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?(?![\d.])"#, role: .address),
            Rule(group: "network", pattern: #"(?<![A-Fa-f0-9:])(?:[A-Fa-f0-9]{1,4}:){3,}[A-Fa-f0-9]{0,4}(?![A-Fa-f0-9:])"#, role: .address)
        ],
        [
            Rule(group: "ops", pattern: #"(^|\n)(●\s+[^\n]+?\.service)"#, role: .info, captureGroup: 2, bold: true),
            Rule(group: "ops", pattern: #"\b(?:container|module|namespace|topic|type|eid|ep|net|nid|msg|host-port|container-ip)=(?:"[^"]*"|[^\s,]+)"#, role: .resource)
        ],
        [
            Rule(group: "process", pattern: #"\bpid=\d+\b"#, role: .number),
            Rule(group: "process", pattern: #"\bstatus=\d+\b"#, role: .error),
            Rule(group: "process", pattern: #"\bexit\s+(?:code|status)\s+\d+\b"#, role: .error),
            Rule(group: "numeric", pattern: #"\b\d+(?:\.\d+)?%"#, role: .number),
            Rule(group: "numeric", pattern: #"\b\d+(?:\.\d+)?\s?(?:KiB|MiB|GiB|TiB|PiB|EiB|KB|MB|GB|TB|PB|EB|B|K|M|G|T|P|E)\b"#, role: .number),
            Rule(group: "numeric", pattern: #"(?<![\w./:-])\d+(?:\.\d+)?(?![\w./:-])"#, role: .number)
        ],
        [
            Rule(group: "filesystem", pattern: #"(?<!\S)[bcdlps-]?[rwxstST-]{9}(?!\S)"#, role: .permission),
            Rule(group: "filesystem", pattern: #"(?<![\w.-])0?[0-7]{3,4}(?![\w.-])"#, role: .permission),
            Rule(group: "filesystem", pattern: #"(?<![\w.-])(/[A-Za-z0-9._~+\-/%:@ ]+)"#, role: .path),
            Rule(group: "filesystem", pattern: #"(?<!\S)[A-Za-z_][A-Za-z0-9_.-]*:[A-Za-z_][A-Za-z0-9_.-]*(?!\S)"#, role: .environment)
        ],
        [
            Rule(group: "git", pattern: #"\b(?:modified|untracked|renamed|deleted|staged|unstaged|ahead|behind|diverged)\b"#, role: .git, bold: true),
            Rule(group: "git", pattern: #"\b(?:git branch|branch)\s+([A-Za-z0-9._/-]+)"#, role: .git, captureGroup: 1),
            Rule(group: "git", pattern: #"\b[0-9a-f]{7,40}\b"#, role: .git)
        ],
        [
            Rule(group: "structure", pattern: #"(?m)^\s*[-=]{3,}\s*$"#, role: .muted),
            Rule(group: "structure", pattern: #"(?m)^\s*[A-Z][A-Z0-9_ -]{2,}\s*$"#, role: .muted)
        ]
    ]

    private static let networkDeviceRuleGroups: [[Rule]] = [
        [
            Rule(
                group: "network-device-error-line",
                pattern: #"(?m)^(?:\s*%\s*)?(?:Invalid input|Incomplete command|Ambiguous command|Error|Failed|Failure|Critical|Alarm)[^\r\n]*"#,
                role: .error,
                bold: true
            )
        ],
        [
            Rule(
                group: "network-device-status",
                pattern: #"\b(?:administratively\s+down|err-disabled|notconnect|disabled|inactive|down|failed|failure|critical|alarm|denied|timeout|unreachable)\b"#,
                role: .error,
                bold: true
            ),
            Rule(
                group: "network-device-status",
                pattern: #"\b(?:CRC errors?|input errors?|output errors?|input drops?|output drops?|discards?|collisions?|packet loss)\b"#,
                role: .error,
                bold: true
            ),
            Rule(
                group: "network-device-status",
                pattern: #"\b(?:warning|degraded|flapping|mismatch|half-duplex|blocking|listening|learning)\b"#,
                role: .warning,
                bold: true
            ),
            Rule(
                group: "network-device-status",
                pattern: #"(?<![\w-])(?:up|connected|active|enabled|established|forwarding|full|success|succeeded|passed)(?![\w-])"#,
                role: .success,
                bold: true
            )
        ],
        [
            Rule(
                group: "network-device-interface",
                pattern: #"(?<![A-Za-z0-9_.-])(?:HundredGigE|FortyGigabitEthernet|TwentyFiveGigE|TenGigabitEthernet|XGigabitEthernet|GigabitEthernet|FastEthernet|Port-channel|Vlan-interface|ManagementEthernet|Ethernet|Loopback|Eth-Trunk|Vlanif|Tunnel|Serial|MgmtEth|XGE|GE|Gi|Fa|Te|Eth|Po)\s*\d+(?:[/.:]\d+)*(?:\.\d+)?(?![A-Za-z0-9_])"#,
                role: .resource,
                bold: true
            )
        ],
        [
            Rule(
                group: "network-device-address",
                pattern: #"(?<![A-Fa-f0-9])(?:[A-Fa-f0-9]{4}\.){2}[A-Fa-f0-9]{4}(?![A-Fa-f0-9])"#,
                role: .address
            ),
            Rule(
                group: "network-device-address",
                pattern: #"(?<![A-Fa-f0-9])(?:[A-Fa-f0-9]{2}[:-]){5}[A-Fa-f0-9]{2}(?![A-Fa-f0-9])"#,
                role: .address
            ),
            Rule(
                group: "network-device-address",
                pattern: #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,3})?(?![\d.])"#,
                role: .address
            ),
            Rule(
                group: "network-device-address",
                pattern: #"(?<![A-Fa-f0-9:])(?:[A-Fa-f0-9]{1,4}:){3,}[A-Fa-f0-9]{0,4}(?:/\d{1,3})?(?![A-Fa-f0-9:])"#,
                role: .address
            )
        ],
        [
            Rule(
                group: "network-device-protocol",
                pattern: #"\b(?:BGP|OSPFv?3?|IS-IS|ISIS|RIPng|RIP|STP|RSTP|MSTP|LACP|LLDP|VRRP|HSRP|ARP|NDP|DHCP|DNS|NTP|SNMP|SSH|Telnet|VLAN|VXLAN|VRF|ACL|QoS)\b"#,
                role: .info,
                bold: true
            )
        ],
        [
            Rule(
                group: "network-device-config",
                pattern: #"(?m)^\s*(interface|router|vlan|vrf|ip\s+route|ipv6\s+route|access-list|acl|description|hostname|system-view|undo|no\s+shutdown|shutdown|switchport|port\s+link-type)\b"#,
                role: .command,
                captureGroup: 1,
                bold: true
            )
        ],
        [
            Rule(
                group: "network-device-header",
                pattern: #"(?m)^\s*(Interface|Port|IP-Address|Protocol|Status|State|Neighbor|Destination|Gateway|Metric|Prefix|Route|MAC Address|VLAN ID|Uptime)\b"#,
                role: .info,
                captureGroup: 1,
                bold: true
            )
        ]
    ]

    public static func highlight(
        _ text: String,
        level: TerminalHighlightLevelPreference,
        richHighlightingEnabled: Bool = true,
        theme: TerminalColorTheme = .portDeskDark,
        profile: TerminalSemanticHighlightProfile = .generalPurpose,
        highlightsIncompleteLines: Bool = true
    ) -> String {
        guard level != .off,
              text.isEmpty == false,
              text.utf8.count <= maximumHighlightedByteCount
        else {
            return text
        }
        let palette = TerminalHighlightPalette(theme: theme)
        let rules: [CompiledRule]
        switch profile {
        case .generalPurpose:
            rules = level == .commandLineEnhanced && richHighlightingEnabled ? compiledRules : compiledPromptRules
        case .networkDeviceConsole:
            guard level == .commandLineEnhanced, richHighlightingEnabled else {
                return text
            }
            rules = compiledNetworkDeviceRules
        }
        var result = ""
        result.reserveCapacity(text.count)
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byLines, .substringNotRequired]) { _, lineRange, enclosingRange, _ in
            let line = String(text[lineRange])
            let trailing = text[lineRange.upperBound..<enclosingRange.upperBound]
            let isCompletedNetworkDeviceLine = profile != .networkDeviceConsole || trailing.isEmpty == false
            if line.utf16.count > maximumHighlightedLineLength || isCompletedNetworkDeviceLine == false {
                result.append(line)
            } else {
                let lineRules = highlightsIncompleteLines == false && trailing.isEmpty
                    ? compiledIncompleteLineRules
                    : rules
                result.append(highlightLine(line, palette: palette, rules: lineRules))
            }
            result.append(contentsOf: trailing)
        }
        if result.isEmpty, text.isEmpty == false {
            if profile == .networkDeviceConsole {
                return text
            }
            return text.utf16.count > maximumHighlightedLineLength ? text : highlightLine(text, palette: palette, rules: rules)
        }
        return result
    }

    public static func highlight(
        _ bytes: [UInt8],
        level: TerminalHighlightLevelPreference,
        richHighlightingEnabled: Bool = true,
        theme: TerminalColorTheme = .portDeskDark,
        profile: TerminalSemanticHighlightProfile = .generalPurpose,
        highlightsIncompleteLines: Bool = true
    ) -> [UInt8] {
        guard level != .off,
              let text = String(bytes: bytes, encoding: .utf8)
        else {
            return bytes
        }
        let highlighted = highlight(
            text,
            level: level,
            richHighlightingEnabled: richHighlightingEnabled,
            theme: theme,
            profile: profile,
            highlightsIncompleteLines: highlightsIncompleteLines
        )
        return highlighted == text ? bytes : Array(highlighted.utf8)
    }

    static func prepare() {
        _ = compiledRules.count
        _ = compiledNetworkDeviceRules.count
    }

    public static func strippingStacioDisplayMarkup(from text: String) -> String {
        let nsText = text as NSString
        let fullLength = nsText.length
        guard fullLength > 0 else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var index = 0
        var isInsideStacioMarkup = false

        while index < fullLength {
            let char = nsText.character(at: index)
            if let marker = portDeskMarkupMarker(in: nsText, at: index) {
                isInsideStacioMarkup = marker.payload == portDeskMarkupStartPayload
                index = max(index + 1, marker.end)
                continue
            }
            if char == 0x1B,
               index + 1 < fullLength,
               nsText.character(at: index + 1) == 0x5B {
                let end = scanCSIEnd(in: nsText, from: index + 2)
                let sequence = nsText.substring(with: NSRange(location: index, length: max(0, end - index)))
                if isInsideStacioMarkup, isSGRSequence(sequence) {
                    index = max(index + 1, end)
                    continue
                }
            }

            result.append(nsText.substring(with: NSRange(location: index, length: 1)))
            index += 1
        }

        return result
    }

    public static func strippingStacioDisplayMarkup(from bytes: [UInt8]) -> [UInt8] {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            return bytes
        }
        let stripped = strippingStacioDisplayMarkup(from: text)
        return stripped == text ? bytes : Array(stripped.utf8)
    }

    private static func highlightLine(
        _ line: String,
        palette: TerminalHighlightPalette,
        rules: [CompiledRule]
    ) -> String {
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        guard fullRange.length > 0 else {
            return line
        }
        let protectedRanges = ansiProtectedRanges(in: line)
        var occupied = protectedRanges
        var replacedRanges: [NSRange] = []
        var replacements: [(range: NSRange, value: String)] = []

        for compiledRule in rules {
            let matches = matches(for: compiledRule, in: line, fullRange: fullRange)
            for range in matches {
                let isPromptRule = compiledRule.rule.group == "prompt"
                guard range.location != NSNotFound,
                      range.length > 0,
                      intersects(range, replacedRanges) == false,
                      (isPromptRule || intersects(range, occupied) == false),
                      let stringRange = Range(range, in: line)
                else {
                    continue
                }
                let token = String(line[stringRange])
                guard isPromptRule || token.contains("\u{001B}") == false else {
                    continue
                }
                let code = palette.sgrCode(
                    for: compiledRule.rule.role,
                    bold: compiledRule.rule.bold,
                    underline: compiledRule.rule.underline,
                    includeBackground: compiledRule.rule.background
                )
                let replacement = isPromptRule
                    ? sgrPreservingControlSequences(code, token)
                    : sgr(code, token)
                replacements.append((range, replacement))
                occupied.append(range)
                replacedRanges.append(range)
            }
        }

        guard replacements.isEmpty == false else {
            return line
        }
        var result = line
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            guard let stringRange = Range(replacement.range, in: result) else {
                continue
            }
            result.replaceSubrange(stringRange, with: replacement.value)
        }
        return result
    }

    private static func matches(
        for compiledRule: CompiledRule,
        in line: String,
        fullRange: NSRange
    ) -> [NSRange] {
        if compiledRule.rule.group == "prompt" {
            return promptMatches(for: compiledRule, in: line, fullRange: fullRange)
        }
        return compiledRule.regex.matches(in: line, range: fullRange).compactMap { match in
            let group = min(compiledRule.rule.captureGroup, match.numberOfRanges - 1)
            let range = match.range(at: group)
            guard range.location != NSNotFound, range.length > 0 else {
                return nil
            }
            return range
        }
    }

    private static func promptMatches(
        for compiledRule: CompiledRule,
        in line: String,
        fullRange: NSRange
    ) -> [NSRange] {
        let nsLine = line as NSString
        let promptStart = leadingPromptSearchOffset(in: nsLine, range: fullRange)
        guard promptStart < fullRange.location + fullRange.length else {
            return []
        }
        let candidateRange = NSRange(
            location: promptStart,
            length: fullRange.location + fullRange.length - promptStart
        )
        let projection = visiblePromptProjection(in: nsLine, range: candidateRange)
        let candidate = projection.text
        let candidateLength = (candidate as NSString).length
        guard candidateLength > 0 else {
            return []
        }

        return compiledRule.regex.matches(
            in: candidate,
            range: NSRange(location: 0, length: candidateLength)
        ).compactMap { match in
            let group = min(compiledRule.rule.captureGroup, match.numberOfRanges - 1)
            let range = match.range(at: group)
            guard range.location != NSNotFound, range.length > 0 else {
                return nil
            }
            return projection.sourceRange(for: range)
        }
    }

    private static func visiblePromptProjection(in text: NSString, range: NSRange) -> VisiblePromptProjection {
        let upperBound = min(text.length, range.location + range.length)
        var index = range.location
        var visible = ""
        var sourceOffsets: [Int] = []

        while index < upperBound {
            let char = text.character(at: index)
            if char == 0x1B,
               index + 1 < upperBound {
                let next = text.character(at: index + 1)
                if next == 0x5B {
                    index = min(scanCSIEnd(in: text, from: index + 2), upperBound)
                    continue
                }
                if next == 0x5D {
                    index = min(scanOSCEnd(in: text, from: index + 2), upperBound)
                    continue
                }
            }

            visible.append(text.substring(with: NSRange(location: index, length: 1)))
            sourceOffsets.append(index)
            index += 1
        }

        return VisiblePromptProjection(text: visible, sourceOffsets: sourceOffsets)
    }

    private static func leadingPromptSearchOffset(in text: NSString, range: NSRange) -> Int {
        let upperBound = min(text.length, range.location + range.length)
        var index = range.location
        while index < upperBound {
            let char = text.character(at: index)
            if char == 0x0D {
                index += 1
                continue
            }
            guard char == 0x1B, index + 1 < upperBound else {
                break
            }
            let next = text.character(at: index + 1)
            if next == 0x5B {
                let end = scanCSIEnd(in: text, from: index + 2)
                guard end > index + 2 else { break }
                index = min(end, upperBound)
                continue
            }
            if next == 0x5D {
                let end = scanOSCEnd(in: text, from: index + 2)
                guard end > index + 2 else { break }
                index = min(end, upperBound)
                continue
            }
            break
        }
        return index
    }

    private static func intersects(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private static func sgr(_ code: String, _ value: String) -> String {
        "\(portDeskMarkupStart)\u{001B}[\(code)m\(value)\u{001B}[0m\(portDeskMarkupEnd)"
    }

    private static func sgrPreservingControlSequences(_ code: String, _ value: String) -> String {
        let nsValue = value as NSString
        let fullLength = nsValue.length
        guard fullLength > 0 else {
            return value
        }

        var result = ""
        var visibleRun = ""
        func flushVisibleRun() {
            guard visibleRun.isEmpty == false else { return }
            result.append(sgr(code, visibleRun))
            visibleRun.removeAll(keepingCapacity: true)
        }

        var index = 0
        while index < fullLength {
            let char = nsValue.character(at: index)
            if char == 0x1B,
               index + 1 < fullLength,
               nsValue.character(at: index + 1) == 0x5B {
                flushVisibleRun()
                let end = scanCSIEnd(in: nsValue, from: index + 2)
                let sequence = nsValue.substring(with: NSRange(location: index, length: max(1, end - index)))
                result.append(sequence)
                index = max(index + 1, end)
                continue
            }
            if char == 0x1B,
               index + 1 < fullLength,
               nsValue.character(at: index + 1) == 0x5D {
                flushVisibleRun()
                let end = scanOSCEnd(in: nsValue, from: index + 2)
                result.append(nsValue.substring(with: NSRange(location: index, length: max(1, end - index))))
                index = max(index + 1, end)
                continue
            }

            visibleRun.append(nsValue.substring(with: NSRange(location: index, length: 1)))
            index += 1
        }
        flushVisibleRun()
        return result
    }

    private static var portDeskMarkupStart: String {
        "\u{001B}]\(portDeskMarkupStartPayload)\u{0007}"
    }

    private static var portDeskMarkupEnd: String {
        "\u{001B}]\(portDeskMarkupEndPayload)\u{0007}"
    }

    private static func isSGRSequence(_ sequence: String) -> Bool {
        sequence.hasPrefix("\u{001B}[") && sequence.hasSuffix("m")
    }

    private static func portDeskMarkupMarker(in text: NSString, at index: Int) -> (payload: String, end: Int)? {
        guard index + 1 < text.length,
              text.character(at: index) == 0x1B,
              text.character(at: index + 1) == 0x5D
        else {
            return nil
        }
        let end = scanOSCEnd(in: text, from: index + 2)
        guard end > index + 2 else {
            return nil
        }
        let terminatorLength: Int
        if text.character(at: end - 1) == 0x07 {
            terminatorLength = 1
        } else if end >= 2,
                  text.character(at: end - 2) == 0x1B,
                  text.character(at: end - 1) == 0x5C {
            terminatorLength = 2
        } else {
            return nil
        }
        let payloadLength = end - index - 2 - terminatorLength
        guard payloadLength > 0 else {
            return nil
        }
        let payload = text.substring(with: NSRange(location: index + 2, length: payloadLength))
        guard payload == portDeskMarkupStartPayload || payload == portDeskMarkupEndPayload else {
            return nil
        }
        return (payload, end)
    }

    private static func ansiProtectedRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        let fullLength = nsText.length
        guard fullLength > 0 else { return [] }

        var ranges: [NSRange] = []
        var index = 0
        var activeSGRStart: Int?
        while index < fullLength {
            let char = nsText.character(at: index)
            guard char == 0x1B else {
                index += 1
                continue
            }
            if index + 1 < fullLength,
               nsText.character(at: index + 1) == 0x5B {
                let end = scanCSIEnd(in: nsText, from: index + 2)
                let escapeRange = NSRange(location: index, length: max(1, end - index))
                ranges.append(escapeRange)
                let code = nsText.substring(with: NSRange(location: index, length: max(0, end - index)))
                if code.contains("[0m") {
                    if let start = activeSGRStart, end > start {
                        ranges.append(NSRange(location: start, length: end - start))
                    }
                    activeSGRStart = nil
                } else if code.hasSuffix("m") {
                    activeSGRStart = activeSGRStart ?? index
                }
                index = max(index + 1, end)
                continue
            }
            if index + 1 < fullLength,
               nsText.character(at: index + 1) == 0x5D {
                let end = scanOSCEnd(in: nsText, from: index + 2)
                ranges.append(NSRange(location: index, length: max(1, end - index)))
                index = max(index + 1, end)
                continue
            }
            index += 1
        }
        if let start = activeSGRStart, fullLength > start {
            ranges.append(NSRange(location: start, length: fullLength - start))
        }
        return ranges
    }

    private static func scanCSIEnd(in text: NSString, from start: Int) -> Int {
        var index = start
        while index < text.length {
            let value = text.character(at: index)
            if value >= 0x40 && value <= 0x7E {
                return index + 1
            }
            index += 1
        }
        return text.length
    }

    private static func scanOSCEnd(in text: NSString, from start: Int) -> Int {
        var index = start
        while index < text.length {
            let value = text.character(at: index)
            if value == 0x07 {
                return index + 1
            }
            if value == 0x1B,
               index + 1 < text.length,
               text.character(at: index + 1) == 0x5C {
                return index + 2
            }
            index += 1
        }
        return text.length
    }
}

struct TerminalSemanticHighlightConfiguration {
    let level: TerminalHighlightLevelPreference
    let richHighlightingEnabled: Bool
    let theme: TerminalColorTheme
    let profile: TerminalSemanticHighlightProfile
    let highlightsIncompleteLines: Bool

    init(
        level: TerminalHighlightLevelPreference,
        richHighlightingEnabled: Bool,
        theme: TerminalColorTheme,
        profile: TerminalSemanticHighlightProfile = .generalPurpose,
        highlightsIncompleteLines: Bool = true
    ) {
        self.level = level
        self.richHighlightingEnabled = richHighlightingEnabled
        self.theme = theme
        self.profile = profile
        self.highlightsIncompleteLines = highlightsIncompleteLines
    }

    func apply(to bytes: [UInt8]) -> [UInt8] {
        TerminalSemanticOutputHighlighter.highlight(
            bytes,
            level: level,
            richHighlightingEnabled: richHighlightingEnabled,
            theme: theme,
            profile: profile,
            highlightsIncompleteLines: highlightsIncompleteLines
        )
    }
}

final class TerminalSemanticOutputProcessor {
    typealias Delivery = ([UInt8]) -> Void

    private struct Request {
        let bytes: [UInt8]
        var configuration: TerminalSemanticHighlightConfiguration?
        let generation: UInt64
        let delivery: Delivery
    }

    private static let asynchronousByteThreshold = 512
    private static let maximumHighlightedOutstandingByteCount = 512 * 1_024

    private let workerQueue: DispatchQueue
    private let stateLock = NSLock()
    private var pendingRequests: [Request] = []
    private var pendingRequestIndex = 0
    private var workerIsRunning = false
    private var synchronousRequestIsRunning = false
    private var generation: UInt64 = 0
    private var outstandingByteCount = 0
    private var bypassHighlightingUntilDrained = false
    private var pendingMainDeliveryBatchCount = 0

    init(label: String) {
        workerQueue = DispatchQueue(label: label, qos: .userInitiated)
        TerminalSemanticOutputHighlighter.prepare()
    }

    func process(
        bytes: [UInt8],
        configuration: TerminalSemanticHighlightConfiguration?,
        delivery: @escaping Delivery
    ) {
        guard bytes.isEmpty == false else {
            deliverOnMain(bytes, delivery: delivery)
            return
        }

        if Thread.isMainThread,
           bytes.count < Self.asynchronousByteThreshold,
           let reservedGeneration = reserveSynchronousRequest(byteCount: bytes.count) {
            let displayBytes = configuration?.apply(to: bytes) ?? bytes
            if isCurrentGeneration(reservedGeneration) {
                delivery(displayBytes)
            }
            finishSynchronousRequest(byteCount: bytes.count, generation: reservedGeneration)
            return
        }

        enqueue(bytes: bytes, configuration: configuration, delivery: delivery)
    }

    func cancel() {
        stateLock.lock()
        generation &+= 1
        pendingRequests.removeAll(keepingCapacity: false)
        pendingRequestIndex = 0
        outstandingByteCount = 0
        bypassHighlightingUntilDrained = false
        stateLock.unlock()
    }

    private func reserveSynchronousRequest(byteCount: Int) -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard workerIsRunning == false,
              synchronousRequestIsRunning == false,
              pendingMainDeliveryBatchCount == 0,
              pendingRequestIndex >= pendingRequests.count
        else {
            return nil
        }
        synchronousRequestIsRunning = true
        outstandingByteCount += byteCount
        return generation
    }

    private func finishSynchronousRequest(byteCount: Int, generation requestGeneration: UInt64) {
        var shouldStartWorker = false
        stateLock.lock()
        synchronousRequestIsRunning = false
        if requestGeneration == generation {
            outstandingByteCount = max(0, outstandingByteCount - byteCount)
        }
        if pendingRequestIndex < pendingRequests.count, workerIsRunning == false {
            workerIsRunning = true
            shouldStartWorker = true
        } else if outstandingByteCount == 0 {
            bypassHighlightingUntilDrained = false
        }
        stateLock.unlock()
        if shouldStartWorker {
            scheduleWorker()
        }
    }

    private func enqueue(
        bytes: [UInt8],
        configuration: TerminalSemanticHighlightConfiguration?,
        delivery: @escaping Delivery
    ) {
        var shouldStartWorker = false
        stateLock.lock()
        let nextOutstandingByteCount = outstandingByteCount + bytes.count
        if nextOutstandingByteCount > Self.maximumHighlightedOutstandingByteCount {
            bypassHighlightingUntilDrained = true
            if pendingRequestIndex < pendingRequests.count {
                for index in pendingRequestIndex..<pendingRequests.count {
                    pendingRequests[index].configuration = nil
                }
            }
        }
        pendingRequests.append(Request(
            bytes: bytes,
            configuration: bypassHighlightingUntilDrained ? nil : configuration,
            generation: generation,
            delivery: delivery
        ))
        outstandingByteCount = nextOutstandingByteCount
        if workerIsRunning == false, synchronousRequestIsRunning == false {
            workerIsRunning = true
            shouldStartWorker = true
        }
        stateLock.unlock()
        if shouldStartWorker {
            scheduleWorker()
        }
    }

    private func scheduleWorker() {
        workerQueue.async { [weak self] in
            self?.drainPendingRequests()
        }
    }

    private func drainPendingRequests() {
        var deliveries: [(generation: UInt64, bytes: [UInt8], delivery: Delivery)] = []
        var didReserveMainDeliveryBatch = false

        while let request = takeNextRequest() {
            guard isCurrentGeneration(request.generation) else {
                finish(request)
                continue
            }
            if didReserveMainDeliveryBatch == false {
                reserveMainDeliveryBatch()
                didReserveMainDeliveryBatch = true
            }
            let displayBytes = request.configuration?.apply(to: request.bytes) ?? request.bytes
            deliveries.append((request.generation, displayBytes, request.delivery))
            finish(request)
        }

        guard deliveries.isEmpty == false else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.finishMainDeliveryBatch() }
            for item in deliveries {
                guard self.isCurrentGeneration(item.generation) else { continue }
                item.delivery(item.bytes)
            }
        }
    }

    private func reserveMainDeliveryBatch() {
        stateLock.lock()
        pendingMainDeliveryBatchCount += 1
        stateLock.unlock()
    }

    private func finishMainDeliveryBatch() {
        stateLock.lock()
        pendingMainDeliveryBatchCount = max(0, pendingMainDeliveryBatchCount - 1)
        stateLock.unlock()
    }

    private func takeNextRequest() -> Request? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard pendingRequestIndex < pendingRequests.count else {
            pendingRequests.removeAll(keepingCapacity: true)
            pendingRequestIndex = 0
            workerIsRunning = false
            if outstandingByteCount == 0 {
                bypassHighlightingUntilDrained = false
            }
            return nil
        }
        let request = pendingRequests[pendingRequestIndex]
        pendingRequestIndex += 1
        if pendingRequestIndex >= 64,
           pendingRequestIndex * 2 >= pendingRequests.count {
            pendingRequests.removeFirst(pendingRequestIndex)
            pendingRequestIndex = 0
        }
        return request
    }

    private func finish(_ request: Request) {
        stateLock.lock()
        if request.generation == generation {
            outstandingByteCount = max(0, outstandingByteCount - request.bytes.count)
        }
        stateLock.unlock()
    }

    private func isCurrentGeneration(_ requestGeneration: UInt64) -> Bool {
        stateLock.lock()
        let isCurrent = requestGeneration == generation
        stateLock.unlock()
        return isCurrent
    }

    private func deliverOnMain(_ bytes: [UInt8], delivery: @escaping Delivery) {
        if Thread.isMainThread {
            delivery(bytes)
        } else {
            DispatchQueue.main.async {
                delivery(bytes)
            }
        }
    }
}
