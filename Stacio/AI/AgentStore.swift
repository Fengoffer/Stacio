import Foundation
import StacioAgentBridge

/// Persistence for the AI panel.
///
/// One JSON document per conversation, written atomically. Streaming updates are
/// coalesced so a token burst does not become a disk write per token. Drafts live
/// inside the conversation document so switching conversations cannot leak input.
///
/// Legacy AI data is never deleted: on first launch the V2 conversation database,
/// assistant settings and local-agent configuration are copied into
/// `legacy-backup/` so they stay readable after the old code is gone.
final class AgentStore {
 static let shared = AgentStore()
 static let historyRemoved = Notification.Name("Stacio.Agent.historyRemoved")

 @MainActor func removeHistory(before cutoff: Date? = nil) {
 flush()
 let ids = Set(loadAll().filter { conversation in
     guard let cutoff else { return true }
     return conversation.updatedAt < cutoff && !conversation.phase.isActive
 }.map { $0.id })
 guard !ids.isEmpty else { return }
 NotificationCenter.default.post(name: Self.historyRemoved, object: self, userInfo: ["ids": ids])
 for id in ids { delete(id: id) }
 }

 struct IndexEntry: Codable, Equatable {
 var id: String
 var title: String
 var updatedAt: Date
 var isDraft: Bool
 }

 private struct MigrationRecord: Codable {
 var version: Int
 var performedAt: Date
 var copiedFiles: [String]
 var note: String
 }

 private let fileManager: FileManager
 let rootDirectory: URL
 private let conversationsDirectory: URL
 private let indexURL: URL
 private let migrationURL: URL
 private let legacyBackupDirectory: URL

 private var pendingWork: [String: DispatchWorkItem] = [:]
 private var pendingSnapshot: [String: AgentConversation] = [:]
 private let queue = DispatchQueue(label: "com.stacio.agent.store", qos: .utility)
 private let saveDebounce: TimeInterval

 private var savedIndex: [IndexEntry] = []
 var index: [IndexEntry] { queue.sync { savedIndex } }

 init(rootDirectory: URL? = nil, fileManager: FileManager = .default, saveDebounce: TimeInterval=0.6) {
 self.fileManager = fileManager
 self.saveDebounce = saveDebounce
 let base = rootDirectory ?? AgentStore.defaultRootDirectory(fileManager: fileManager)
 self.rootDirectory = base
 self.conversationsDirectory = base.appendingPathComponent("conversations", isDirectory: true)
 self.indexURL = base.appendingPathComponent("index.json")
 self.migrationURL = base.appendingPathComponent("migration-v1.json")
 self.legacyBackupDirectory = base.appendingPathComponent("legacy-backup", isDirectory: true)
 try? fileManager.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
 loadIndex()
 }

