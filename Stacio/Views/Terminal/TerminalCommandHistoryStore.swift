import Foundation

public struct TerminalCommandHistoryEntry: Equatable, Identifiable {
    public let id: UUID
    public let runtimeID: String
    public let command: String
    public let usedAt: Date

    public init(id: UUID = UUID(), runtimeID: String, command: String, usedAt: Date) {
        self.id = id
        self.runtimeID = runtimeID
        self.command = command
        self.usedAt = usedAt
    }
}

public final class TerminalCommandHistoryStore {
    private let maxEntriesPerRuntime: Int
    private let dateProvider: () -> Date
    private var entriesByRuntimeID: [String: [TerminalCommandHistoryEntry]] = [:]

    public init(
        maxEntriesPerRuntime: Int = 200,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.maxEntriesPerRuntime = max(1, maxEntriesPerRuntime)
        self.dateProvider = dateProvider
    }

    @discardableResult
    public func record(runtimeID: String, command rawCommand: String) -> TerminalCommandHistoryEntry? {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard runtimeID.isEmpty == false,
              command.isEmpty == false
        else {
            return nil
        }

        let entry = TerminalCommandHistoryEntry(
            runtimeID: runtimeID,
            command: command,
            usedAt: dateProvider()
        )
        var entries = entriesByRuntimeID[runtimeID] ?? []
        entries.append(entry)
        if entries.count > maxEntriesPerRuntime {
            entries.removeFirst(entries.count - maxEntriesPerRuntime)
        }
        entriesByRuntimeID[runtimeID] = entries
        return entry
    }

    public func entries(for runtimeID: String?) -> [TerminalCommandHistoryEntry] {
        guard let runtimeID,
              runtimeID.isEmpty == false
        else {
            return []
        }
        return Array((entriesByRuntimeID[runtimeID] ?? []).reversed())
    }

    public func replaceRuntimeID(oldRuntimeID: String, newRuntimeID: String) {
        guard oldRuntimeID != newRuntimeID,
              var entries = entriesByRuntimeID.removeValue(forKey: oldRuntimeID)
        else {
            return
        }
        entries = entries.map { entry in
            TerminalCommandHistoryEntry(
                id: entry.id,
                runtimeID: newRuntimeID,
                command: entry.command,
                usedAt: entry.usedAt
            )
        }
        var mergedEntries = entriesByRuntimeID[newRuntimeID] ?? []
        mergedEntries.append(contentsOf: entries)
        if mergedEntries.count > maxEntriesPerRuntime {
            mergedEntries.removeFirst(mergedEntries.count - maxEntriesPerRuntime)
        }
        entriesByRuntimeID[newRuntimeID] = mergedEntries
    }

    public func removeEntries(for runtimeID: String) {
        entriesByRuntimeID.removeValue(forKey: runtimeID)
    }
}

final class TerminalCommandHistoryInputBuffer {
    private var buffer: [UInt8] = []

    func ingest(bytes: [UInt8]) -> [String] {
        var submittedCommands: [String] = []
        for byte in bytes {
            switch byte {
            case 10, 13:
                if let command = processSubmittedLine() {
                    submittedCommands.append(command)
                }
            case 3, 21, 27:
                reset()
            case 9:
                continue
            case 8, 127:
                removeLastCharacter()
            case 0..<32:
                continue
            default:
                buffer.append(byte)
            }
        }
        return submittedCommands
    }

    func reset() {
        buffer.removeAll()
    }

    private func processSubmittedLine() -> String? {
        guard buffer.isEmpty == false else {
            return nil
        }
        let command = String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll()
        return command.isEmpty ? nil : command
    }

    private func removeLastCharacter() {
        guard buffer.isEmpty == false else { return }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer = Array(text.dropLast().utf8)
    }
}
