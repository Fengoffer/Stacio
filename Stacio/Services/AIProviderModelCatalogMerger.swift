import Foundation

public enum AIProviderModelCatalogMerger {
    public static func merge(
        existing: [AIProviderModelConfiguration],
        fetchedModelIDs: [String]
    ) -> [AIProviderModelConfiguration] {
        merge(
            existing: existing,
            fetchedEntries: fetchedModelIDs.map { AIModelCatalogEntry(id: $0) }
        )
    }

    public static func merge(
        existing: [AIProviderModelConfiguration],
        fetchedEntries: [AIModelCatalogEntry]
    ) -> [AIProviderModelConfiguration] {
        let fetched = normalizedEntries(fetchedEntries)
        let fetchedByID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        let fetchedSet = Set(fetchedByID.keys)
        var existingIDs = Set(existing.map(\.id))
        var merged = existing.map { model in
            var updated = model
            updated.wasReturnedByLatestCatalog = fetchedSet.contains(model.id)
            if let fetched = fetchedByID[model.id] {
                updated.capabilities.applyCatalogCapabilities(fetched.capabilities)
            }
            return updated
        }

        for entry in fetched where existingIDs.insert(entry.id).inserted {
            var model = AIProviderModelConfiguration(
                    id: entry.id,
                    isEnabled: false,
                    isManual: false,
                    wasReturnedByLatestCatalog: true
            )
            model.capabilities.applyCatalogCapabilities(entry.capabilities)
            merged.append(model)
        }
        return merged
    }

    private static func normalizedEntries(
        _ entries: [AIModelCatalogEntry]
    ) -> [AIModelCatalogEntry] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let modelID = AppSettings.normalizedAIModelName(entry.id)
            guard modelID.isEmpty == false,
                  seen.insert(modelID).inserted
            else {
                return nil
            }
            return AIModelCatalogEntry(id: modelID, capabilities: entry.capabilities)
        }
    }
}
