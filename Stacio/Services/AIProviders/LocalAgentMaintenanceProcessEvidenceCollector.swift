import Darwin
import Foundation

public enum LocalAgentMaintenanceEvidenceError: Error, Equatable {
    case invalidJournalIdentity(String)
    case observationUnavailable(String)
}

public protocol LocalAgentMaintenanceEvidenceCollecting: AnyObject {
    func collectEvidence(
        for entry: LocalAgentMaintenanceProcessJournalEntry
    ) throws -> LocalAgentMaintenanceReconciliationEvidence
}

struct LocalAgentObservedProcessIdentity: Equatable {
    let processIdentifier: Int32
    let processGroupIdentifier: Int32
    let trustedStartTime: Date
}

enum LocalAgentRootProcessObservation: Equatable {
    case missing
    case running(LocalAgentObservedProcessIdentity)
    case unavailable
}

enum LocalAgentProcessGroupObservation: Equatable {
    case exited
    case running
    case unavailable
}

protocol LocalAgentProcessInspecting {
    func rootProcess(processIdentifier: Int32) -> LocalAgentRootProcessObservation
    func processGroup(processGroupIdentifier: Int32) -> LocalAgentProcessGroupObservation
}

/// Read-only OS evidence collector. It never signals, adopts, or relaunches the
/// recorded process. Ambiguous observations remain reconciliation-required.
public final class DarwinLocalAgentMaintenanceEvidenceCollector: LocalAgentMaintenanceEvidenceCollecting {
    private let inspector: LocalAgentProcessInspecting

    public convenience init() {
        self.init(inspector: DarwinLocalAgentProcessInspector())
    }

    init(inspector: LocalAgentProcessInspecting) {
        self.inspector = inspector
    }

    public func collectEvidence(
        for entry: LocalAgentMaintenanceProcessJournalEntry
    ) throws -> LocalAgentMaintenanceReconciliationEvidence {
        guard entry.state == .stateUnknown,
              let processIdentifier = entry.processIdentifier,
              let processGroupIdentifier = entry.processGroupIdentifier,
              let trustedStartTime = entry.trustedProcessStartTime
        else {
            throw LocalAgentMaintenanceEvidenceError.invalidJournalIdentity(entry.referenceID)
        }

        // A durable tree-exited event was emitted only by the managed terminal
        // after its complete process-group probe settled. It is stronger than a
        // later PID snapshot, which may already contain a reused PID.
        if entry.treeExited {
            return .init(
                processGenerationMatches: true,
                processGroupExited: true,
                businessResultCommitted: entry.businessResultCommitted,
                processWasIsolated: entry.businessResultCommitted == false
            )
        }

        let groupObservation = inspector.processGroup(
            processGroupIdentifier: processGroupIdentifier
        )
        guard groupObservation == .exited else {
            if groupObservation == .unavailable {
                throw LocalAgentMaintenanceEvidenceError.observationUnavailable(entry.referenceID)
            }
            return unresolvedEvidence(entry: entry)
        }

        let generationResolved: Bool
        switch inspector.rootProcess(processIdentifier: processIdentifier) {
        case .missing:
            generationResolved = true
        case .running(let observed):
            let isRecordedGeneration = observed.processIdentifier == processIdentifier
                && observed.processGroupIdentifier == processGroupIdentifier
                && abs(observed.trustedStartTime.timeIntervalSince(trustedStartTime)) < 0.001
            // If the PID now belongs to a different generation while the old
            // PGID is absent, the recorded generation is conclusively gone.
            generationResolved = isRecordedGeneration == false
        case .unavailable:
            throw LocalAgentMaintenanceEvidenceError.observationUnavailable(entry.referenceID)
        }

        return .init(
            processGenerationMatches: generationResolved,
            processGroupExited: true,
            businessResultCommitted: entry.businessResultCommitted,
            processWasIsolated: generationResolved && entry.businessResultCommitted == false
        )
    }

    private func unresolvedEvidence(
        entry: LocalAgentMaintenanceProcessJournalEntry
    ) -> LocalAgentMaintenanceReconciliationEvidence {
        .init(
            processGenerationMatches: false,
            processGroupExited: false,
            businessResultCommitted: entry.businessResultCommitted,
            processWasIsolated: false
        )
    }
}

private struct DarwinLocalAgentProcessInspector: LocalAgentProcessInspecting {
    func rootProcess(processIdentifier: Int32) -> LocalAgentRootProcessObservation {
        guard processIdentifier > 0 else { return .unavailable }
        errno = 0
        let existence = kill(processIdentifier, 0)
        if existence != 0, errno == ESRCH {
            return .missing
        }
        guard existence == 0 || errno == EPERM else {
            return .unavailable
        }

        var info = proc_bsdinfo()
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.stride)
        )
        guard result == MemoryLayout<proc_bsdinfo>.stride,
              info.pbi_pid == UInt32(processIdentifier),
              info.pbi_start_tvsec > 0
        else {
            return .unavailable
        }
        return .running(
            .init(
                processIdentifier: processIdentifier,
                processGroupIdentifier: Int32(info.pbi_pgid),
                trustedStartTime: Date(
                    timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                        + TimeInterval(info.pbi_start_tvusec) / 1_000_000
                )
            )
        )
    }

    func processGroup(processGroupIdentifier: Int32) -> LocalAgentProcessGroupObservation {
        guard processGroupIdentifier > 0 else { return .unavailable }
        var processIdentifiers = [pid_t](repeating: 0, count: 256)
        let byteCount = processIdentifiers.count * MemoryLayout<pid_t>.stride
        let listed = proc_listpgrppids(
            processGroupIdentifier,
            &processIdentifiers,
            Int32(byteCount)
        )
        if listed > 0 {
            let rawCount = Int(listed)
            let count = rawCount <= processIdentifiers.count
                ? rawCount
                : min(rawCount / MemoryLayout<pid_t>.stride, processIdentifiers.count)
            var sawUnavailable = false
            for processIdentifier in processIdentifiers.prefix(count) where processIdentifier > 0 {
                switch liveness(processIdentifier: processIdentifier) {
                case .live:
                    return .running
                case .unavailable:
                    sawUnavailable = true
                case .missing, .zombie:
                    continue
                }
            }
            return sawUnavailable ? .unavailable : .exited
        }
        if listed < 0 {
            return groupSignalProbe(processGroupIdentifier: processGroupIdentifier)
        }
        return groupSignalProbe(processGroupIdentifier: processGroupIdentifier)
    }

    private enum ProcessLiveness {
        case live
        case zombie
        case missing
        case unavailable
    }

    private func liveness(processIdentifier: pid_t) -> ProcessLiveness {
        errno = 0
        let existence = kill(processIdentifier, 0)
        if existence != 0, errno == ESRCH { return .missing }
        guard existence == 0 || errno == EPERM else { return .unavailable }

        var info = proc_bsdinfo()
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.stride)
        )
        guard result == MemoryLayout<proc_bsdinfo>.stride else { return .unavailable }
        return info.pbi_status == UInt32(SZOMB) ? .zombie : .live
    }

    private func groupSignalProbe(
        processGroupIdentifier: Int32
    ) -> LocalAgentProcessGroupObservation {
        errno = 0
        if kill(-processGroupIdentifier, 0) == 0 { return .running }
        switch errno {
        case ESRCH:
            return .exited
        case EPERM:
            return .running
        default:
            return .unavailable
        }
    }
}
