import Foundation
import WebKit

public final class RemoteFileOnlineMediaRegistry {
    public static let shared = RemoteFileOnlineMediaRegistry()
    public static let scheme = "stacio-remote-media"

    private let lock = NSLock()
    private var sources: [String: RemoteFileOnlineMediaSource] = [:]

    private init() {}

    public func register(
        fileName: String,
        mimeType: String,
        byteCount: UInt64,
        reader: @escaping @Sendable (_ offset: UInt64, _ length: UInt64?) throws -> Data
    ) -> URL {
        let token = UUID().uuidString
        lock.lock()
        sources[token] = RemoteFileOnlineMediaSource(
            token: token,
            fileName: fileName,
            mimeType: mimeType,
            byteCount: byteCount,
            reader: reader
        )
        lock.unlock()
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = token
        let encodedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        components.percentEncodedPath = "/" + encodedFileName
        if let url = components.url {
            return url
        }

        var fallbackComponents = URLComponents()
        fallbackComponents.scheme = Self.scheme
        fallbackComponents.host = token
        fallbackComponents.path = "/media"
        if let url = fallbackComponents.url {
            return url
        }
        return URL(fileURLWithPath: "/stacio-remote-media/\(token)")
    }

    func source(for url: URL) -> RemoteFileOnlineMediaSource? {
        guard url.scheme == Self.scheme,
              let token = url.host,
              token.isEmpty == false
        else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return sources[token]
    }
}

struct RemoteFileOnlineMediaSource: @unchecked Sendable {
    let token: String
    let fileName: String
    let mimeType: String
    let byteCount: UInt64
    let reader: @Sendable (_ offset: UInt64, _ length: UInt64?) throws -> Data
}

public final class RemoteFileOnlineMediaSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let shared = RemoteFileOnlineMediaSchemeHandler(registry: .shared)

    private let registry: RemoteFileOnlineMediaRegistry
    private let queue = DispatchQueue(label: "Stacio.RemoteMediaScheme", qos: .userInitiated, attributes: .concurrent)
    private let activeTasksLock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()

    init(registry: RemoteFileOnlineMediaRegistry) {
        self.registry = registry
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let source = registry.source(for: url)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        markTaskActive(urlSchemeTask)
        let requestedRange = Self.byteRange(
            from: urlSchemeTask.request.value(forHTTPHeaderField: "Range"),
            sourceByteCount: source.byteCount
        )
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.markTaskFinished(urlSchemeTask)
            }
            do {
                let offset = requestedRange?.offset ?? 0
                guard offset < source.byteCount || source.byteCount == 0 else {
                    guard self.isTaskActive(urlSchemeTask) else { return }
                    urlSchemeTask.didReceive(Self.unsatisfiableRangeResponse(for: url, source: source))
                    urlSchemeTask.didFinish()
                    return
                }
                let length = requestedRange?.length
                let data = try source.reader(offset, length)
                let response = Self.response(
                    for: url,
                    source: source,
                    offset: offset,
                    byteCount: UInt64(data.count),
                    isPartial: requestedRange != nil
                )
                guard self.isTaskActive(urlSchemeTask) else { return }
                urlSchemeTask.didReceive(response)
                guard self.isTaskActive(urlSchemeTask) else { return }
                urlSchemeTask.didReceive(data)
                guard self.isTaskActive(urlSchemeTask) else { return }
                urlSchemeTask.didFinish()
            } catch {
                guard self.isTaskActive(urlSchemeTask) else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        markTaskFinished(urlSchemeTask)
    }

    private func markTaskActive(_ task: WKURLSchemeTask) {
        activeTasksLock.lock()
        activeTasks.insert(ObjectIdentifier(task))
        activeTasksLock.unlock()
    }

    private func markTaskFinished(_ task: WKURLSchemeTask) {
        activeTasksLock.lock()
        activeTasks.remove(ObjectIdentifier(task))
        activeTasksLock.unlock()
    }

    private func isTaskActive(_ task: WKURLSchemeTask) -> Bool {
        activeTasksLock.lock()
        defer { activeTasksLock.unlock() }
        return activeTasks.contains(ObjectIdentifier(task))
    }

    private static func response(
        for url: URL,
        source: RemoteFileOnlineMediaSource,
        offset: UInt64,
        byteCount: UInt64,
        isPartial: Bool
    ) -> URLResponse {
        let expectedLength = expectedContentLength(source.byteCount)
        guard isPartial else {
            let headers: [String: String] = [
                "Content-Type": source.mimeType,
                "Content-Length": String(source.byteCount),
                "Accept-Ranges": "bytes"
            ]
            return HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) ?? URLResponse(
                url: url,
                mimeType: source.mimeType,
                expectedContentLength: expectedLength,
                textEncodingName: nil
            )
        }

        let end = byteCount == 0 ? offset : offset + byteCount - 1
        let headers: [String: String] = [
            "Content-Type": source.mimeType,
            "Content-Length": String(byteCount),
            "Content-Range": "bytes \(offset)-\(end)/\(source.byteCount)",
            "Accept-Ranges": "bytes"
        ]
        return HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? URLResponse(
            url: url,
            mimeType: source.mimeType,
            expectedContentLength: expectedContentLength(byteCount),
            textEncodingName: nil
        )
    }

    private static func unsatisfiableRangeResponse(
        for url: URL,
        source: RemoteFileOnlineMediaSource
    ) -> URLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: 416,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes */\(source.byteCount)",
                "Accept-Ranges": "bytes"
            ]
        ) ?? URLResponse(
            url: url,
            mimeType: source.mimeType,
            expectedContentLength: 0,
            textEncodingName: nil
        )
    }

    private static func expectedContentLength(_ value: UInt64) -> Int {
        value <= UInt64(Int.max) ? Int(value) : -1
    }

    private static func byteRange(
        from header: String?,
        sourceByteCount: UInt64
    ) -> (offset: UInt64, length: UInt64?)? {
        guard let header,
              header.hasPrefix("bytes=")
        else {
            return nil
        }
        let body = header.dropFirst("bytes=".count)
        guard let separator = body.firstIndex(of: "-") else {
            return nil
        }
        let startText = body[..<separator]
        let endText = body[body.index(after: separator)...]
        if startText.isEmpty {
            guard let suffixLength = UInt64(endText),
                  suffixLength > 0
            else {
                return nil
            }
            if suffixLength >= sourceByteCount {
                return (0, sourceByteCount)
            }
            return (sourceByteCount - suffixLength, suffixLength)
        }
        guard let start = UInt64(startText) else {
            return nil
        }
        guard let end = UInt64(endText) else {
            return (start, nil)
        }
        guard end >= start else {
            return nil
        }
        return (start, end - start + 1)
    }
}
