import AppKit
import StacioCoreBindings

enum RemoteFileDragPayload {
    static let pasteboardType = NSPasteboard.PasteboardType("cn.stacio.remote-file-selection")

    static func pasteboardItem(
        for selection: RemoteFileSelection,
        sourceRuntimeID: String? = nil
    ) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        var values: [String: Any] = [
            "path": selection.path,
            "size": NSNumber(value: selection.size),
            "kind": kindString(selection.kind)
        ]
        // NSPasteboard property lists cannot contain Optional.some/none wrappers.
        if let modifiedTime = selection.modifiedTime {
            values["modifiedTime"] = modifiedTime
        }
        if let sourceRuntimeID,
           sourceRuntimeID.isEmpty == false {
            values["sourceRuntimeID"] = sourceRuntimeID
        }
        item.setPropertyList(values, forType: pasteboardType)
        return item
    }

    static func sourceRuntimeID(from pasteboard: NSPasteboard) -> String? {
        pasteboard.pasteboardItems?.compactMap { item in
            guard let values = item.propertyList(forType: pasteboardType) as? [String: Any],
                  let sourceRuntimeID = values["sourceRuntimeID"] as? String,
                  sourceRuntimeID.isEmpty == false
            else { return nil }
            return sourceRuntimeID
        }.first
    }

    static func selections(from pasteboard: NSPasteboard) -> [RemoteFileSelection] {
        pasteboard.pasteboardItems?.compactMap { item in
            guard let values = item.propertyList(forType: pasteboardType) as? [String: Any],
                  let path = values["path"] as? String,
                  let sizeNumber = values["size"] as? NSNumber,
                  let kindValue = values["kind"] as? String
            else {
                return nil
            }
            let kind: RemoteFileKind
            switch kindValue {
            case "directory":
                kind = .directory
            case "symlink":
                kind = .symlink
            default:
                kind = .file
            }
            return RemoteFileSelection(
                path: path,
                size: sizeNumber.uint64Value,
                kind: kind,
                modifiedTime: values["modifiedTime"] as? String
            )
        } ?? []
    }

    private static func kindString(_ kind: RemoteFileKind) -> String {
        switch kind {
        case .file:
            return "file"
        case .directory:
            return "directory"
        case .symlink:
            return "symlink"
        }
    }
}
