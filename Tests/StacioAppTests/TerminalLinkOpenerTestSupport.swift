import Foundation
@testable import StacioApp

@MainActor
final class RecordingTerminalLinkOpener: TerminalLinkOpening {
    private(set) var openedURLs: [URL] = []

    func openTerminalLink(_ url: URL) {
        openedURLs.append(url)
    }
}
