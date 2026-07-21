import Foundation

public enum ExternalImportedCredential: Equatable, Sendable {
    case password(String)
    case privateKeyPassphrase(String)
}

public struct ExternalImportedSession: Equatable, Sendable {
    public let name: String
    public let folderPath: String?
    public let protocolName: String
    public let host: String
    public let port: UInt16
    public let username: String?
    public let privateKeyPath: String?
    public let credential: ExternalImportedCredential?
}

public struct ExternalSessionImportPayload: Equatable, Sendable {
    public let sessions: [ExternalImportedSession]
    public let warnings: [String]
}

public enum ExternalSessionImportParserError: Error, Equatable {
    case unsupportedSource
    case invalidFormat
    case noSessions
}

public enum ExternalSessionImportParser {
    public static func parseText(
        _ text: String,
        sourceType: SessionImportSourceType,
        sourceName: String
    ) throws -> ExternalSessionImportPayload {
        let payload: ExternalSessionImportPayload
        switch sourceType {
        case .mobaXterm:
            payload = parseMobaXterm(text)
        case .xShell:
            payload = parseXshell(text, sourceName: sourceName)
        case .windTerm:
            payload = try parseWindTerm(text)
        case .secureCRT:
            payload = try parseSecureCRT(text)
        case .electerm:
            payload = try parseElecterm(text)
        case .termius:
            payload = try parseTermius(text)
        default:
            throw ExternalSessionImportParserError.unsupportedSource
        }
        guard payload.sessions.isEmpty == false else {
            throw ExternalSessionImportParserError.noSessions
        }
        return payload
    }

    public static func parseDirectory(
        _ directoryURL: URL,
        sourceType: SessionImportSourceType,
        sourceName: String
    ) throws -> ExternalSessionImportPayload {
        let payload: ExternalSessionImportPayload
        switch sourceType {
        case .finalShell:
            payload = try parseFinalShell(directoryURL)
        case .xShell:
            payload = try parseXshellDirectory(directoryURL)
        default:
            throw ExternalSessionImportParserError.unsupportedSource
        }
        guard payload.sessions.isEmpty == false else {
            throw ExternalSessionImportParserError.noSessions
        }
        return payload
    }

