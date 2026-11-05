import Foundation
import XCTest
import ZIPFoundation
@testable import StacioApp

final class BastionHostSessionImportResolverTests: XCTestCase {
    func testRegistryUsesHighestConfidenceAdapterAndPreservesRegistrationOrderForTies() throws {
        let low = StubBastionConfigurationAdapter(vendor: .sangfor, score: 20, sessionName: "low")
        let firstHigh = StubBastionConfigurationAdapter(vendor: .topsec, score: 90, sessionName: "first")
        let secondHigh = StubBastionConfigurationAdapter(vendor: .qianxin, score: 90, sessionName: "second")
        let registry = BastionConfigurationAdapterRegistry(adapters: [low, firstHigh, secondHigh])

        let payload = try XCTUnwrap(registry.automaticallyParse(file: importFile()))

        XCTAssertEqual(payload.sessions.map(\.name), ["first"])
    }

    func testRegistryContinuesToLowerConfidenceAdapterAfterPreferredCandidateRejects() throws {
        let rejecting = StubBastionConfigurationAdapter(
            vendor: .topsec,
            score: 100,
            sessionName: "unused",
            parseError: ExternalSessionImportParserError.invalidFormat
        )
        let fallback = StubBastionConfigurationAdapter(
            vendor: .sangfor,
            score: 60,
            sessionName: "fallback"
        )
        let registry = BastionConfigurationAdapterRegistry(adapters: [rejecting, fallback])

        let payload = try XCTUnwrap(registry.automaticallyParse(file: importFile()))

        XCTAssertEqual(payload.sessions.map(\.name), ["fallback"])
    }

    func testManualVendorSelectionUsesOnlyTheMatchingRegisteredAdapter() throws {
        let selected = StubBastionConfigurationAdapter(vendor: .sangfor, score: 60, sessionName: "selected")
        let other = StubBastionConfigurationAdapter(vendor: .topsec, score: 100, sessionName: "other")
        let resolver = DefaultBastionHostSessionImportResolver(
            adapterRegistry: BastionConfigurationAdapterRegistry(adapters: [other, selected])
        )

        let payload = try resolver.resolve(file: importFile(), vendorHint: .sangfor)

        XCTAssertEqual(payload.sessions.map(\.name), ["selected"])
    }

    func testManualVendorSelectionRejectsRegisteredAdapterWithNoConfidence() {
        let selected = StubBastionConfigurationAdapter(
            vendor: .topsec,
            score: 0,
            sessionName: "unused"
        )
        let resolver = DefaultBastionHostSessionImportResolver(
            adapterRegistry: BastionConfigurationAdapterRegistry(adapters: [selected])
        )

        XCTAssertThrowsError(try resolver.resolve(file: importFile(), vendorHint: .topsec)) { error in
            XCTAssertEqual(error as? ExternalSessionImportParserError, .invalidFormat)
        }
    }

    func testManualVendorSelectionDoesNotBypassARegisteredAdapterThatRejectsTheFormat() {
        let selected = StubBastionConfigurationAdapter(
            vendor: .topsec,
            score: 100,
            sessionName: "unused",
            canParseFile: false
        )
        let resolver = DefaultBastionHostSessionImportResolver(
            adapterRegistry: BastionConfigurationAdapterRegistry(adapters: [selected])
        )
        let file = SessionImportFile(
            sourceName: "generic.xsh",
            sourceType: .bastionHost,
            contents: """
            [CONNECTION]
            Host=server.example.com
            Port=22
            Protocol=SSH
            [CONNECTION:AUTHENTICATION]
            UserName=deploy
            """
        )

        XCTAssertThrowsError(try resolver.resolve(file: file, vendorHint: .topsec)) { error in
            XCTAssertEqual(error as? ExternalSessionImportParserError, .invalidFormat)
        }
    }

    func testDefaultRegistryKeepsTopsecAsTheOnlyVendorSpecificParserUntilFixturesExist() {
        XCTAssertEqual(BastionConfigurationAdapterRegistry.default.adapters.map { $0.vendor }, [.topsec])
    }

    func testResolverFallsBackToGenericParsingWhenARecognizedAdapterRejectsTheFile() throws {
        let rejecting = StubBastionConfigurationAdapter(
            vendor: .topsec,
            score: 100,
            sessionName: "unused",
            parseError: ExternalSessionImportParserError.invalidFormat
        )
        let resolver = DefaultBastionHostSessionImportResolver(
            adapterRegistry: BastionConfigurationAdapterRegistry(adapters: [rejecting])
        )
        let file = SessionImportFile(
            sourceName: "generic.xsh",
            sourceType: .bastionHost,
            contents: """
            [CONNECTION]
            Host=server.example.com
            Port=2222
            Protocol=SSH
            [CONNECTION:AUTHENTICATION]
            UserName=deploy
            """
        )

        let payload = try resolver.resolve(file: file, vendorHint: nil)

        let session = try XCTUnwrap(payload.sessions.first)
        XCTAssertEqual(session.host, "server.example.com")
        XCTAssertEqual(session.port, 2222)
        XCTAssertEqual(session.username, "deploy")
    }

    func testResolverNormalizesAdapterFailuresSoTheManualVendorFallbackCanRun() {
        let rejecting = StubBastionConfigurationAdapter(
            vendor: .topsec,
            score: 100,
            sessionName: "unused",
            parseError: StubAdapterError.rejected
        )
        let resolver = DefaultBastionHostSessionImportResolver(
            adapterRegistry: BastionConfigurationAdapterRegistry(adapters: [rejecting])
        )

        XCTAssertThrowsError(try resolver.resolve(file: importFile(), vendorHint: nil)) { error in
            XCTAssertEqual(error as? ExternalSessionImportParserError, .invalidFormat)
        }
    }

