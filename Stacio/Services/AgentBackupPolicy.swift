import Foundation

public struct AgentVerifiedBackup: Equatable {
    public let path: String
    public let command: String
}

public enum AgentBackupPolicy {
    public static func requiresBackup(command: String) -> Bool {
        let value = normalized(command)
        guard value.isEmpty == false, isBackupCommand(command: value) == false else { return false }

        let deploymentPatterns = [
            #"\bsystemctl\s+(restart|reload|enable|disable|start|stop)\b"#,
            #"\b(service)\s+\S+\s+(restart|reload|start|stop)\b"#,
            #"\bdocker(?:\s+compose)?\s+(up|down|restart|run|rm|stop|start|pull)\b"#,
            #"\bkubectl\s+(apply|delete|patch|replace|edit|scale|set)\b"#,
            #"\bkubectl\s+rollout\s+(restart|undo)\b"#,
            #"\bhelm\s+(install|upgrade|rollback|uninstall)\b"#,
            #"\b(apt|apt-get|dnf|yum|zypper|pacman|brew)\s+(install|upgrade|remove|update)\b"#,
            #"\b(psql|mysql|mariadb|mongosh?)\b.*(?:\s-f\s+|<\s*)\S+"#,
            #"\b(flyway|liquibase|alembic|prisma|rails|django-admin)\b.*\b(migrate|upgrade|deploy)\b"#,
            #"\b(rsync|scp)\b.*(?:/srv/|/opt/|/var/www/|/usr/local/)"#
        ]
        if deploymentPatterns.contains(where: { matches($0, in: value) }) {
            return true
        }

        let writesContent = matches(#"(^|[;&|]\s*)(sudo\s+)?(sed\s+-[^\n;]*i|perl\s+-[^\n;]*pi|tee\b|install\b|cp\b|mv\b)"#, in: value)
            || matches(#"(^|[^>])>{1,2}\s*[^&]"#, in: value)
        let configurationTarget = matches(#"/(etc|usr/local/etc)/|\.(conf|config|ini|yaml|yml|toml|json|properties|env)(?:\s|$)"#, in: value)
        return writesContent && configurationTarget
    }

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
        let archive = matches(#"\b(tar|zip)\b"#, in: value) && value.contains("backup")
        let copy = matches(#"\b(cp|rsync)\b"#, in: value) && value.contains("backup")
        return nativeDump || archive || copy
    }

    private static func backupPath(from text: String) -> String? {
        pathCandidates(in: text).last
    }

    private static func pathCandidates(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[\s='\"])(/[^\s'\";|]+)"#) else { return [] }
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
