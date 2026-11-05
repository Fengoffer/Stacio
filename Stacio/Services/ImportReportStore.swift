import StacioCoreBindings

public protocol ImportReportListing {
    func listImportReports(limit: UInt32) throws -> [ImportReport]
}

public struct CoreBridgeImportReportStore: ImportReportListing {
    private let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public func listImportReports(limit: UInt32) throws -> [ImportReport] {
        guard limit > 0 else {
            return []
        }

        let reports = try CoreBridge.listImportReports(databasePath: databasePath)
        return Array(reports.sorted { $0.createdAt > $1.createdAt }.prefix(Int(limit)))
    }
}
