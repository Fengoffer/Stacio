import Foundation
import SQLite3
import StacioAgentBridge
import StacioCoreBindings

public typealias AIConversationHistoryItemDraft = AiConversationHistoryItemDraft
public typealias AIConversationHistoryItemRecord = AiConversationHistoryItemRecord

public enum AIConversationHistoryRole: String, Equatable {
    case user
    case assistant
    case command
    case terminal
    case plan
    case step

    static func fromStoredRawValue(_ rawValue: String) -> AIConversationHistoryRole {
        AIConversationHistoryRole(rawValue: rawValue) ?? .assistant
    }
}

public protocol AIAssistantConversationHistoryRecording {
    @discardableResult
    func appendConversationHistoryItem(
        runtimeID: String,
        role: AIConversationHistoryRole,
        content: String,
        requestID: String?
    ) throws -> AIConversationHistoryItemRecord
}

public protocol AIAssistantConversationHistoryListing {
    func listConversationHistory(runtimeID: String) throws -> [AIConversationHistoryItemRecord]
}

public protocol AIAssistantConversationHistoryClearing {
    func clearConversationHistory() throws
}

public struct AIAssistantConversationThreadSummary: Equatable {
    public let id: String
    public let title: String
    public let latestMessageAt: String
}

public protocol AIAssistantConversationThreadListing {
    func listConversationThreads(runtimeID: String) throws -> [AIAssistantConversationThreadSummary]
}

public extension AIAssistantConversationThreadListing {
    func listConversationThreads(runtimeID: String) throws -> [AIAssistantConversationThreadSummary] { [] }
}

public struct AIConversationHistoryConversationSummary: Equatable {
    public let runtimeID: String
    public let firstUserMessagePreview: String
    public let messageCount: Int
    public let createdAt: String
    public let latestMessageAt: String
    public let matchedSnippet: String?

    public init(
        runtimeID: String,
        firstUserMessagePreview: String,
        messageCount: Int,
        createdAt: String,
        latestMessageAt: String,
        matchedSnippet: String?
    ) {
        self.runtimeID = runtimeID
        self.firstUserMessagePreview = firstUserMessagePreview
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.latestMessageAt = latestMessageAt
        self.matchedSnippet = matchedSnippet
    }
}

public protocol AIAssistantConversationHistoryConversationListing {
    func listConversationSummaries(searchQuery: String?) throws -> [AIConversationHistoryConversationSummary]
}

public protocol AIAssistantConversationHistoryDeleting {
    func deleteConversationHistory(runtimeID: String) throws
}

public typealias AIAssistantConversationHistoryBrowsing =
    AIAssistantConversationHistoryConversationListing
    & AIAssistantConversationHistoryListing
    & AIAssistantConversationHistoryDeleting
    & AIAssistantConversationHistoryClearing

public typealias AIAssistantConversationHistoryStoring =
    AIAssistantConversationHistoryRecording
    & AIAssistantConversationHistoryListing
    & AIAssistantConversationHistoryClearing
    & AIAssistantConversationThreadListing

