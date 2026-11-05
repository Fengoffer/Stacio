import AppKit

/// A table view with the same destructive-key contract used by the session
/// sidebar. Controllers decide what deleting the current selection means and
/// return `true` when the key event was consumed.
@MainActor
public class StacioDeleteKeyTableView: NSTableView {
    public var deleteSelectionHandler: (() -> Bool)?

    public override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117),
           deleteSelectionHandler?() == true {
            return
        }
        super.keyDown(with: event)
    }

    /// Match the sidebar's context-menu selection semantics: right-clicking a
    /// row adds it to an existing selection only when it is already selected;
    /// otherwise it makes that row the active selection.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let clickedRow = row(at: convert(event.locationInWindow, from: nil))
        if clickedRow >= 0, selectedRowIndexes.contains(clickedRow) == false {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        } else if clickedRow < 0 {
            deselectAll(nil)
        }
        return super.menu(for: event)
    }
}
