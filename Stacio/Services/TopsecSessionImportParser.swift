import Foundation
import ZIPFoundation

enum TopsecSessionImportParser {
    private static let maximumArchiveEntryCount = 4_096
    private static let maximumEntrySize: UInt64 = 16 * 1_024 * 1_024
    private static let maximumClientConfigurationFileCount = 256
    private static let maximumClientConfigurationBytes: UInt64 = 32 * 1_024 * 1_024

    private enum ClientArchiveLimitError: Error {
        case exceeded
    }

    static func parseFile(at url: URL) throws -> ExternalSessionImportPayload {
        do {
            let payload: ExternalSessionImportPayload
            switch url.pathExtension.lowercased() {
            case "xlsx":
                payload = try parseWorkbook(at: url)
            case "zip":
                payload = try parseClientArchive(at: url)
            default:
                throw ExternalSessionImportParserError.unsupportedSource
            }
            guard payload.sessions.isEmpty == false else {
                throw ExternalSessionImportParserError.noSessions
            }
            return payload
        } catch let error as ExternalSessionImportParserError {
            throw error
        } catch {
            throw ExternalSessionImportParserError.invalidFormat
        }
    }

    private static func parseWorkbook(at url: URL) throws -> ExternalSessionImportPayload {
        let archive = try Archive(url: url, accessMode: .read)
        let entries = try validatedEntries(in: archive)
        let sharedStrings: [String]
        if let entry = entries.first(where: { $0.path.lowercased() == "xl/sharedstrings.xml" }) {
            sharedStrings = try parseSharedStrings(try data(for: entry, in: archive))
        } else {
            sharedStrings = []
        }

        let worksheetEntries = entries
            .filter {
                let path = $0.path.lowercased()
                return path.hasPrefix("xl/worksheets/") && path.hasSuffix(".xml")
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard worksheetEntries.isEmpty == false else {
            throw ExternalSessionImportParserError.invalidFormat
        }

        var importedSessions: [ExternalImportedSession] = []
        for entry in worksheetEntries {
            let rows = try parseWorksheet(try data(for: entry, in: archive), sharedStrings: sharedStrings)
            importedSessions.append(contentsOf: sessions(from: rows))
        }
        let payload = ExternalSessionImportPayload(
            sessions: deduplicated(importedSessions),
            warnings: []
        )
        guard containsTopsecRoute(payload.sessions) else {
            throw ExternalSessionImportParserError.invalidFormat
        }
        return BastionHostImportAdapter.addingVendorMetadata(
            to: payload,
            vendor: .topsec,
            format: "topsec_xlsx"
        )
    }

    static func parseGenericClientArchive(at url: URL) throws -> ExternalSessionImportPayload {
        do {
            guard url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame else {
                throw ExternalSessionImportParserError.unsupportedSource
            }
            let result = try parseClientArchiveContents(at: url)
            guard result.payload.sessions.isEmpty == false else {
                throw ExternalSessionImportParserError.noSessions
            }
            return result.payload
        } catch let error as ExternalSessionImportParserError {
            throw error
        } catch {
            throw ExternalSessionImportParserError.invalidFormat
        }
    }

    private struct ParsedClientArchive {
        let payload: ExternalSessionImportPayload
        let extensions: Set<String>
    }

    private static func parseClientArchive(at url: URL) throws -> ExternalSessionImportPayload {
        let result = try parseClientArchiveContents(at: url)
        let payload = result.payload
        guard containsTopsecRoute(payload.sessions) else {
            throw ExternalSessionImportParserError.invalidFormat
        }
        let format: String
        if result.extensions == ["ini"] {
            format = "topsec_securecrt_zip"
        } else if result.extensions.isSubset(of: ["xsh", "xts"]) {
            format = "topsec_xshell_zip"
        } else {
            format = "topsec_client_zip"
        }
        return BastionHostImportAdapter.addingVendorMetadata(
            to: payload,
            vendor: .topsec,
            format: format
        )
    }

    private static func parseClientArchiveContents(at url: URL) throws -> ParsedClientArchive {
        let archive = try Archive(url: url, accessMode: .read)
        let entries = try validatedEntries(in: archive)
            .filter { entry in
                ["xsh", "xts", "ini"].contains(
                    URL(fileURLWithPath: entry.path).pathExtension.lowercased()
                )
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard entries.isEmpty == false else {
            throw ExternalSessionImportParserError.invalidFormat
        }
        guard entries.count <= maximumClientConfigurationFileCount else {
            throw ExternalSessionImportParserError.invalidFormat
        }
        var declaredConfigurationBytes: UInt64 = 0
        for entry in entries {
            let (nextTotal, overflow) = declaredConfigurationBytes.addingReportingOverflow(
                UInt64(entry.uncompressedSize)
            )
            guard overflow == false, nextTotal <= maximumClientConfigurationBytes else {
                throw ExternalSessionImportParserError.invalidFormat
            }
            declaredConfigurationBytes = nextTotal
        }

        var sessions: [ExternalImportedSession] = []
        var warnings: [String] = []
        var extractedConfigurationBytes: UInt64 = 0
        for entry in entries {
            do {
                let contents = try SessionImportTextDecoder.decode(
                    try data(
                        for: entry,
                        in: archive,
                        cumulativeExtractedBytes: &extractedConfigurationBytes,
                        maximumCumulativeSize: maximumClientConfigurationBytes
                    )
                )
                let pathExtension = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
                let sourceType: SessionImportSourceType = pathExtension == "ini" ? .secureCRT : .xShell
                let sourceName = sourceType == .xShell
                    ? normalizedXshellSourceName(entry.path)
                    : normalizedArchiveSourceName(entry.path)
                let payload = try ExternalSessionImportParser.parseText(
                    contents,
                    sourceType: sourceType,
                    sourceName: sourceName
                )
                sessions.append(contentsOf: payload.sessions)
                warnings.append(contentsOf: payload.warnings)
            } catch is ClientArchiveLimitError {
                throw ExternalSessionImportParserError.invalidFormat
            } catch {
                warnings.append("\(URL(fileURLWithPath: entry.path).lastPathComponent) 无法识别，已跳过。")
            }
        }
        let payload = ExternalSessionImportPayload(
            sessions: deduplicated(sessions),
            warnings: Array(Set(warnings)).sorted()
        )
        let extensions = Set(entries.map {
            URL(fileURLWithPath: $0.path).pathExtension.lowercased()
        })
        return ParsedClientArchive(payload: payload, extensions: extensions)
    }

    private static func containsTopsecRoute(_ sessions: [ExternalImportedSession]) -> Bool {
        sessions.contains { session in
            session.username.flatMap(TopsecBastionRoute.init(compositeUsername:)) != nil
        }
    }

    private static func validatedEntries(in archive: Archive) throws -> [Entry] {
        var entries: [Entry] = []
        var scannedEntryCount = 0
        entries.reserveCapacity(64)
        for entry in archive {
            scannedEntryCount += 1
            guard scannedEntryCount <= maximumArchiveEntryCount,
                  UInt64(entry.uncompressedSize) <= maximumEntrySize
            else { throw ExternalSessionImportParserError.invalidFormat }
            if entry.type == .file {
                entries.append(entry)
            }
        }
        return entries
    }

    private static func data(for entry: Entry, in archive: Archive) throws -> Data {
        guard UInt64(entry.uncompressedSize) <= maximumEntrySize else {
            throw ExternalSessionImportParserError.invalidFormat
        }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            result.append(chunk)
        }
        return result
    }

    private static func data(
        for entry: Entry,
        in archive: Archive,
        cumulativeExtractedBytes: inout UInt64,
        maximumCumulativeSize: UInt64
    ) throws -> Data {
        guard UInt64(entry.uncompressedSize) <= maximumEntrySize else {
            throw ClientArchiveLimitError.exceeded
        }
        var extractedBytes = cumulativeExtractedBytes
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            let (nextTotal, overflow) = extractedBytes.addingReportingOverflow(UInt64(chunk.count))
            let (nextEntrySize, entryOverflow) = UInt64(result.count).addingReportingOverflow(UInt64(chunk.count))
            guard overflow == false,
                  entryOverflow == false,
                  nextTotal <= maximumCumulativeSize,
                  nextEntrySize <= maximumEntrySize
            else {
                throw ClientArchiveLimitError.exceeded
            }
            extractedBytes = nextTotal
            result.append(chunk)
        }
        cumulativeExtractedBytes = extractedBytes
        return result
    }