public struct CoreBridgeAIAssistantConversationHistoryStore: AIAssistantConversationHistoryRecording,
    AIAssistantConversationHistoryBrowsing, AIAssistantConversationThreadListing {
    private let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public static func defaultStore() -> CoreBridgeAIAssistantConversationHistoryStore? {
        guard let databasePath = try? StacioPaths().databaseURL.path else {
            return nil
        }
        return CoreBridgeAIAssistantConversationHistoryStore(databasePath: databasePath)
    }

    @discardableResult
    public func appendConversationHistoryItem(
        runtimeID: String,
        role: AIConversationHistoryRole,
        content: String,
        requestID: String?
    ) throws -> AIConversationHistoryItemRecord {
        try CoreBridge.appendAIConversationHistoryItem(
            databasePath: databasePath,
            item: AIConversationHistoryItemDraft(
                runtimeId: runtimeID,
                role: role.rawValue,
                content: redactedHistoryContent(content),
                requestId: requestID
            )
        )
    }

    public func listConversationHistory(runtimeID: String) throws -> [AIConversationHistoryItemRecord] {
        try CoreBridge.listAIConversationHistory(databasePath: databasePath, runtimeID: runtimeID)
    }

    public func listConversationThreads(runtimeID: String) throws -> [AIAssistantConversationThreadSummary] {
        let connection = try AIConversationHistorySQLiteConnection(path: databasePath)
        guard try connection.tableExists("ai_conversation_history") else { return [] }
        let prefix = Self.threadStorageID(runtimeID: runtimeID, threadID: "")
        let statement = try connection.prepare(
            """
            SELECT runtime_id,
                   COALESCE((SELECT content FROM ai_conversation_history first
                             WHERE first.runtime_id = history.runtime_id AND first.role = 'user'
                             ORDER BY first.rowid ASC LIMIT 1), ''),
                   MAX(created_at)
            FROM ai_conversation_history history
            WHERE runtime_id = ? OR runtime_id LIKE ? ESCAPE '\\'
            GROUP BY runtime_id
            ORDER BY MAX(rowid) DESC
            """
        )
        defer { sqlite3_finalize(statement) }
        try connection.bind(runtimeID, to: 1, in: statement)
        try connection.bind(Self.prefixLikePattern(for: prefix), to: 2, in: statement)
        var threads: [AIAssistantConversationThreadSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let storageID = connection.columnString(statement, index: 0)
            let threadID = Self.threadID(from: storageID, runtimeID: runtimeID) ?? "legacy"
            let firstMessage = connection.columnString(statement, index: 1)
            threads.append(.init(
                id: threadID,
                title: firstMessage.isEmpty ? "排查会话" : Self.previewText(firstMessage),
                latestMessageAt: connection.columnString(statement, index: 2)
            ))
        }
        return threads
    }

    public static func threadStorageID(runtimeID: String, threadID: String) -> String {
        threadID == "legacy" ? runtimeID : runtimeID + "\u{1F}" + threadID
    }

    private static func threadID(from storageID: String, runtimeID: String) -> String? {
        let prefix = runtimeID + "\u{1F}"
        guard storageID.hasPrefix(prefix) else { return storageID == runtimeID ? "legacy" : nil }
        return String(storageID.dropFirst(prefix.count))
    }

    public func clearConversationHistory() throws {
        try CoreBridge.clearAIConversationHistory(databasePath: databasePath)
    }

    public func listConversationSummaries(searchQuery: String?) throws -> [AIConversationHistoryConversationSummary] {
        let connection = try AIConversationHistorySQLiteConnection(path: databasePath)
        guard try connection.tableExists("ai_conversation_history") else {
            return []
        }

        let trimmedQuery = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSearchQuery = trimmedQuery?.isEmpty == false
        let searchClause = hasSearchQuery
            ? """
              WHERE EXISTS (
                SELECT 1
                FROM ai_conversation_history matched
                WHERE matched.runtime_id = grouped.runtime_id
                  AND matched.content LIKE ? ESCAPE '\\' COLLATE NOCASE
              )
              """
            : ""
        let matchedSnippetColumn = hasSearchQuery
            ? """
              COALESCE((
                SELECT matched.content
                FROM ai_conversation_history matched
                WHERE matched.runtime_id = grouped.runtime_id
                  AND matched.content LIKE ? ESCAPE '\\' COLLATE NOCASE
                ORDER BY matched.rowid ASC
                LIMIT 1
              ), '')
              """
            : "NULL"
        let sql = """
            WITH grouped AS (
                SELECT runtime_id,
                       COUNT(*) AS message_count,
                       MIN(created_at) AS created_at,
                       MAX(created_at) AS latest_message_at
                FROM ai_conversation_history
                GROUP BY runtime_id
            )
            SELECT grouped.runtime_id,
                   COALESCE((
                       SELECT first_user.content
                       FROM ai_conversation_history first_user
                       WHERE first_user.runtime_id = grouped.runtime_id
                         AND first_user.role = 'user'
                       ORDER BY first_user.rowid ASC
                       LIMIT 1
                   ), ''),
                   grouped.message_count,
                   grouped.created_at,
                   grouped.latest_message_at,
                   \(matchedSnippetColumn)
            FROM grouped
            \(searchClause)
            ORDER BY grouped.created_at DESC, grouped.runtime_id DESC
            """
        let pattern = hasSearchQuery ? trimmedQuery.map(Self.likePattern(for:)) : nil
        let statement = try connection.prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let pattern {
            try connection.bind(pattern, to: 1, in: statement)
            try connection.bind(pattern, to: 2, in: statement)
        }

        var summaries: [AIConversationHistoryConversationSummary] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw connection.error("step conversation summaries")
            }
            let firstUserMessage = connection.columnString(statement, index: 1)
            let matchedSnippet = connection.columnOptionalString(statement, index: 5)
            summaries.append(
                AIConversationHistoryConversationSummary(
                    runtimeID: connection.columnString(statement, index: 0),
                    firstUserMessagePreview: Self.previewText(firstUserMessage),
                    messageCount: Int(sqlite3_column_int64(statement, 2)),
                    createdAt: connection.columnString(statement, index: 3),
                    latestMessageAt: connection.columnString(statement, index: 4),
                    matchedSnippet: matchedSnippet?.isEmpty == true ? nil : matchedSnippet
                )
            )
        }
        return summaries
    }

    public func deleteConversationHistory(runtimeID: String) throws {
        let connection = try AIConversationHistorySQLiteConnection(path: databasePath)
        guard try connection.tableExists("ai_conversation_history") else {
            return
        }
        let statement = try connection.prepare(
            "DELETE FROM ai_conversation_history WHERE runtime_id = ? OR runtime_id LIKE ? ESCAPE '\\'"
        )
        defer { sqlite3_finalize(statement) }
        try connection.bind(runtimeID, to: 1, in: statement)
        try connection.bind(Self.prefixLikePattern(for: Self.threadStorageID(runtimeID: runtimeID, threadID: "")), to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw connection.error("delete conversation history")
        }
    }

    private func redactedHistoryContent(_ content: String) -> String {
        content
            .components(separatedBy: .newlines)
            .map { AgentProtocolRedaction.redact($0) }
            .joined(separator: "\n")
    }

    private static func previewText(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    private static func likePattern(for query: String) -> String {
        var pattern = "%"
        for character in query {
            if character == "\\" || character == "%" || character == "_" {
                pattern.append("\\")
            }
            pattern.append(character)
        }
        pattern.append("%")
        return pattern
    }

    private static func prefixLikePattern(for prefix: String) -> String {
        var pattern = ""
        for character in prefix {
            if character == "\\" || character == "%" || character == "_" {
                pattern.append("\\")
            }
            pattern.append(character)
        }
        pattern.append("%")
        return pattern
    }
}

private final class AIConversationHistorySQLiteConnection {
    private let database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            if let database {
                sqlite3_close(database)
            }
            throw NSError(
                domain: "Stacio.AIConversationHistory.SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "SQLite open failed: \(message)"]
            )
        }
        self.database = database
    }

    deinit {
        sqlite3_close(database)
    }

    func tableExists(_ tableName: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind(tableName, to: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return true
        }
        if result == SQLITE_DONE {
            return false
        }
        throw error("check table exists")
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw error("prepare SQL")
        }
        return statement
    }

    func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard result == SQLITE_OK else {
            throw error("bind SQL text")
        }
    }

    func columnString(_ statement: OpaquePointer?, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: text)
    }

    func columnOptionalString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return columnString(statement, index: index)
    }

    func error(_ action: String) -> NSError {
        let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
        return NSError(
            domain: "Stacio.AIConversationHistory.SQLite",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: "SQLite \(action) failed: \(message)"]
        )
    }
}
