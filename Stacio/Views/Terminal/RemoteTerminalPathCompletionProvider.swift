import Foundation
import StacioCoreBindings

public final class RemoteTerminalPathCompletionProvider: TerminalPathCompletionProviding {
    public var onCandidatesUpdated: (() -> Void)?

    private let bridge: RemoteFilesBridging
    private let liveSessionContextProvider: () -> TunnelLiveSessionContext?
    private let currentDirectoryProvider: () -> String
    private let queue = DispatchQueue(label: "Stacio.RemoteTerminalPathCompletionProvider", qos: .userInitiated)
    private let lock = NSLock()
    private var cachedCandidatesByPath: [String: [TerminalPathCompletionCandidate]] = [:]
    private var inFlightPaths: Set<String> = []

    public init(
        bridge: RemoteFilesBridging = CoreBridgeRemoteFilesBridge(),
        liveSessionContextProvider: @escaping () -> TunnelLiveSessionContext?,
        currentDirectoryProvider: @escaping () -> String
    ) {
        self.bridge = bridge
        self.liveSessionContextProvider = liveSessionContextProvider
        self.currentDirectoryProvider = currentDirectoryProvider
    }

    public func candidates(for request: TerminalPathCompletionRequest) throws -> [TerminalPathCompletionCandidate] {
        let remotePath = resolvedRemotePath(for: request.parentPath)
        if let cached = cachedCandidates(for: remotePath) {
            return Self.filtered(cached, prefix: request.namePrefix)
        }
        refresh(remotePath: remotePath)
        return []
    }

    public func warm(parentPath: String) {
        refresh(remotePath: resolvedRemotePath(for: parentPath))
    }

    private func refresh(remotePath: String) {
        guard let context = liveSessionContextProvider(),
              markRefreshInFlight(remotePath)
        else {
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let candidates: [TerminalPathCompletionCandidate]
            do {
                let entries = try bridge.listLiveRemoteDirectory(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256,
                    remotePath: remotePath
                )
                candidates = Self.candidates(from: entries)
            } catch {
                candidates = []
            }
            self.store(candidates, for: remotePath)
            DispatchQueue.main.async { [weak self] in
                self?.onCandidatesUpdated?()
            }
        }
    }

    private func resolvedRemotePath(for parentPath: String) -> String {
        let path = parentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == "." {
            return currentDirectoryProvider()
        }
        if path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") {
            return path
        }
        let base = currentDirectoryProvider()
        if base.isEmpty || base == "~" {
            return "~/\(path)"
        }
        if base.hasSuffix("/") {
            return base + path
        }
        return base + "/" + path
    }

    private func cachedCandidates(for remotePath: String) -> [TerminalPathCompletionCandidate]? {
        lock.lock()
        defer { lock.unlock() }
        return cachedCandidatesByPath[remotePath]
    }

    private func markRefreshInFlight(_ remotePath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlightPaths.contains(remotePath) == false else {
            return false
        }
        inFlightPaths.insert(remotePath)
        return true
    }

    private func store(_ candidates: [TerminalPathCompletionCandidate], for remotePath: String) {
        lock.lock()
        cachedCandidatesByPath[remotePath] = candidates
        inFlightPaths.remove(remotePath)
        lock.unlock()
    }

    private static func candidates(from entries: [RemoteFileEntry]) -> [TerminalPathCompletionCandidate] {
        entries.compactMap { entry in
            let name = lastPathComponent(entry.path)
            guard name.isEmpty == false,
                  name != ".",
                  name != ".."
            else {
                return nil
            }
            return TerminalPathCompletionCandidate(
                name: name,
                isDirectory: entry.kind == .directory
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func filtered(
        _ candidates: [TerminalPathCompletionCandidate],
        prefix: String
    ) -> [TerminalPathCompletionCandidate] {
        candidates.filter {
            $0.name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
                && $0.name.caseInsensitiveCompare(prefix) != .orderedSame
        }
    }

    private static func lastPathComponent(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmed.isEmpty == false else {
            return path == "/" ? "/" : ""
        }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