    private static func parseXshellDirectory(_ directoryURL: URL) throws -> ExternalSessionImportPayload {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw ExternalSessionImportParserError.invalidFormat }
        var sessions: [ExternalImportedSession] = []
        for case let fileURL as URL in enumerator where ["xsh", "xts"].contains(fileURL.pathExtension.lowercased()) {
            let rootComponents = directoryURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let fileComponents = fileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let relativePath = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
            let sourceName = relativePath.replacingOccurrences(of: "/", with: "__")
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            sessions.append(contentsOf: parseXshell(text, sourceName: sourceName).sessions)
        }
        return ExternalSessionImportPayload(sessions: sessions, warnings: [])
    }

    private static func parseMobaXterm(_ text: String) -> ExternalSessionImportPayload {
        let sections = iniSections(text)
        let passwords = sections["Passwords"] ?? [:]
        var sessions: [ExternalImportedSession] = []
        for (sectionName, values) in sections where sectionName.hasPrefix("Bookmarks") {
            let folder = normalizedFolderPath(values["SubRep"]?.replacingOccurrences(of: "\\", with: "/"))
            for (name, value) in values where name != "SubRep" && value.hasPrefix("#109#") {
                let fields = value.split(separator: "%", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 4 else { continue }
                let host = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard host.isEmpty == false else { continue }
                let port = UInt16(fields[2]) ?? 22
                let username = optionalTrimmed(fields[3])
                let password = mobaXtermPassword(
                    for: name,
                    host: host,
                    port: port,
                    username: username,
                    passwords: passwords
                )
                sessions.append(
                    ExternalImportedSession(
                        name: name,
                        folderPath: folder,
                        protocolName: "ssh",
                        host: host,
                        port: port,
                        username: username,
                        privateKeyPath: nil,
                        credential: password.flatMap(optionalTrimmed).map(ExternalImportedCredential.password)
                    )
                )
            }
        }
        return ExternalSessionImportPayload(sessions: sessions, warnings: [])
    }

    private static func parseXshell(_ text: String, sourceName: String) -> ExternalSessionImportPayload {
        let sections = iniSections(text)
        let connection = sections["CONNECTION"] ?? sections["Connection"] ?? [:]
        let authentication = sections["AUTHENTICATION"] ?? sections["Authentication"] ?? [:]
        guard let host = optionalTrimmed(connection["Host"] ?? connection["HostName"]) else {
            return ExternalSessionImportPayload(sessions: [], warnings: [])
        }
        let rawBaseName = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        let nameParts = rawBaseName.components(separatedBy: "__")
        let name = nameParts.last.flatMap(optionalTrimmed) ?? host
        let folder = nameParts.count > 1 ? normalizedFolderPath(nameParts.dropLast().joined(separator: "/")) : nil
        let keyPath = optionalTrimmed(authentication["UserKey"] ?? authentication["PrivateKey"])
        let passphrase = optionalTrimmed(authentication["Passphrase"])
        let password = optionalTrimmed(connection["Password"] ?? authentication["Password"])
        let credential: ExternalImportedCredential?
        if keyPath != nil {
            credential = passphrase.map(ExternalImportedCredential.privateKeyPassphrase)
        } else {
            credential = password.map(ExternalImportedCredential.password)
        }
        return ExternalSessionImportPayload(
            sessions: [
                ExternalImportedSession(
                    name: name,
                    folderPath: folder,
                    protocolName: "ssh",
                    host: host,
                    port: UInt16(connection["Port"] ?? "") ?? 22,
                    username: optionalTrimmed(connection["UserName"] ?? connection["Username"]),
                    privateKeyPath: keyPath,
                    credential: credential
                )
            ],
            warnings: []
        )
    }

    private static func parseWindTerm(_ text: String) throws -> ExternalSessionImportPayload {
        guard let entries = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
            throw ExternalSessionImportParserError.invalidFormat
        }
        let sessions = entries.compactMap { entry -> ExternalImportedSession? in
            guard (entry["session.protocol"] as? String)?.caseInsensitiveCompare("SSH") == .orderedSame,
                  let target = optionalTrimmed(entry["session.target"] as? String)
            else { return nil }
            let targetParts = target.split(separator: "@", maxSplits: 1).map(String.init)
            let username = targetParts.count == 2 ? optionalTrimmed(targetParts[0]) : nil
            let host = targetParts.count == 2 ? targetParts[1] : targetParts[0]
            guard host.isEmpty == false else { return nil }
            return ExternalImportedSession(
                name: optionalTrimmed(entry["session.label"] as? String) ?? host,
                folderPath: normalizedFolderPath((entry["session.group"] as? String)?.replacingOccurrences(of: ">", with: "/")),
                protocolName: "ssh",
                host: host,
                port: uint16(entry["session.port"]) ?? 22,
                username: username,
                privateKeyPath: optionalTrimmed(entry["session.privateKey"] as? String),
                credential: optionalTrimmed(entry["session.password"] as? String).map(ExternalImportedCredential.password)
            )
        }
        return ExternalSessionImportPayload(sessions: sessions, warnings: [])
    }

    private static func parseSecureCRT(_ text: String) throws -> ExternalSessionImportPayload {
        let delegate = SecureCRTImportXMLDelegate()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = delegate
        guard parser.parse() else { throw ExternalSessionImportParserError.invalidFormat }
        return ExternalSessionImportPayload(sessions: delegate.sessions, warnings: delegate.warnings)
    }

    private static func parseElecterm(_ text: String) throws -> ExternalSessionImportPayload {
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let bookmarks = root["bookmarks"] as? [[String: Any]]
        else { throw ExternalSessionImportParserError.invalidFormat }
        let groups = (root["bookmarkGroups"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) { result, group in
            guard let title = optionalTrimmed(group["title"] as? String) else { return }
            for bookmarkID in group["bookmarkIds"] as? [String] ?? [] {
                result[bookmarkID] = title
            }
        }
        let sessions = bookmarks.compactMap { bookmark -> ExternalImportedSession? in
            guard (bookmark["type"] as? String)?.caseInsensitiveCompare("ssh") == .orderedSame,
                  bookmark["enableSsh"] as? Bool != false,
                  let host = optionalTrimmed(bookmark["host"] as? String)
            else { return nil }
            let id = bookmark["id"] as? String ?? ""
            return ExternalImportedSession(
                name: optionalTrimmed(bookmark["title"] as? String) ?? host,
                folderPath: normalizedFolderPath(groups[id]),
                protocolName: "ssh",
                host: host,
                port: uint16(bookmark["port"]) ?? 22,
                username: optionalTrimmed(bookmark["username"] as? String),
                privateKeyPath: optionalTrimmed(bookmark["privateKeyPath"] as? String),
                credential: optionalTrimmed(bookmark["password"] as? String).map(ExternalImportedCredential.password)
            )
        }
        return ExternalSessionImportPayload(sessions: sessions, warnings: [])
    }

    private static func parseTermius(_ text: String) throws -> ExternalSessionImportPayload {
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let hosts = root["hosts"] as? [[String: Any]]
        else { throw ExternalSessionImportParserError.invalidFormat }
        let groups = (root["groups"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) { result, group in
            guard let id = group["id"] as? String,
                  let label = optionalTrimmed(group["label"] as? String ?? group["name"] as? String)
            else { return }
            result[id] = label
        }
        let sessions = hosts.compactMap { hostRecord -> ExternalImportedSession? in
            guard let host = optionalTrimmed(hostRecord["address"] as? String ?? hostRecord["host"] as? String) else {
                return nil
            }
            let keyPath = optionalTrimmed(hostRecord["private_key_path"] as? String ?? hostRecord["privateKeyPath"] as? String)
            let passphrase = optionalTrimmed(hostRecord["passphrase"] as? String)
            let password = optionalTrimmed(hostRecord["password"] as? String)
            return ExternalImportedSession(
                name: optionalTrimmed(hostRecord["label"] as? String ?? hostRecord["name"] as? String) ?? host,
                folderPath: (hostRecord["group_id"] as? String).flatMap { normalizedFolderPath(groups[$0]) },
                protocolName: "ssh",
                host: host,
                port: uint16(hostRecord["port"]) ?? 22,
                username: optionalTrimmed(hostRecord["username"] as? String),
                privateKeyPath: keyPath,
                credential: keyPath == nil
                    ? password.map(ExternalImportedCredential.password)
                    : passphrase.map(ExternalImportedCredential.privateKeyPassphrase)
            )
        }
        return ExternalSessionImportPayload(sessions: sessions, warnings: [])
    }

    private static func parseFinalShell(_ directoryURL: URL) throws -> ExternalSessionImportPayload {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw ExternalSessionImportParserError.invalidFormat }
        var folders: [String: (name: String, parentID: String?)] = [:]
        var connections: [[String: Any]] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "folder.json" || url.lastPathComponent.hasSuffix("_connect_config.json") else {
                continue
            }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let record = object as? [String: Any] else { continue }
            if url.lastPathComponent == "folder.json",
               (record["delete_time"] as? NSNumber)?.uint64Value ?? 0 == 0,
               let id = record["id"] as? String,
               let name = optionalTrimmed(record["name"] as? String) {
                folders[id] = (name, optionalTrimmed(record["parent_id"] as? String))
            } else {
                connections.append(record)
            }
        }
        let sessions = connections.compactMap { record -> ExternalImportedSession? in
            guard (record["delete_time"] as? NSNumber)?.uint64Value ?? 0 == 0,
                  (record["conection_type"] as? NSNumber)?.intValue == 100,
                  let host = optionalTrimmed(record["host"] as? String)
            else { return nil }
            let keyPath = optionalTrimmed(record["private_key_path"] as? String)
            let password = optionalTrimmed(record["password"] as? String)
            let passphrase = optionalTrimmed(record["passphrase"] as? String)
            return ExternalImportedSession(
                name: optionalTrimmed(record["name"] as? String) ?? host,
                folderPath: (record["parent_id"] as? String).flatMap { finalShellFolderPath($0, folders: folders) },
                protocolName: "ssh",
                host: host,
                port: uint16(record["port"]) ?? 22,
                username: optionalTrimmed(record["user_name"] as? String),
                privateKeyPath: keyPath,
                credential: keyPath == nil
                    ? password.map(ExternalImportedCredential.password)
                    : passphrase.map(ExternalImportedCredential.privateKeyPassphrase)
            )
        }
        return ExternalSessionImportPayload(sessions: sessions, warnings: [])
    }

    private static func finalShellFolderPath(
        _ id: String,
        folders: [String: (name: String, parentID: String?)]
    ) -> String? {
        var path: [String] = []
        var current: String? = id
        var visited: Set<String> = []
        while let id = current, id != "root", id != "0", visited.insert(id).inserted,
              let folder = folders[id] {
            path.append(folder.name)
            current = folder.parentID
        }
        return normalizedFolderPath(path.reversed().joined(separator: "/"))
    }

    private static func iniSections(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                result[section, default: [:]] = result[section, default: [:]]
            } else if let separator = line.firstIndex(of: "="), section.isEmpty == false {
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                result[section, default: [:]][key] = value
            }
        }
        return result
    }

    private static func normalizedFolderPath(_ value: String?) -> String? {
        let segments = value?.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        return segments.isEmpty ? nil : segments.joined(separator: "/")
    }

    private static func mobaXtermPassword(
        for sessionName: String,
        host: String,
        port: UInt16,
        username: String?,
        passwords: [String: String]
    ) -> String? {
        var keys = [host, "\(host):\(port)", sessionName]
        if let username {
            keys.insert("\(username)@\(host)", at: 0)
            keys.insert("\(username)@\(host):\(port)", at: 1)
            keys.append("\(host)@\(username)")
            keys.append("\(host):\(port)@\(username)")
        }
        let normalizedPasswords = passwords.reduce(into: [String: String]()) { result, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key.isEmpty == false, result[key] == nil else { return }
            result[key] = entry.value
        }
        for key in keys {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let password = optionalTrimmed(normalizedPasswords[normalizedKey]) {
                return password
            }
        }
        return nil
    }

    private static func optionalTrimmed(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func uint16(_ value: Any?) -> UInt16? {
        if let value = value as? NSNumber { return UInt16(exactly: value.uint64Value) }
        if let value = value as? String { return UInt16(value) }
        return nil
    }
}

