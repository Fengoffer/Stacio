import AppKit

enum LocalFileDropHandler {
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    static func register(_ view: NSView) {
        view.registerForDraggedTypes(draggedTypes)
    }

    static func operation(for pasteboard: NSPasteboard) -> NSDragOperation {
        localFilePaths(from: pasteboard).isEmpty ? [] : .copy
    }

    static func performDrop(from sender: NSDraggingInfo, handler: ([String]) -> Void) -> Bool {
        let paths = localFilePaths(from: sender.draggingPasteboard)
        guard paths.isEmpty == false else {
            return false
        }
        handler(paths)
        return true
    }

    static func localFilePaths(from pasteboard: NSPasteboard) -> [String] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ])?
            .compactMap { ($0 as? URL)?.path } ?? []
    }
}
