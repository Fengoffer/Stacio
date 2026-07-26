import Foundation

public protocol BastionHostSessionImportResolving {
    func resolve(
        file: SessionImportFile,
        vendorHint: BastionHostVendor?
    ) throws -> ExternalSessionImportPayload
}

public protocol BastionConfigurationAdapter {
    var vendor: BastionHostVendor { get }
    func canParse(file: SessionImportFile) -> Bool
    func confidence(for file: SessionImportFile) -> Int
    func parse(file: SessionImportFile) throws -> ExternalSessionImportPayload
}

public extension BastionConfigurationAdapter {
    func canParse(file: SessionImportFile) -> Bool { true }
}

public struct BastionConfigurationAdapterRegistry {
    public static let `default` = BastionConfigurationAdapterRegistry(
        adapters: [TopsecBastionConfigurationAdapter()]
    )

    public let adapters: [any BastionConfigurationAdapter]

    public init(adapters: [any BastionConfigurationAdapter]) {
        var seen = Set<BastionHostVendor>()
        self.adapters = adapters.filter { seen.insert($0.vendor).inserted }
    }

    public func adapter(for vendor: BastionHostVendor) -> (any BastionConfigurationAdapter)? {
        adapters.first { $0.vendor == vendor }
    }

    public func automaticallyParse(file: SessionImportFile) throws -> ExternalSessionImportPayload? {
        typealias Candidate = (
            index: Int,
            adapter: any BastionConfigurationAdapter,
            confidence: Int
        )
        var candidates: [Candidate] = []
        for (index, adapter) in adapters.enumerated() {
            let confidence = max(0, min(100, adapter.confidence(for: file)))
            guard confidence > 0, adapter.canParse(file: file) else { continue }
            candidates.append((index: index, adapter: adapter, confidence: confidence))
        }
        candidates.sort { lhs, rhs in
            lhs.confidence == rhs.confidence
                ? lhs.index < rhs.index
                : lhs.confidence > rhs.confidence
        }
        for candidate in candidates {
            do {
                return try candidate.adapter.parse(file: file)
            } catch {
                // A confidence score only nominates a parser. Rejection must not
                // bypass lower-ranked adapters or the generic import pipeline.
                continue
            }
        }
        return nil
    }
}

public struct TopsecBastionConfigurationAdapter: BastionConfigurationAdapter {
    public let vendor: BastionHostVendor = .topsec

    public init() {}

    public func canParse(file: SessionImportFile) -> Bool {
        guard let sourceURL = file.sourceURL else { return false }
        return ["xlsx", "zip"].contains(sourceURL.pathExtension.lowercased())
    }

    public func confidence(for file: SessionImportFile) -> Int {
        let nameAndText = "\(file.sourceName)\n\(file.contents.prefix(8_192))".lowercased()
        if nameAndText.contains("topsec") || nameAndText.contains("天融信") {
            return 100
        }
        if TopsecBastionRoute.first(in: file.contents) != nil {
            return 95
        }
        guard let sourceURL = file.sourceURL,
              ["xlsx", "zip"].contains(sourceURL.pathExtension.lowercased())
        else { return 0 }
        // Binary Topsec exports do not expose a reliable marker before parsing.
        // Keep this below explicit markers so future vendor adapters can win.
        return 25
    }

    public func parse(file: SessionImportFile) throws -> ExternalSessionImportPayload {
        guard let sourceURL = file.sourceURL,
              ["xlsx", "zip"].contains(sourceURL.pathExtension.lowercased())
        else {
            throw ExternalSessionImportParserError.invalidFormat
        }
        return try TopsecSessionImportParser.parseFile(at: sourceURL)
    }
}

public struct DefaultBastionHostSessionImportResolver: BastionHostSessionImportResolving {
    private let adapterRegistry: BastionConfigurationAdapterRegistry

    public init(adapterRegistry: BastionConfigurationAdapterRegistry = .default) {
        self.adapterRegistry = adapterRegistry
    }

    public func resolve(
        file: SessionImportFile,
        vendorHint: BastionHostVendor?
    ) throws -> ExternalSessionImportPayload {
        if let vendorHint {
            if let adapter = adapterRegistry.adapter(for: vendorHint) {
                guard adapter.canParse(file: file),
                      adapter.confidence(for: file) > 0
                else {
                    throw ExternalSessionImportParserError.invalidFormat
                }
                return try adapter.parse(file: file)
            }
            let payload = try genericPayload(for: file)
            return BastionHostImportAdapter.addingVendorMetadata(
                to: payload,
                vendor: vendorHint,
                format: "vendor_selected_external_session"
            )
        }

        if let payload = try adapterRegistry.automaticallyParse(file: file) {
            return payload
        }
        if let payload = try? BastionHostImportAdapter.parseManifest(file.contents) {
            return payload
        }
        let payload = try genericPayload(for: file)
        let sourceNameForVendorDetection = file.sourceURL?.pathExtension
            .caseInsensitiveCompare("zip") == .orderedSame ? "" : file.sourceName
        return BastionHostImportAdapter.addingDetectedVendorMetadata(
            to: payload,
            sourceName: sourceNameForVendorDetection,
            contents: file.contents
        )
    }

    private func genericPayload(for file: SessionImportFile) throws -> ExternalSessionImportPayload {
        if let sourceURL = file.sourceURL, sourceURL.hasDirectoryPath {
            return try ExternalSessionImportParser.parseDirectory(
                sourceURL,
                sourceType: .xShell,
                sourceName: file.sourceName
            )
        }
        if let sourceURL = file.sourceURL,
           sourceURL.pathExtension.caseInsensitiveCompare("zip") == .orderedSame {
            return try TopsecSessionImportParser.parseGenericClientArchive(at: sourceURL)
        }
        if let payload = try? BastionHostImportAdapter.parseManifest(file.contents) {
            return payload
        }

        for sourceType in preferredSourceTypes(for: file) {
            if let payload = try? ExternalSessionImportParser.parseText(
                file.contents,
                sourceType: sourceType,
                sourceName: file.sourceName
            ) {
                return payload
            }
        }
        throw ExternalSessionImportParserError.invalidFormat
    }

    private func preferredSourceTypes(for file: SessionImportFile) -> [SessionImportSourceType] {
        switch file.sourceURL?.pathExtension.lowercased() ?? "" {
        case "xsh", "xts", "ini", "txt":
            return [.xShell, .secureCRT]
        case "xml":
            return [.secureCRT, .xShell]
        case "json":
            return [.windTerm, .electerm, .termius]
        default:
            return [.xShell, .secureCRT, .windTerm, .electerm, .termius]
        }
    }
}