    func testResolverFallsBackToGenericXshellArchiveWhenTopsecAdapterRejectsIt() throws {
        let archiveURL = try makeArchive(
            entries: [
                "Servers/production.xsh": Data(
                    """
                    [CONNECTION]
                    Host=server.example.com
                    Port=2222
                    Protocol=SSH
                    [CONNECTION:AUTHENTICATION]
                    UserName=deploy
                    """.utf8
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let file = SessionImportFile(
            sourceName: archiveURL.lastPathComponent,
            sourceType: .bastionHost,
            contents: "",
            sourceURL: archiveURL
        )

        let payload = try DefaultBastionHostSessionImportResolver().resolve(
            file: file,
            vendorHint: nil
        )

        let session = try XCTUnwrap(payload.sessions.first)
        XCTAssertEqual(session.host, "server.example.com")
        XCTAssertEqual(session.port, 2222)
        XCTAssertEqual(session.username, "deploy")
    }

    func testGenericArchiveNameCannotForgeTopsecVendorMetadata() throws {
        let archiveURL = try makeArchive(
            entries: [
                "Servers/production.xsh": Data(
                    """
                    [CONNECTION]
                    Host=server.example.com
                    Port=22
                    Protocol=SSH
                    [CONNECTION:AUTHENTICATION]
                    UserName=deploy
                    """.utf8
                )
            ],
            filename: "topsec-backup.zip"
        )
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let file = SessionImportFile(
            sourceName: archiveURL.lastPathComponent,
            sourceType: .bastionHost,
            contents: "",
            sourceURL: archiveURL
        )

        let payload = try DefaultBastionHostSessionImportResolver().resolve(
            file: file,
            vendorHint: nil
        )

        XCTAssertNil(try XCTUnwrap(payload.sessions.first).configJSON)
    }

    func testResolverFallsBackToGenericSecureCRTArchiveWhenTopsecAdapterRejectsIt() throws {
        let archiveURL = try makeArchive(
            entries: [
                "Servers/production.ini": Data(
                    """
                    D:"Is Session"=00000001
                    S:"Protocol Name"=SSH2
                    S:"Hostname"=server.example.com
                    S:"Username"=deploy
                    D:"[SSH2] Port"=000008AE
                    """.utf8
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let file = SessionImportFile(
            sourceName: archiveURL.lastPathComponent,
            sourceType: .bastionHost,
            contents: "",
            sourceURL: archiveURL
        )

        let payload = try DefaultBastionHostSessionImportResolver().resolve(
            file: file,
            vendorHint: nil
        )

        let session = try XCTUnwrap(payload.sessions.first)
        XCTAssertEqual(session.host, "server.example.com")
        XCTAssertEqual(session.port, 2222)
        XCTAssertEqual(session.username, "deploy")
    }

    func testGenericArchiveRejectsCumulativeConfigurationBytesBeyondLimit() throws {
        let oversizedConfiguration = Data(repeating: 0x41, count: 12 * 1_024 * 1_024)
        let archiveURL = try makeArchive(entries: [
            "Servers/one.xsh": oversizedConfiguration,
            "Servers/two.xsh": oversizedConfiguration,
            "Servers/three.xsh": oversizedConfiguration
        ])
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        XCTAssertThrowsError(try TopsecSessionImportParser.parseGenericClientArchive(at: archiveURL)) { error in
            XCTAssertEqual(error as? ExternalSessionImportParserError, .invalidFormat)
        }
    }

    func testGenericArchiveRejectsMoreThanMaximumConfigurationFileCount() throws {
        let entries = Dictionary(uniqueKeysWithValues: (0...256).map { index in
            ("Servers/session-\(index).xsh", Data("not-a-session".utf8))
        })
        let archiveURL = try makeArchive(entries: entries)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        XCTAssertThrowsError(try TopsecSessionImportParser.parseGenericClientArchive(at: archiveURL)) { error in
            XCTAssertEqual(error as? ExternalSessionImportParserError, .invalidFormat)
        }
    }

    private func importFile() -> SessionImportFile {
        SessionImportFile(
            sourceName: "vendor-export.dat",
            sourceType: .bastionHost,
            contents: "vendor fixture"
        )
    }

    private func makeArchive(
        entries: [String: Data],
        filename: String = "\(UUID().uuidString).zip"
    ) throws -> URL {
        let archive = try Archive(accessMode: .create)
        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<(Int(position) + size))
                }
            )
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        try XCTUnwrap(archive.data).write(to: url)
        return url
    }
}

private struct StubBastionConfigurationAdapter: BastionConfigurationAdapter {
    let vendor: BastionHostVendor
    let score: Int
    let sessionName: String
    let canParseFile: Bool
    let parseError: Error?

    init(
        vendor: BastionHostVendor,
        score: Int,
        sessionName: String,
        canParseFile: Bool = true,
        parseError: Error? = nil
    ) {
        self.vendor = vendor
        self.score = score
        self.sessionName = sessionName
        self.canParseFile = canParseFile
        self.parseError = parseError
    }

    func canParse(file: SessionImportFile) -> Bool {
        canParseFile
    }

    func confidence(for file: SessionImportFile) -> Int {
        score
    }

    func parse(file: SessionImportFile) throws -> ExternalSessionImportPayload {
        if let parseError {
            throw parseError
        }
        return ExternalSessionImportPayload(
            sessions: [
                ExternalImportedSession(
                    name: sessionName,
                    folderPath: nil,
                    protocolName: "ssh",
                    host: "bastion.example.com",
                    port: 22,
                    username: "ops",
                    privateKeyPath: nil,
                    credential: nil
                )
            ],
            warnings: []
        )
    }
}

private enum StubAdapterError: Error {
    case rejected
}