    private static func parseSharedStrings(_ data: Data) throws -> [String] {
        let delegate = SharedStringsXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ExternalSessionImportParserError.invalidFormat }
        return delegate.values
    }

    private static func parseWorksheet(
        _ data: Data,
        sharedStrings: [String]
    ) throws -> [Int: [Int: String]] {
        let delegate = WorksheetXMLDelegate(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ExternalSessionImportParserError.invalidFormat }
        return delegate.rows
    }

    private static func sessions(from rows: [Int: [Int: String]]) -> [ExternalImportedSession] {
        let sortedRows = rows.keys.sorted()
        guard let headerRowIndex = sortedRows.first(where: { columns(in: rows[$0] ?? [:]) != nil }),
              let columnMap = columns(in: rows[headerRowIndex] ?? [:])
        else { return [] }

        return sortedRows.compactMap { rowIndex -> ExternalImportedSession? in
            guard rowIndex > headerRowIndex, let row = rows[rowIndex] else { return nil }
            guard let host = trimmed(row[columnMap.host]),
                  let username = trimmed(row[columnMap.username])
            else { return nil }
            let protocolName = columnMap.protocolColumn
                .flatMap { trimmed(row[$0]) }?
                .lowercased() ?? "ssh"
            guard ["ssh", "sftp"].contains(protocolName) else { return nil }
            let port = columnMap.port
                .flatMap { parsedPort(row[$0]) } ?? 22
            let route = TopsecBastionRoute(compositeUsername: username)
            return ExternalImportedSession(
                name: route?.targetHost ?? host,
                folderPath: nil,
                protocolName: protocolName,
                host: host,
                port: port,
                username: username,
                privateKeyPath: nil,
                credential: nil
            )
        }
    }

    private struct WorkbookColumns {
        let host: Int
        let protocolColumn: Int?
        let username: Int
        let port: Int?
    }

    private static func columns(in row: [Int: String]) -> WorkbookColumns? {
        let normalized = Dictionary(uniqueKeysWithValues: row.map { ($0.key, normalizedHeader($0.value)) })
        func column(matching aliases: Set<String>) -> Int? {
            normalized.first(where: { aliases.contains($0.value) })?.key
        }
        guard let host = column(matching: ["host", "hostname", "address", "主机", "主机地址"]),
              let username = column(matching: ["username", "user", "账号", "用户名"])
        else { return nil }
        return WorkbookColumns(
            host: host,
            protocolColumn: column(matching: ["protocol", "协议"]),
            username: username,
            port: column(matching: ["port", "端口"])
        )
    }

    private static func normalizedHeader(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func parsedPort(_ value: String?) -> UInt16? {
        guard let value = trimmed(value) else { return nil }
        if let port = UInt16(value), port > 0 { return port }
        guard let numeric = Double(value),
              numeric.rounded() == numeric,
              numeric > 0,
              numeric <= Double(UInt16.max)
        else { return nil }
        return UInt16(numeric)
    }

    private static func trimmed(_ value: String?) -> String? {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result.isEmpty ? nil : result
    }

    private static func normalizedXshellSourceName(_ path: String) -> String {
        let flattened = normalizedArchiveSourceName(path)
        let pathExtension = URL(fileURLWithPath: flattened).pathExtension
        var stem = URL(fileURLWithPath: flattened).deletingPathExtension().lastPathComponent
        let lowercasedStem = stem.lowercased()
        if lowercasedStem.hasSuffix("_6") || lowercasedStem.hasSuffix("_7") {
            stem.removeLast(2)
        }
        return pathExtension.isEmpty ? stem : "\(stem).\(pathExtension)"
    }

    private static func normalizedArchiveSourceName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "__")
    }

    private static func deduplicated(_ sessions: [ExternalImportedSession]) -> [ExternalImportedSession] {
        var seen: Set<String> = []
        return sessions.filter { session in
            let key = [
                session.protocolName.lowercased(),
                session.host.lowercased(),
                String(session.port),
                session.username?.lowercased() ?? ""
            ].joined(separator: "\u{1F}")
            return seen.insert(key).inserted
        }
    }
}

