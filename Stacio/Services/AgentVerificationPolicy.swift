import Foundation

public enum AgentVerificationPolicy {
    public static func isVerificationCommand(_ command: String) -> Bool {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.isEmpty == false, AgentBackupPolicy.requiresBackup(command: value) == false else { return false }

        let patterns = [
            #"\bsystemctl\s+(status|is-active|is-enabled|show)\b"#,
            #"\bservice\s+\S+\s+status\b"#,
            #"\b(nginx|apachectl|httpd|haproxy|named-checkconf)\b.*(?:-t\b|\bconfigtest\b|\bcheck\b)"#,
            #"\bdocker(?:\s+compose)?\s+(ps|inspect|logs)\b"#,
            #"\bkubectl\s+(get|describe|logs|wait)\b"#,
            #"\bkubectl\s+rollout\s+status\b"#,
            #"\bhelm\s+(status|test|get)\b"#,
            #"\b(curl|wget)\b.*(?:health|ready|live|status|localhost|127\.0\.0\.1)"#,
            #"\b(ss|netstat|lsof)\b.*(?:-l|listen)"#,
            #"\b(psql|mysql|mariadb|mongosh?|redis-cli)\b.*\b(select|ping|status|db\.runcommand)\b"#,
            #"\b(test|stat|sha256sum|shasum|diff|cmp)\b\s+"#
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }

    public static func requiresVerification(in steps: [AgentTaskStepResult]) -> Bool {
        guard let mutationIndex = steps.lastIndex(where: {
            $0.state == .completed && AgentBackupPolicy.requiresBackup(command: $0.command)
        }) else {
            return false
        }
        let laterSteps = steps.suffix(from: steps.index(after: mutationIndex))
        return laterSteps.contains(where: {
            $0.state == .completed && isVerificationCommand($0.command)
        }) == false
    }
}

public enum AgentFinalReportPolicy {
    public static func isCompliant(message: String, steps: [AgentTaskStepResult]) -> Bool {
        let hasMutation = steps.contains {
            $0.state == .completed && AgentBackupPolicy.requiresBackup(command: $0.command)
        }
        guard hasMutation else { return true }
        guard let backup = AgentBackupPolicy.latestVerifiedBackup(in: steps) else { return false }
        let baseCompliant = message.contains("备份与回滚")
            && message.contains(backup.path)
            && message.contains("验证")
            && message.contains("回滚")
        let performedRollback = steps.contains {
            $0.state == .completed && AgentRollbackPolicy.isRollbackCommand($0.command)
        }
        return baseCompliant && (performedRollback == false || message.contains("回滚结果"))
    }
}

public enum AgentRollbackPolicy {
    public static func isRollbackCommand(_ command: String) -> Bool {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let patterns = [
            #"\bcp\b\s+(?:-[^\s]+\s+)*(?:['\"])?/[^\s'\"]*backup[^\s'\"]*(?:['\"])?\s+"#,
            #"\brsync\b\s+(?:-[^\s]+\s+)*(?:['\"])?/[^\s'\"]*backup[^\s'\"]*(?:['\"])?\s+"#,
            #"\bhelm\s+rollback\b"#,
            #"\bkubectl\s+rollout\s+undo\b"#,
            #"\b(pg_restore|mysql|mariadb|mongorestore)\b.*(?:backup|\.sql|\.dump|\.archive)"#,
            #"\b(dnf|yum|apt|apt-get|brew)\b.*\b(downgrade|reinstall)\b"#
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}
