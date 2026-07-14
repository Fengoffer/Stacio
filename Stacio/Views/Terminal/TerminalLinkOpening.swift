import AppKit
import Foundation

@MainActor
public protocol TerminalLinkOpening: AnyObject {
    func openTerminalLink(_ url: URL)
}

@MainActor
public final class WorkspaceTerminalLinkOpener: TerminalLinkOpening {
    public static let shared = WorkspaceTerminalLinkOpener()

    public init() {}

    public func openTerminalLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