private final class SharedStringsXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var values: [String] = []
    private var isInsideItem = false
    private var isCapturingText = false
    private var currentValue = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "si" {
            isInsideItem = true
            currentValue = ""
        } else if elementName == "t", isInsideItem {
            isCapturingText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCapturingText { currentValue += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "t" {
            isCapturingText = false
        } else if elementName == "si" {
            values.append(currentValue)
            isInsideItem = false
            currentValue = ""
        }
    }
}

private final class WorksheetXMLDelegate: NSObject, XMLParserDelegate {
    private enum Capture {
        case value
        case inlineText
    }

    private let sharedStrings: [String]
    private(set) var rows: [Int: [Int: String]] = [:]
    private var currentReference: String?
    private var currentType: String?
    private var currentValue = ""
    private var currentInlineText = ""
    private var capture: Capture?

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "c":
            currentReference = attributeDict["r"]
            currentType = attributeDict["t"]
            currentValue = ""
            currentInlineText = ""
        case "v" where currentReference != nil:
            capture = .value
        case "t" where currentReference != nil:
            capture = .inlineText
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch capture {
        case .value:
            currentValue += string
        case .inlineText:
            currentInlineText += string
        case nil:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "v" || elementName == "t" {
            capture = nil
            return
        }
        guard elementName == "c",
              let reference = currentReference,
              let location = Self.location(for: reference)
        else { return }

        let value: String
        if currentType == "s",
           let index = Int(currentValue),
           sharedStrings.indices.contains(index) {
            value = sharedStrings[index]
        } else if currentType == "inlineStr" {
            value = currentInlineText
        } else {
            value = currentValue
        }
        rows[location.row, default: [:]][location.column] = value
        currentReference = nil
        currentType = nil
        currentValue = ""
        currentInlineText = ""
    }

    private static func location(for reference: String) -> (row: Int, column: Int)? {
        let letters = reference.prefix { $0.isLetter }
        let digits = reference.dropFirst(letters.count)
        guard letters.isEmpty == false,
              let row = Int(digits),
              row > 0
        else { return nil }
        var column = 0
        for scalar in letters.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            column = column * 26 + Int(scalar.value - 64)
        }
        return (row - 1, column - 1)
    }
}
