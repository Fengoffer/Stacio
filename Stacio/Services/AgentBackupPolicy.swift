import Foundation
import StacioAgentBridge

public struct AgentVerifiedBackup: Equatable {
    public let path: String
    public let command: String
}

public enum AgentBackupPolicy {
    public static func isDeploymentCommand(command: String) -> Bool {
        let value = normalized(command)
        let deploymentPatterns = [
            #"\bdocker(?:\s+compose)?\s+up\b"#,
            #"\bdocker\s+run\b"#,
            #"\bkubectl\s+apply\b"#,
            #"\bhelm\s+install\b"#
        ]
        return deploymentPatterns.contains(where: { matches($0, in: value) })
    }

    public static func requiresBackup(command: String) -> Bool {
        let value = normalized(command)
        guard value.isEmpty == false, isBackupCommand(command: value) == false else { return false }

        if mutationPatterns.contains(where: { matches($0, in: value) }) {
            return true
        }

        let writesContent = matches(#"(^|[;&|]\s*)(sudo\s+)?(sed\s+-[^\n;]*i|perl\s+-[^\n;]*pi|tee\b|install\b|cp\b|mv\b|chmod\b|chown\b|setfacl\b|touch\b|ln\b)"#, in: value)
            || matches(#"(^|[^>])>{1,2}\s*[^&]"#, in: value)
            || matches(#"\b(python3?|ruby|node|php)\b.*(?:open\s*\(|write(?:_text|file)?\s*\(|fs\.write)"#, in: value)
            || matches(#"(^|[;&|]\s*)(sudo\s+)?(?:rm|unlink|truncate)\b[^;&|]*(?:/etc/|/usr/local/etc/)"#, in: value)
            || matches(#"\b(?:curl|wget)\b[^;&|]*(?:-o|--output|-O|--output-document)(?:=|\s+)[^;&|]*(?:/etc/|/usr/local/etc/)"#, in: value)
            || matches(#"\bdd\b[^;&|]*\bof=(?:/etc/|/usr/local/etc/)"#, in: value)
        let configurationTarget = matches(#"/(etc|usr/local/etc)/|\.(conf|config|ini|yaml|yml|toml|json|properties|env)(?:\s|$)"#, in: value)
        return writesContent && configurationTarget
    }

    private static let mutationPatterns = [
        #"\bsystemctl\s+(restart|reload|enable|disable|start|stop)\b"#,
        #"\bservice\s+\S+\s+(restart|reload|start|stop)\b"#,
        #"\bdocker(?:\s+compose)?\s+(up|down|restart|run|rm|stop|start|pull)\b"#,
        #"\bkubectl\s+(apply|delete|patch|replace|edit|scale|set)\b"#,
        #"\bkubectl\s+rollout\s+(restart|undo)\b"#,
        #"\bhelm\s+(install|upgrade|rollback|uninstall)\b"#,
        #"\b(apt|apt-get|dnf|yum|zypper|pacman|brew)\s+(install|upgrade|remove|update)\b"#,
        #"\b(psql|mysql|mariadb|mongosh?)\b.*(?:\s-f\s+|<\s*)\S+"#,
        #"\b(flyway|liquibase|alembic|prisma|rails|django-admin)\b.*\b(migrate|upgrade|deploy)\b"#,
        #"\b(rsync|scp)\b.*(?:/srv/|/opt/|/var/www/|/usr/local/)"#
    ]

    public static func latestVerifiedBackup(in steps: [AgentTaskStepResult]) -> AgentVerifiedBackup? {
        for step in steps.reversed()
        where step.state == .completed
            && isBackupCommand(command: step.command)
            && AgentRollbackPolicy.isRollbackCommand(step.command) == false {
            if let path = backupPath(from: step.observation) {
                return AgentVerifiedBackup(path: path, command: step.command)
            }
        }
        return nil
    }

    public static func verifiedBackupForNextMutation(in steps: [AgentTaskStepResult]) -> AgentVerifiedBackup? {
        let lastMutationIndex = steps.lastIndex(where: {
            $0.state == .completed && requiresBackup(command: $0.command)
        })
        let eligibleSteps: ArraySlice<AgentTaskStepResult>
        if let lastMutationIndex {
            eligibleSteps = steps.suffix(from: steps.index(after: lastMutationIndex))
        } else {
            eligibleSteps = steps[...]
        }
        return latestVerifiedBackup(in: Array(eligibleSteps))
    }

    public static func isBackupCommand(command: String) -> Bool {
        let value = normalized(command)
        let nativeDump = matches(#"\b(pg_dump|pg_basebackup|mysqldump|mariadb-dump|mongodump)\b"#, in: value)
        let archive = matches(#"\b(tar|zip)\b"#, in: value) && backupDestinationHint(in: value)
        let copy = matches(#"\b(cp|rsync)\b"#, in: value) && backupDestinationHint(in: value)
        return nativeDump || archive || copy
    }

    /// Returns the last absolute path found in a backup command/output.
    ///
    /// The coordinator uses this as a lightweight, in-memory proof that a
    /// configuration-changing command was preceded by a completed backup.
    public static func backupPath(from text: String) -> String? {
        pathCandidates(in: text).last(where: isRecognizedBackupPath)
    }

    /// A path is useful as backup evidence only when it has an unambiguous
    /// backup location/name. Arbitrary absolute paths (for example
    /// `/etc/passwd`) must not be accepted as proof of a backup.
    private static func isRecognizedBackupPath(_ path: String) -> Bool {
        let value = path.lowercased()
        if ["/var/backups/", "/var/backup/", "/backup/", "/backups/"]
            .contains(where: value.hasPrefix) {
            return true
        }

        let filename = value.split(separator: "/").last.map(String.init) ?? value
        let hasBackupName = filename.range(
            of: #"(^|[._-])(backup|backups|snapshot|dump)([._-]|$)"#,
            options: .regularExpression
        ) != nil
        let backupExtensions = [
            ".bak", ".backup", ".dump", ".sql", ".archive", ".tar", ".tgz", ".tar.gz", ".zip"
        ]
        return hasBackupName || backupExtensions.contains(where: filename.hasSuffix)
    }

    /// Check the destination operands of copy/archive commands rather than
    /// looking for the word "backup" anywhere in the command. This avoids
    /// treating `cp /etc/backup.conf /etc/nginx/...` as a verified backup.
    private static func backupDestinationHint(in value: String) -> Bool {
        // Keep shell command segments independent so a backup-looking path in
        // a later `&&` command cannot make an unrelated `cp` look safe.
        let segments = value.components(separatedBy: CharacterSet(charactersIn: ";&|"))
        for segment in segments {
            let tokens = segment
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)

            for (index, token) in tokens.enumerated()
            where token == "cp" || token == "rsync" || token == "tar" || token == "zip" {
                let operandStart = tokens.index(after: index)
                let operands = operandStart < tokens.endIndex
                    ? tokens[operandStart...].filter { !$0.hasPrefix("-") }
                    : []
                // zip takes the archive as its first operand; copy commands
                // take the destination as their last operand.
                let destination = token == "zip" ? operands.first : operands.last
                if let destination, isRecognizedBackupPath(destination) {
                    return true
                }
                // Relative destinations are common in scripts and do not pass
                // pathCandidates' absolute-path filter, so inspect their name.
                if let destination, destination.range(
                    of: #"(^|[._/-])(backup|backups|snapshot|dump)([._/-]|$)"#,
                    options: .regularExpression
                ) != nil {
                    return true
                }
            }

            // `tar -f <archive> <source>` places the destination next to -f,
            // not at the end of the command. Inspect both standalone and
            // combined short options such as `tar -czf archive.tar.gz`.
            for index in tokens.indices {
                let option = tokens[index]
                if option.hasPrefix("--file=") {
                    let archiveToken = String(option.dropFirst("--file=".count))
                    if isRecognizedBackupPath(archiveToken) {
                        return true
                    }
                    continue
                }
                guard option == "-f" || (option.hasPrefix("-") && option.dropFirst().contains("f")) else {
                    continue
                }
                let archiveToken: String?
                if option == "-f" || option.last == "f" {
                    archiveToken = tokens.indices.contains(index + 1) ? tokens[index + 1] : nil
                } else if let flagIndex = option.firstIndex(of: "f") {
                    archiveToken = String(option[option.index(after: flagIndex)...])
                } else {
                    archiveToken = nil
                }
                if let archiveToken, isRecognizedBackupPath(archiveToken) {
                    return true
                }
            }

            if tokens.contains(where: { $0.hasPrefix("--backup-dir=") }),
               let backupDirectory = tokens.first(where: { $0.hasPrefix("--backup-dir=") })
                    .map({ String($0.dropFirst("--backup-dir=".count)) }),
               isRecognizedBackupPath(backupDirectory) {
                return true
            }
        }
        return false
    }

    private static func pathCandidates(in text: String) -> [String] {
        // Backup tools commonly prefix the destination with punctuation in
        // human-readable output (for example, "备份完成：/var/backups/..."),
        // so treat ASCII and full-width separators as valid path boundaries.
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[\s='\"：:,，、])(/[^\s'\";|：:,，、]+)"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let pathRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[pathRange])
        }
    }

    private static func normalized(_ command: String) -> String {
        command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Runtime-scoped, single-use proof that a completed backup was observed.
///
/// This is deliberately in-memory and keyed by both runtime ID and connection
/// generation. A reconnect or process restart therefore requires a fresh,
/// observable backup; command text alone can never satisfy the gate.
@MainActor
public final class AgentBackupLedger {
    private struct Record {
        let connectionGeneration: UInt64
        let backup: AgentVerifiedBackup
    }

    private var recordsByRuntimeID: [String: Record] = [:]

    public init() {}

    public func allows(
        command: String,
        runtimeID: String,
        generation: UInt64
    ) -> Bool {
        guard AgentBackupPolicy.requiresBackup(command: command),
              AgentBackupPolicy.isDeploymentCommand(command: command) == false,
              AgentRollbackPolicy.isRollbackCommand(command) == false
        else {
            return true
        }
        guard let record = recordsByRuntimeID[runtimeID],
              record.connectionGeneration == generation
        else {
            return false
        }
        // Consume the proof at admission time. The coordinator can execute
        // more than one background request concurrently; waiting until the
        // command finishes would let two mutations reuse one backup.
        recordsByRuntimeID.removeValue(forKey: runtimeID)
        return true
    }

    public func record(
        command: String,
        runtimeID: String,
        generation: UInt64,
        events: [AgentTraceEvent]
    ) {
        if AgentBackupPolicy.isBackupCommand(command: command) {
            // A backup is valid only after the terminal reported audited
            // completion; approval/running events alone are not evidence that
            // the copy actually succeeded.
            guard events.contains(where: {
                $0.state == .completed
                    && $0.metadata?["terminalOutputAudited"] == "true"
            }) else { return }
            let output = events
                .compactMap { $0.metadata?["terminalOutputSummary"] }
                .joined(separator: "\n")
            // Only terminal output is accepted as proof. The command itself
            // is not evidence that the copy/archive actually succeeded.
            guard let path = AgentBackupPolicy.backupPath(from: output) else { return }
            recordsByRuntimeID[runtimeID] = Record(
                connectionGeneration: generation,
                backup: AgentVerifiedBackup(path: path, command: command)
            )
            return
        }

        // A proof is single-use for configuration-changing commands.
        // Consume it as soon as execution is admitted. If the runtime later
        // fails or is cancelled, retaining the proof could incorrectly allow
        // a subsequent mutation without a fresh backup.
        let reachedExecution = events.contains {
            switch $0.state {
            case .approved, .typing, .running, .waitingForOutput, .completed:
                return true
            default:
                return false
            }
        }
        if reachedExecution, AgentBackupPolicy.requiresBackup(command: command) {
            recordsByRuntimeID.removeValue(forKey: runtimeID)
        }
    }

    public func invalidate(runtimeID: String) {
        recordsByRuntimeID.removeValue(forKey: runtimeID)
    }
}
