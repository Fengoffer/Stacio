import Foundation

public enum BundledRuntimeCatalogError: Error, Equatable {
    case missingManifest
    case unreadableResource(String)
    case invalidManifest
    case validation(CatalogSetError)
}

public protocol RuntimeCatalogProviding: AnyObject {
    var catalogSet: RuntimeCatalogSet? { get }
    var loadError: BundledRuntimeCatalogError? { get }
}

/// Loads one immutable, hash-verified catalog snapshot from the app bundle.
/// Configuration editors copy suggestions out of this snapshot and never retain
/// mutable descriptor objects, so a later app update cannot overwrite user data.
public final class BundledRuntimeCatalog: RuntimeCatalogProviding, @unchecked Sendable {
    public static let shared: BundledRuntimeCatalog = {
        // SwiftPM's generated Bundle.module accessor falls back to an absolute
        // .build path when its resource bundle is absent. A packaged app must
        // never depend on the developer machine, so production resources live
        // in Contents/Resources/RuntimeCatalog and are loaded from Bundle.main.
        if Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            return BundledRuntimeCatalog(bundle: .main)
        }
        // 仅 Debug 构建允许回退到 SwiftPM 资源包；Release 构建里
        // StacioPackageResources.moduleBundle 恒为 nil，因此绝不会引用
        // 会写入 .build 绝对路径的 Bundle.module 访问器。
        guard let moduleBundle = StacioPackageResources.moduleBundle else {
            return BundledRuntimeCatalog(bundle: .main)
        }
        return BundledRuntimeCatalog(bundle: moduleBundle)
    }()

    public let catalogSet: RuntimeCatalogSet?
    public let evidence: CatalogValidationEvidence?
    public let loadError: BundledRuntimeCatalogError?

    public init(bundle: Bundle) {
        do {
            let loaded = try Self.load(bundle: bundle)
            catalogSet = loaded.set
            evidence = loaded.evidence
            loadError = nil
        } catch let error as BundledRuntimeCatalogError {
            catalogSet = nil
            evidence = nil
            loadError = error
        } catch {
            catalogSet = nil
            evidence = nil
            loadError = .invalidManifest
        }
    }

    public init(set: RuntimeCatalogSet) {
        catalogSet = set
        evidence = nil
        loadError = nil
    }

    public func provider(catalogID: String?) -> ProviderCatalogEntry? {
        catalogSet?.provider(catalogID: catalogID)
    }

    public func providersForCreation() -> [ProviderCatalogEntry] {
        catalogSet?.providers.filter {
            $0.tombstone == nil && $0.supportLevel != .unsupported
        } ?? []
    }

    public func codingPlansForCreation() -> [CodingPlanCatalogEntry] {
        catalogSet?.codingPlans.filter {
            $0.tombstone == nil && $0.supportLevel != .unsupported
        } ?? []
    }

    public func localAgent(catalogID: String?) -> LocalAgentCatalogEntry? {
        catalogSet?.localAgent(catalogID: catalogID)
    }

    public func localAgent(rawIdentity: String?) -> LocalAgentCatalogEntry? {
        catalogSet?.localAgent(rawIdentity: rawIdentity)
    }

    public func localAgentsForCreation() -> [LocalAgentCatalogEntry] {
        catalogSet?.localAgents.filter(\.isExecutableCandidate) ?? []
    }

    public var toolCatalog: StacioToolCatalog? {
        catalogSet?.toolCatalog
    }

    public func nativeRuntimeEntry(catalogID: String?) -> NativeRuntimeCatalogEntry? {
        catalogSet?.nativeRuntimeEntry(catalogID: catalogID)
    }

    public func nativeRuntimeEntriesForCreation() -> [NativeRuntimeCatalogEntry] {
        let providers = providersForCreation().map(NativeRuntimeCatalogEntry.provider)
        let plans = codingPlansForCreation().map(NativeRuntimeCatalogEntry.codingPlan)
        return (providers + plans).filter(\.isExecutableByNativeRuntime)
    }

    public func websiteActions(ownerCatalogID: String?) -> [WebsiteActionEntry] {
        guard let ownerCatalogID else { return [] }
        return catalogSet?.websiteActions(ownerCatalogID: ownerCatalogID) ?? []
    }

    public func primaryWebsiteAction(ownerCatalogID: String?) -> WebsiteActionEntry? {
        guard let ownerCatalogID else { return nil }
        return catalogSet?.primaryWebsiteAction(ownerCatalogID: ownerCatalogID)
    }

    public func provider(legacyProfileRawValue: String, baseURL: String? = nil) -> ProviderCatalogEntry? {
        let candidates = providersForCreation().filter {
            $0.legacyProfileRawValue?.caseInsensitiveCompare(legacyProfileRawValue) == .orderedSame
        }
        guard let baseURL else { return candidates.first }
        let normalized = Self.normalizedURLString(baseURL)
        return candidates.first {
            Self.normalizedURLString($0.suggestedBaseURL) == normalized
        } ?? candidates.first
    }

    private static func load(bundle: Bundle) throws -> (
        set: RuntimeCatalogSet,
        evidence: CatalogValidationEvidence
    ) {
        guard let manifestURL = resourceURL(
            relativePath: "runtime-catalog-manifest-v1.json",
            bundle: bundle
        ) else {
            throw BundledRuntimeCatalogError.missingManifest
        }
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RuntimeCatalogManifest.self, from: manifestData)
        else {
            throw BundledRuntimeCatalogError.invalidManifest
        }

        var resources: [String: Data] = [:]
        for descriptor in manifest.resources {
            guard let url = resourceURL(relativePath: descriptor.relativePath, bundle: bundle),
                  let data = try? Data(contentsOf: url)
            else {
                throw BundledRuntimeCatalogError.unreadableResource(descriptor.relativePath)
            }
            resources[descriptor.relativePath] = data
        }

        switch RuntimeCatalogSetLoader.load(
            manifest: manifest,
            resources: resources,
            previouslyPublishedCatalogIDs: [],
            currentAppVersion: currentApplicationVersion()
        ) {
        case .success(let loaded):
            return loaded
        case .failure(let error):
            throw BundledRuntimeCatalogError.validation(error)
        }
    }

    private static func resourceURL(relativePath: String, bundle: Bundle) -> URL? {
        let path = relativePath as NSString
        let name = path.deletingPathExtension
        let ext = path.pathExtension
        return bundle.url(forResource: name, withExtension: ext, subdirectory: "RuntimeCatalog")
            ?? bundle.url(forResource: name, withExtension: ext)
    }

    private static func currentApplicationVersion() -> String? {
        // XCTest and command-line hosts have their own unrelated bundle version.
        // Only the actual application bundle is authoritative for catalog gating.
        guard Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return nil
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private static func normalizedURLString(_ value: String?) -> String? {
        guard let value,
              let url = OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: value)
        else {
            return nil
        }
        return url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