 static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
 let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
 let base = support ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
 return base.appendingPathComponent("Stacio/agent-v1", isDirectory: true)
 }

 // MARK: - Loading

 func loadAll() -> [AgentConversation] {
 let urls = (try? fileManager.contentsOfDirectory(at: conversationsDirectory, includingPropertiesForKeys: nil)) ?? []
 var result: [AgentConversation] = []
 for url in urls where url.pathExtension == "json" {
 guard let data = try? Data(contentsOf: url) else { continue }
 guard let conversation = try? AgentStore.decoder.decode(AgentConversation.self, from: data) else { continue }
 result.append(conversation)
 }
 result.sort { $0.updatedAt > $1.updatedAt }
 return result
 }

 func load(id: String) -> AgentConversation? {
 let url = conversationsDirectory.appendingPathComponent("\(id).json")
 guard let data = try? Data(contentsOf: url) else { return nil }
 return try? AgentStore.decoder.decode(AgentConversation.self, from: data)
 }

 private func loadIndex() {
 guard let data = try? Data(contentsOf: indexURL) else { return }
 guard let entries = try? AgentStore.decoder.decode([IndexEntry].self, from: data) else { return }
 savedIndex = entries
 }

 // MARK: - Saving

 func save(_ conversation: AgentConversation, immediately: Bool = false) {
 queue.sync { scheduleSave(conversation, immediately: immediately) }
 }

 private func scheduleSave(_ conversation: AgentConversation, immediately: Bool) {
 let snapshot = conversation
 pendingWork[snapshot.id]?.cancel()
 if immediately {
 pendingSnapshot.removeValue(forKey: snapshot.id)
 write(snapshot)
 return
 }
 pendingSnapshot[snapshot.id] = snapshot
 let work = DispatchWorkItem { [weak self] in
 guard let self else { return }
 self.write(snapshot)
 self.pendingSnapshot.removeValue(forKey: snapshot.id)
 self.pendingWork.removeValue(forKey: snapshot.id)
 }
 pendingWork[snapshot.id] = work
 queue.asyncAfter(deadline: .now() + saveDebounce, execute: work)
 }

 func flush() {
 queue.sync {
 for work in pendingWork.values { work.cancel() }
 for (_, conversation) in pendingSnapshot {
 write(conversation)
 }
 pendingSnapshot.removeAll()
 pendingWork.removeAll()
 }
 }

 func delete(id: String) {
 queue.sync {
 pendingWork[id]?.cancel()
 pendingWork.removeValue(forKey: id)
 pendingSnapshot.removeValue(forKey: id)
 let url = conversationsDirectory.appendingPathComponent("\(id).json")
 try? fileManager.removeItem(at: url)
 try? fileManager.removeItem(at: rootDirectory.appendingPathComponent("images").appendingPathComponent(id))
 savedIndex.removeAll { $0.id == id }
 writeIndex()
 }
 }

 private func write(_ conversation: AgentConversation) {
 let url = conversationsDirectory.appendingPathComponent("\(conversation.id).json")
 var saved = conversation
 for index in saved.items.indices {
 guard var tool = saved.items[index].tool, let scope = tool.recordingScope else { continue }
 if scope == "none" { tool.output = "" }
 else {
 let redacted = AgentProtocolRedaction.redactPreservingLineBreaks(tool.output)
 let limit = scope == "fullWhenAudited" && tool.completionState == .confirmed ? 32_000 : 8_000
 tool.output = AIAssistantPanelViewController.boundedTerminalHistoryText(redacted, characterLimit: limit)
 }
 saved.items[index].tool = tool
 }
 guard let data = try? AgentStore.encoder.encode(saved) else { return }
 try? data.write(to: url, options: .atomic)
 upsertIndex(conversation)
 }

 private func upsertIndex(_ conversation: AgentConversation) {
 let entry = IndexEntry(id: conversation.id, title: conversation.displayTitle, updatedAt: conversation.updatedAt, isDraft: conversation.isDraft)
 if let position = savedIndex.firstIndex(where: { $0.id == entry.id }) {
 if savedIndex[position] == entry { return }
 savedIndex[position] = entry
 } else {
 savedIndex.append(entry)
 }
 savedIndex.sort { $0.updatedAt > $1.updatedAt }
 writeIndex()
 }

 private func writeIndex() {
 guard let data = try? AgentStore.encoder.encode(savedIndex) else { return }
 try? data.write(to: indexURL, options: .atomic)
 }

 // MARK: - Legacy preservation

 /// Copies legacy AI state into `legacy-backup/` exactly once. The originals stay
 /// where they are; nothing is lost even if the new panel is removed later.
 @discardableResult
 func preserveLegacyData(supportDirectory: URL? = nil) -> [String] {
 if let data = try? Data(contentsOf: migrationURL) {
 if let record = try? AgentStore.decoder.decode(MigrationRecord.self, from: data), record.version >= 1 {
 return record.copiedFiles
 }
 }
 let base = supportDirectory ?? rootDirectory.deletingLastPathComponent()
 let candidates = [
 "agent-conversations-v2.sqlite3",
 "agent-conversations-v2.sqlite3-wal",
 "agent-conversations-v2.sqlite3-shm",
 "agent-control.sqlite3",
 "assistant-settings.sqlite3",
 "assistant-settings-values-v1.json",
 "runtime-configurations-v2.sqlite3",
 "local-agent-configurations-v1.json",
 "local-agent-maintenance-journal-v1.json"
 ]
 try? fileManager.createDirectory(at: legacyBackupDirectory, withIntermediateDirectories: true)
 var copied: [String] = []
 for name in candidates {
 let source = base.appendingPathComponent(name)
 guard fileManager.fileExists(atPath: source.path) else { continue }
 let destination = legacyBackupDirectory.appendingPathComponent(name)
 if fileManager.fileExists(atPath: destination.path) {
 copied.append(name)
 continue
 }
 do {
 try fileManager.copyItem(at: source, to: destination)
 copied.append(name)
 } catch {
 continue
 }
 }
 let record = MigrationRecord(version:1, performedAt: Date(), copiedFiles: copied, note: "旧 AI助手的数据库与配置文件已复制保留，可直接读取；新面板不复用这些数据库。")
 if let data = try? AgentStore.encoder.encode(record) {
 try? data.write(to: migrationURL, options: .atomic)
 }
 return copied
 }

 // MARK: - Coders

 private static let encoder: JSONEncoder = {
 let encoder = JSONEncoder()
 encoder.dateEncodingStrategy = .iso8601
 encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
 return encoder
 }()

 private static let decoder: JSONDecoder = {
 let decoder = JSONDecoder()
 decoder.dateDecodingStrategy = .iso8601
 return decoder
 }()
}