private final class SecureCRTImportXMLDelegate: NSObject, XMLParserDelegate {
    struct Frame {
        let name: String
        var fields: [String: String]
    }

    var sessions: [ExternalImportedSession] = []
    var warnings: [String] = []
    private var stack: [Frame] = []
    private var currentField: String?
    private var currentValue = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "key" {
            stack.append(Frame(name: attributeDict["name"] ?? "", fields: [:]))
        } else if elementName == "string" || elementName == "dword" {
            currentField = attributeDict["name"]
            currentValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentField != nil { currentValue += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "string" || elementName == "dword" {
            if let field = currentField, stack.isEmpty == false {
                stack[stack.count - 1].fields[field] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentField = nil
            currentValue = ""
            return
        }
        guard elementName == "key", let frame = stack.popLast() else { return }
        guard frame.fields["Protocol Name"]?.caseInsensitiveCompare("SSH2") == .orderedSame,
              let host = frame.fields["Hostname"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              host.isEmpty == false
        else { return }
        let sessionsIndex = stack.firstIndex { $0.name == "Sessions" }
        let folder = sessionsIndex.map { index in
            stack.dropFirst(index + 1).map(\.name).filter { !$0.isEmpty }.joined(separator: "/")
        }.flatMap { $0.isEmpty ? nil : $0 }
        let rawPassword = frame.fields["Password V2"] ?? frame.fields["Password"]
        let password = rawPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential: ExternalImportedCredential?
        if let password, password.isEmpty == false, password.hasPrefix("02:") == false {
            credential = .password(password)
        } else {
            credential = nil
            if password?.isEmpty == false { warnings.append("\(frame.name) 的 SecureCRT 加密密码无法直接迁移") }
        }
        sessions.append(
            ExternalImportedSession(
                name: frame.name.isEmpty ? host : frame.name,
                folderPath: folder,
                protocolName: "ssh",
                host: host,
                port: UInt16(frame.fields["[SSH2] Port"] ?? frame.fields["Port"] ?? "") ?? 22,
                username: frame.fields["Username"].flatMap { $0.isEmpty ? nil : $0 },
                privateKeyPath: frame.fields["Identity Filename V2"].flatMap { $0.isEmpty ? nil : $0 },
                credential: credential
            )
        )
    }
}
