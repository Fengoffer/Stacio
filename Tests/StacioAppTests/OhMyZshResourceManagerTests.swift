import AppKit
import CryptoKit
import Darwin
import StacioCoreBindings
import XCTest
@testable import StacioApp

/// OhMyZshResourceManager 端到端测试：本地 HTTP 服务器提供 snapshot.tar.gz + manifest.json，
/// 验证 下载 → sha256 校验 → 解压安装 → 目录可被 catalog 使用 → 卸载。
final class OhMyZshResourceManagerTests: XCTestCase {
    private var server: Process?
    private var port = 0
    private var snapshotDir: String = ""
    private var installDir: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["STACIO_OMZ_TEST_SNAPSHOT_DIR"],
              FileManager.default.fileExists(atPath: dir) else {
            throw XCTSkip("未设置 STACIO_OMZ_TEST_SNAPSHOT_DIR。")
        }
        snapshotDir = dir
        installDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-resource-test-\(UUID().uuidString)", isDirectory: true)
        port = try randomAvailablePort()
    }

    override func tearDownWithError() throws {
        server?.terminate()
        if let installDir {
            try? FileManager.default.removeItem(at: installDir)
        }
    }

    private func startServer(directory: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", directory]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        server = proc
        for _ in 0..<40 {
            if (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/manifest.json")!)) != nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("本地 HTTP 服务器未就绪。")
    }

    private func randomAvailablePort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(socketFD) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw XCTSkip("无法分配端口。") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound = addr
        let g = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &len)
            }
        }
        guard g == 0 else { throw XCTSkip("无法读取端口。") }
        return Int(CFSwapInt16BigToHost(bound.sin_port))
    }

    private func makeManager() -> OhMyZshResourceManager {
        OhMyZshResourceManager(
            resourceDirectoryURL: installDir,
            baseURL: URL(string: "http://127.0.0.1:\(port)")!
        )
    }

    func testDownloadInstallCatalogAndUninstall() throws {
        try startServer(directory: snapshotDir)
        let manager = makeManager()
        let expectation = expectation(description: "download")

        manager.downloadIfNeeded { result in
            switch result {
            case .success:
                expectation.fulfill()
            case let .failure(error):
                XCTFail("下载失败: \(error)")
            }
        }
        wait(for: [expectation], timeout: 60)

        XCTAssertTrue(manager.status().isInstalled, "资源应安装完成")
        XCTAssertEqual(manager.status().installedVersion, "2026.08.1")

        let catalog = OhMyZshCatalog(directoryURL: manager.installedDirectoryURL)
        XCTAssertTrue(catalog.isAvailable)
        XCTAssertEqual(catalog.plugins().count, 355, "插件数应为 355")
        XCTAssertEqual(catalog.themes().count, 143, "主题数应为 143")

        XCTAssertNotNil(manager.nerdFontURL, "资源目录应包含 Nerd Font")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.nerdFontURL!.path))

        let store = AppSettingsStore(defaults: UserDefaults(suiteName: "test-omz-\(UUID().uuidString)")!)
        try manager.uninstall(settingsStore: store)
        XCTAssertFalse(manager.status().isInstalled, "卸载后资源应清除")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installDir.path), "资源目录应被删除")
    }

    func testManifestSHA256MismatchRejects() throws {
        let tamperedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-tampered-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tamperedDir) }
        try FileManager.default.createDirectory(at: tamperedDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: snapshotDir).appendingPathComponent("snapshot.tar.gz"),
            to: tamperedDir.appendingPathComponent("snapshot.tar.gz")
        )
        var manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: snapshotDir).appendingPathComponent("manifest.json"))
        ) as! [String: Any]
        manifest["sha256"] = String(repeating: "0", count: 64)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: tamperedDir.appendingPathComponent("manifest.json"))

        try startServer(directory: tamperedDir.path)
        let manager = makeManager()
        let expectation = expectation(description: "download-reject")

        manager.download { result in
            switch result {
            case .success:
                XCTFail("sha256 不匹配应失败")
            case let .failure(error as OhMyZshResourceError):
                XCTAssertEqual(error, .sha256Mismatch)
                expectation.fulfill()
            case let .failure(error):
                XCTFail("应报 sha256Mismatch，实际 \(error)")
            }
        }
        wait(for: [expectation], timeout: 60)
        XCTAssertFalse(manager.status().isInstalled, "校验失败时不得安装")
    }

    func testManifestSizeMismatchRejectsBeforeSha256() throws {
        let tamperedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-size-tampered-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tamperedDir) }
        try FileManager.default.createDirectory(at: tamperedDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: snapshotDir).appendingPathComponent("snapshot.tar.gz"),
            to: tamperedDir.appendingPathComponent("snapshot.tar.gz")
        )
        var manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: snapshotDir).appendingPathComponent("manifest.json"))
        ) as! [String: Any]
        manifest["sizeBytes"] = 1
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: tamperedDir.appendingPathComponent("manifest.json"))

        try startServer(directory: tamperedDir.path)
        let manager = makeManager()
        let expectation = expectation(description: "download-size-reject")

        manager.download { result in
            switch result {
            case .success:
                XCTFail("sizeBytes 不匹配应失败")
            case let .failure(error as OhMyZshResourceError):
                XCTAssertEqual(error, .sizeMismatch)
                expectation.fulfill()
            case let .failure(error):
                XCTFail("应报 sizeMismatch，实际 \(error)")
            }
        }
        wait(for: [expectation], timeout: 60)
        XCTAssertFalse(manager.status().isInstalled, "大小校验失败时不得安装")
    }

    func testDownloadIfNeededRedownloadsWhenRequiredFileMissing() throws {
        try startServer(directory: snapshotDir)
        let manager = makeManager()
        let first = expectation(description: "initial-download")
        manager.downloadIfNeeded { result in
            switch result {
            case .success:
                first.fulfill()
            case let .failure(error):
                XCTFail("首次下载失败: \(error)")
            }
        }
        wait(for: [first], timeout: 60)

        let missingFont = installDir
            .appendingPathComponent("fonts", isDirectory: true)
            .appendingPathComponent(OhMyZshResourceManager.nerdFontFileName)
        try FileManager.default.removeItem(at: missingFont)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingFont.path))

        let second = expectation(description: "redownload-after-missing-file")
        manager.downloadIfNeeded { result in
            switch result {
            case .success:
                second.fulfill()
            case let .failure(error):
                XCTFail("缺失文件后应重新下载: \(error)")
            }
        }
        wait(for: [second], timeout: 60)

        XCTAssertTrue(FileManager.default.fileExists(atPath: missingFont.path), "缺失文件应被重新补回")
        XCTAssertEqual(manager.status().installedVersion, "2026.08.1")
    }
}

// MARK: - Review 修复回归：下载路径、安装完整性、wrapper symlink 逃逸

final class OhMyZshResourceManagerSecurityTests: XCTestCase {
    private var server: Process?
    private var port = 0
    private var installDir: URL!

    override func setUpWithError() throws {
        installDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-security-test-\(UUID().uuidString)", isDirectory: true)
        port = try randomAvailablePort()
    }

    override func tearDownWithError() throws {
        server?.terminate()
        if let installDir {
            try? FileManager.default.removeItem(at: installDir)
        }
    }

    private func randomAvailablePort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(socketFD) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw XCTSkip("无法分配端口。") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound = addr
        let g = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &len)
            }
        }
        guard g == 0 else { throw XCTSkip("无法读取端口。") }
        return Int(CFSwapInt16BigToHost(bound.sin_port))
    }

    private func startServer(directory: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", directory]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        server = proc
        for _ in 0..<40 {
            if (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/manifest.json")!)) != nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("本地 HTTP 服务器未就绪。")
    }

    private func makeManager() -> OhMyZshResourceManager {
        OhMyZshResourceManager(
            resourceDirectoryURL: installDir,
            baseURL: URL(string: "http://127.0.0.1:\(port)")!
        )
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeManifest(
        in directory: URL,
        version: String = "2026.08.1",
        sizeBytes: Int64,
        sha256: String,
        downloadPath: String = "snapshot.tar.gz"
    ) throws {
        let manifest: [String: Any] = [
            "version": version,
            "sizeBytes": sizeBytes,
            "sha256": sha256,
            "downloadPath": downloadPath
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
    }

    private func makeTarball(from sourceDirectory: URL, outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", outputURL.path, "-C", sourceDirectory.path, "."]
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw NSError(
                domain: "OhMyZshResourceManagerSecurityTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr]
            )
        }
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testResolveDownloadURLRejectsUnsafePaths() {
        let baseURL = URL(string: "https://ops.stacio.cn/api/v1/public/stacio/oh-my-zsh")!
        XCTAssertEqual(
            OhMyZshResourceManager.resolveDownloadURL(baseURL: baseURL, downloadPath: "snapshot.tar.gz")?.absoluteString,
            baseURL.appendingPathComponent("snapshot.tar.gz").absoluteString
        )
        XCTAssertEqual(
            OhMyZshResourceManager.resolveDownloadURL(baseURL: baseURL, downloadPath: "nested/snapshot.tar.gz")?.absoluteString,
            baseURL.appendingPathComponent("nested").appendingPathComponent("snapshot.tar.gz").absoluteString
        )
        for unsafePath in [
            "",
            " ",
            "/etc/passwd",
            "../snapshot.tar.gz",
            "./snapshot.tar.gz",
            "snapshot.tar.gz?x=1",
            "snapshot.tar.gz#frag",
            "snapshot%2Etar.gz",
            "nested//snapshot.tar.gz",
            "nested/../snapshot.tar.gz"
        ] {
            XCTAssertNil(
                OhMyZshResourceManager.resolveDownloadURL(baseURL: baseURL, downloadPath: unsafePath),
                "应拒绝不安全 downloadPath: \(unsafePath)"
            )
        }
    }

    func testInstalledTreeDigestInvalidatesAfterContentMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-installed-tree-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile("#!/bin/zsh\n", to: root.appendingPathComponent("oh-my-zsh.sh"))
        try writeFile("git plugin\n", to: root.appendingPathComponent("plugins/git/git.plugin.zsh"))
        try writeFile("docker plugin\n", to: root.appendingPathComponent("plugins/docker/docker.plugin.zsh"))
        try writeFile("docker README\n", to: root.appendingPathComponent("plugins/docker/README.md"))
        try writeFile("robbyrussell theme\n", to: root.appendingPathComponent("themes/robbyrussell.zsh-theme"))
        try writeFile("font bytes\n", to: root.appendingPathComponent("fonts/\(OhMyZshResourceManager.nerdFontFileName)"))

        let manager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let treeHash = try manager.directoryTreeDigest(at: root)
        try "2026.08.1".write(
            to: root.appendingPathComponent(OhMyZshResourceManager.versionMarkerFileName),
            atomically: true,
            encoding: .utf8
        )
        try "deadbeef".write(
            to: root.appendingPathComponent(OhMyZshResourceManager.manifestHashMarkerFileName),
            atomically: true,
            encoding: .utf8
        )
        try treeHash.write(
            to: root.appendingPathComponent(OhMyZshResourceManager.installTreeHashMarkerFileName),
            atomically: true,
            encoding: .utf8
        )

        let initialValidation = expectation(description: "initial-installed-tree-validation")
        manager.refreshIntegrityValidation { isValid in
            XCTAssertTrue(isValid)
            initialValidation.fulfill()
        }
        wait(for: [initialValidation], timeout: 10)
        XCTAssertEqual(manager.status().installedVersion, "2026.08.1")
        XCTAssertEqual(manager.installedDirectoryURL, root)
        let catalog = OhMyZshCatalog(directoryURL: manager.installedDirectoryURL)
        XCTAssertEqual(catalog.plugins().map(\.name).sorted(), ["docker", "git"])

        try writeFile("mutated docker readme\n", to: root.appendingPathComponent("plugins/docker/README.md"))

        let tamperValidation = expectation(description: "tampered-installed-tree-validation")
        manager.refreshIntegrityValidation { isValid in
            XCTAssertFalse(isValid)
            tamperValidation.fulfill()
        }
        wait(for: [tamperValidation], timeout: 10)
        XCTAssertNil(manager.status().installedVersion, "目录内容变化后应失去已安装状态")
        XCTAssertNil(manager.installedDirectoryURL, "完整性校验失败后不应再复用目录")
    }

    func testDownloadRejectsWrapperSymlinkEscape() throws {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-symlink-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let payloadRoot = sourceDir.appendingPathComponent("payload", isDirectory: true)
        let wrapperRoot = payloadRoot.appendingPathComponent("wrapper", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: wrapperRoot.appendingPathComponent("link").path,
            withDestinationPath: "../outside"
        )

        let tarball = sourceDir.appendingPathComponent("snapshot.tar.gz")
        try makeTarball(from: payloadRoot, outputURL: tarball)
        let sha = try sha256(of: tarball)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: tarball.path)[.size] as? NSNumber
        )
        try writeManifest(
            in: sourceDir,
            sizeBytes: size.int64Value,
            sha256: sha
        )

        try startServer(directory: sourceDir.path)
        let manager = makeManager()
        let expectation = expectation(description: "unsafe-symlink-reject")

        manager.download { result in
            switch result {
            case .success:
                XCTFail("wrapper 内的 ../outside symlink 应拒绝安装")
            case let .failure(error as OhMyZshResourceError):
                XCTAssertEqual(error, .unsafeArchiveMember)
                expectation.fulfill()
            case let .failure(error):
                XCTFail("应报 unsafeArchiveMember，实际 \(error)")
            }
        }

        wait(for: [expectation], timeout: 60)
        XCTAssertNil(manager.installedDirectoryURL)
    }
}

// MARK: - Integrity cache, legacy migration, and font registration

private final class OhMyZshDownloadGateURLProtocol: URLProtocol {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func reset() {
            lock.lock()
            paths.removeAll()
            lock.unlock()
        }

        func record(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }

        var recordedPaths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    private static let state = State()

    static func reset() {
        state.reset()
    }

    static var recordedPaths: [String] {
        state.recordedPaths
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "ohmyzsh-download-gate.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.state.record(url.path)
        if url.lastPathComponent == "manifest.json" {
            let manifest = """
            {"version":"2026.08.1","sizeBytes":1,"sha256":"\(String(repeating: "0", count: 64))","downloadPath":"snapshot.tar.gz"}
            """
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(manifest.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            // Reaching the snapshot request proves download(manifest:) started after the
            // validation gate became idle. No network or archive fixture is needed here.
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }

    override func stopLoading() {}
}

private final class ImmediateOhMyZshDataTask: URLSessionDataTask, @unchecked Sendable {
    override func resume() {}
}

private final class ImmediateOhMyZshDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    override func resume() {}
}

private final class ImmediateOhMyZshManifestSession: URLSession, @unchecked Sendable {
    private let manifestPayloads: [Data]
    private let condition = NSCondition()
    private var nextManifestIndex = 0
    private var downloadCompletions: [@Sendable (URL?, URLResponse?, Error?) -> Void] = []
    private var downloadURLs: [URL] = []

    init(manifest: OhMyZshResourceManifest) throws {
        manifestPayloads = [try Self.payload(for: manifest)]
        super.init()
    }

    init(manifests: [OhMyZshResourceManifest]) throws {
        precondition(manifests.isEmpty == false)
        manifestPayloads = try manifests.map(Self.payload(for:))
        super.init()
    }

    private static func payload(for manifest: OhMyZshResourceManifest) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": manifest.version,
            "sizeBytes": manifest.sizeBytes,
            "sha256": manifest.sha256,
            "downloadPath": manifest.downloadPath,
        ])
    }

    override func dataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask {
        condition.lock()
        let payload = manifestPayloads[min(nextManifestIndex, manifestPayloads.count - 1)]
        nextManifestIndex += 1
        condition.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        completionHandler(payload, response, nil)
        return ImmediateOhMyZshDataTask()
    }

    override func downloadTask(
        with url: URL,
        completionHandler: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void
    ) -> URLSessionDownloadTask {
        condition.lock()
        downloadURLs.append(url)
        downloadCompletions.append(completionHandler)
        condition.broadcast()
        condition.unlock()
        return ImmediateOhMyZshDownloadTask()
    }

    var downloadRequestCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return downloadCompletions.count
    }

    var downloadRequestPaths: [String] {
        condition.lock()
        defer { condition.unlock() }
        return downloadURLs.map(\.path)
    }

    func waitForDownloadRequestCount(_ expectedCount: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while downloadCompletions.count < expectedCount {
            if condition.wait(until: deadline) == false {
                return false
            }
        }
        return true
    }

    func completeNextDownload(error: Error) {
        condition.lock()
        let completion = downloadCompletions.removeFirst()
        condition.unlock()
        completion(nil, nil, error)
    }

    func completeDownloads(error: Error) {
        condition.lock()
        let completions = downloadCompletions
        downloadCompletions.removeAll()
        condition.unlock()
        completions.forEach { $0(nil, nil, error) }
    }
}

final class OhMyZshResourceIntegrityCacheTests: XCTestCase {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
    }

    private final class LockedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Date

        init(_ date: Date) {
            storage = date
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            storage = storage.addingTimeInterval(interval)
            lock.unlock()
        }
    }

    private final class LockedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
    }

    private final class LockedValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value?

        var value: Value? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ value: Value) {
            lock.lock()
            storage = value
            lock.unlock()
        }
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeInstalledResource(includeTreeMarker: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-integrity-cache-\(UUID().uuidString)", isDirectory: true)
        try writeFile("#!/bin/zsh\n", to: root.appendingPathComponent("oh-my-zsh.sh"))
        try writeFile("git plugin\n", to: root.appendingPathComponent("plugins/git/git.plugin.zsh"))
        try writeFile("theme\n", to: root.appendingPathComponent("themes/robbyrussell.zsh-theme"))
        try writeFile("font bytes\n", to: root.appendingPathComponent("fonts/\(OhMyZshResourceManager.nerdFontFileName)"))
        try "2026.08.1".write(
            to: root.appendingPathComponent(OhMyZshResourceManager.versionMarkerFileName),
            atomically: true,
            encoding: .utf8
        )
        try String(repeating: "a", count: 64).write(
            to: root.appendingPathComponent(OhMyZshResourceManager.manifestHashMarkerFileName),
            atomically: true,
            encoding: .utf8
        )
        if includeTreeMarker {
            try refreshTreeMarker(at: root)
        }
        return root
    }

    private func refreshTreeMarker(at root: URL) throws {
        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let digest = try digestManager.directoryTreeDigest(at: root)
        try digest.write(
            to: root.appendingPathComponent(OhMyZshResourceManager.installTreeHashMarkerFileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func waitForValidation(
        _ manager: OhMyZshResourceManager,
        expected: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let finished = expectation(description: "oh-my-zsh-integrity-validation")
        manager.refreshIntegrityValidation { isValid in
            XCTAssertEqual(isValid, expected, file: file, line: line)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    private func waitForLease(
        _ manager: OhMyZshResourceManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> OhMyZshDeploymentLease {
        let finished = expectation(description: "oh-my-zsh-deployment-lease")
        let captured = LockedValue<Result<OhMyZshDeploymentLease, Error>>()
        manager.validatedResourceLeaseForDeployment { result in
            captured.set(result)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        return try XCTUnwrap(captured.value, file: file, line: line).get()
    }

    private func makeEnabledSettingsStore() throws -> (AppSettingsStore, UserDefaults, String) {
        let suiteName = "test-omz-auto-apply-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.ohmyzshEnabled = true
            settings.ohmyzshTheme = "robbyrussell"
            settings.ohmyzshPlugins = ["git"]
        }
        return (store, defaults, suiteName)
    }

    func testDownloadIfNeededStartsDownloadAfterIntegrityGateBecomesIdle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-download-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        OhMyZshDownloadGateURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OhMyZshDownloadGateURLProtocol.self]
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            baseURL: URL(string: "https://ohmyzsh-download-gate.invalid/oh-my-zsh")!,
            session: URLSession(configuration: configuration)
        )
        let finished = expectation(description: "download-started-after-integrity-gate")

        manager.downloadIfNeeded { result in
            guard case let .failure(error) = result else {
                return XCTFail("stub snapshot download should terminate with its controlled error")
            }
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(
            OhMyZshDownloadGateURLProtocol.recordedPaths,
            ["/oh-my-zsh/manifest.json", "/oh-my-zsh/snapshot.tar.gz"]
        )
    }

    func testQueuedDownloadWaitersSurviveReentrantForceValidation() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let scanCount = LockedCounter()
        let firstScanCaptured = expectation(description: "reentrant-download-first-scan-captured")
        let releaseFirstScan = DispatchSemaphore(value: 0)
        let manifestHash = String(repeating: "a", count: 64)
        let manifest = OhMyZshResourceManifest(
            version: "2026.08.1",
            sizeBytes: 1,
            sha256: manifestHash,
            downloadPath: "snapshot.tar.gz"
        )
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            baseURL: URL(string: "https://ohmyzsh-download-gate.invalid/oh-my-zsh")!,
            session: try ImmediateOhMyZshManifestSession(manifest: manifest),
            treeDigestProvider: { url in
                scanCount.increment()
                let digest = try digestManager.directoryTreeDigest(at: url)
                if scanCount.value == 1 {
                    firstScanCaptured.fulfill()
                    _ = releaseFirstScan.wait(timeout: .now() + 5)
                }
                return digest
            }
        )
        let firstResult = LockedValue<Result<Void, Error>>()
        let secondResult = LockedValue<Result<Void, Error>>()
        let leaseResult = LockedValue<Result<OhMyZshDeploymentLease, Error>>()
        let firstFinished = expectation(description: "reentrant-download-first-finished")
        let secondFinished = expectation(description: "reentrant-download-second-finished")
        let leaseFinished = expectation(description: "reentrant-download-force-lease-finished")

        manager.downloadIfNeeded { result in
            firstResult.set(result)
            XCTAssertTrue(manager.status().isValidating, "after-gate 回调交接期间仍应保持 busy 门禁")
            // This force request is intentionally reentrant with after-gate delivery. It must
            // queue behind all already-reserved download decisions instead of clearing their
            // validated installation between callbacks.
            manager.validatedResourceLeaseForDeployment { result in
                leaseResult.set(result)
                if case let .success(lease) = result {
                    lease.release()
                }
                leaseFinished.fulfill()
            }
            firstFinished.fulfill()
        }
        wait(for: [firstScanCaptured], timeout: 2)

        manager.downloadIfNeeded { result in
            secondResult.set(result)
            secondFinished.fulfill()
        }
        XCTAssertEqual(scanCount.value, 1, "第二个 force 必须在首轮扫描释放前完成排队")
        releaseFirstScan.signal()
        wait(for: [firstFinished, secondFinished, leaseFinished], timeout: 10)

        guard case .success? = firstResult.value else {
            return XCTFail("第一个合法下载等待者不应失败：\(String(describing: firstResult.value))")
        }
        guard case .success? = secondResult.value else {
            return XCTFail("回调重入 force 校验不应丢失第二个合法下载等待者：\(String(describing: secondResult.value))")
        }
        guard case .success? = leaseResult.value else {
            return XCTFail("重入的 force 校验应最终交付独立租约：\(String(describing: leaseResult.value))")
        }
        XCTAssertEqual(scanCount.value, 3, "首轮、排队 force 和重入租约各执行一次摘要校验")
    }

    func testConcurrentSameManifestDownloadsShareOneOperationResult() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-coalesced-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = OhMyZshResourceManifest(
            version: "2026.08.1",
            sizeBytes: 1,
            sha256: String(repeating: "b", count: 64),
            downloadPath: "snapshot.tar.gz"
        )
        let session = try ImmediateOhMyZshManifestSession(manifest: manifest)
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            baseURL: URL(string: "https://ohmyzsh-download-gate.invalid/oh-my-zsh")!,
            session: session
        )
        let firstResult = LockedValue<Result<Void, Error>>()
        let secondResult = LockedValue<Result<Void, Error>>()
        let firstFinished = expectation(description: "coalesced-download-first-finished")
        let secondFinished = expectation(description: "coalesced-download-second-finished")

        manager.download { result in
            firstResult.set(result)
            firstFinished.fulfill()
        }
        manager.download { result in
            secondResult.set(result)
            secondFinished.fulfill()
        }

        XCTAssertEqual(session.downloadRequestCount, 1, "相同 manifest 只能创建一个下载任务")
        session.completeDownloads(error: URLError(.cannotConnectToHost))
        wait(for: [firstFinished, secondFinished], timeout: 2)

        for result in [firstResult.value, secondResult.value] {
            guard case let .failure(error)? = result else {
                return XCTFail("合并下载的每个等待者都应收到受控下载结果：\(String(describing: result))")
            }
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    func testAfterGateDeliveryPublishesIdleStatusAfterCallbacksFinish() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = OhMyZshResourceManifest(
            version: "2026.08.1",
            sizeBytes: 1,
            sha256: String(repeating: "a", count: 64),
            downloadPath: "snapshot.tar.gz"
        )
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            baseURL: URL(string: "https://ohmyzsh-download-gate.invalid/oh-my-zsh")!,
            session: try ImmediateOhMyZshManifestSession(manifest: manifest)
        )
        let callbackEntered = expectation(description: "after-gate-callback-entered")
        let busyNotification = expectation(description: "after-gate-busy-notification")
        let idleNotification = expectation(description: "after-gate-idle-notification")
        let releaseCallback = DispatchSemaphore(value: 0)
        let observedStates = LockedEvents()
        let observationLock = NSLock()
        var didObserveBusy = false
        var didObserveIdle = false
        let observer = NotificationCenter.default.addObserver(
            forName: OhMyZshResourceManager.statusDidChangeNotification,
            object: manager,
            queue: .main
        ) { _ in
            let isBusy = manager.status().isBusy
            observedStates.append(isBusy ? "busy" : "idle")
            if isBusy {
                observationLock.lock()
                let shouldFulfill = didObserveBusy == false
                didObserveBusy = true
                observationLock.unlock()
                if shouldFulfill {
                    busyNotification.fulfill()
                }
            } else {
                observationLock.lock()
                let shouldFulfill = didObserveIdle == false
                didObserveIdle = true
                observationLock.unlock()
                if shouldFulfill {
                    idleNotification.fulfill()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let outcome = LockedValue<Result<Void, Error>>()
        manager.downloadIfNeeded { result in
            outcome.set(result)
            callbackEntered.fulfill()
            _ = releaseCallback.wait(timeout: .now() + 5)
        }

        wait(for: [callbackEntered, busyNotification], timeout: 5)
        XCTAssertTrue(manager.status().isValidating, "after-gate 回调阻塞期间应保持 busy")
        releaseCallback.signal()
        wait(for: [idleNotification], timeout: 5)

        guard case .success? = outcome.value else {
            return XCTFail("匹配已安装资源的下载决策不应失败：\(String(describing: outcome.value))")
        }
        XCTAssertFalse(manager.status().isBusy)
        XCTAssertEqual(observedStates.values, ["busy", "idle"], "交接只应发送一次 busy 和一次最终 idle")
    }

    func testExplicitDownloadWaitsForAfterGateDeliveryToFinish() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let installedManifest = OhMyZshResourceManifest(
            version: "2026.08.1",
            sizeBytes: 1,
            sha256: String(repeating: "a", count: 64),
            downloadPath: "installed.tar.gz"
        )
        let explicitManifest = OhMyZshResourceManifest(
            version: "2026.08.2",
            sizeBytes: 2,
            sha256: String(repeating: "b", count: 64),
            downloadPath: "explicit.tar.gz"
        )
        let session = try ImmediateOhMyZshManifestSession(manifests: [installedManifest, explicitManifest])
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            baseURL: URL(string: "https://ohmyzsh-download-gate.invalid/oh-my-zsh")!,
            session: session
        )
        let releaseCallback = DispatchSemaphore(value: 0)
        let callbackEntered = expectation(description: "explicit-download-after-gate-callback-entered")
        let explicitFinished = expectation(description: "explicit-download-finished")
        let initialOutcome = LockedValue<Result<Void, Error>>()
        let explicitOutcome = LockedValue<Result<Void, Error>>()

        manager.downloadIfNeeded { result in
            initialOutcome.set(result)
            manager.download { result in
                explicitOutcome.set(result)
                explicitFinished.fulfill()
            }
            callbackEntered.fulfill()
            _ = releaseCallback.wait(timeout: .now() + 5)
        }

        wait(for: [callbackEntered], timeout: 5)
        XCTAssertEqual(session.downloadRequestCount, 0, "公开下载不得在 after-gate 回调交接期间启动任务")
        releaseCallback.signal()
        XCTAssertTrue(session.waitForDownloadRequestCount(1), "交接完成后应启动排队的公开下载")
        XCTAssertEqual(session.downloadRequestPaths, ["/oh-my-zsh/explicit.tar.gz"])
        session.completeNextDownload(error: URLError(.cannotConnectToHost))
        wait(for: [explicitFinished], timeout: 5)

        guard case .success? = initialOutcome.value else {
            return XCTFail("已安装资源决策不应失败：\(String(describing: initialOutcome.value))")
        }
        guard case let .failure(error)? = explicitOutcome.value else {
            return XCTFail("公开下载应收到受控任务结果：\(String(describing: explicitOutcome.value))")
        }
        XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
    }

    func testQueuedExplicitDownloadsSerializeDifferentManifestsAndCoalesceWaiters() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let installedManifest = OhMyZshResourceManifest(
            version: "2026.08.1",
            sizeBytes: 1,
            sha256: String(repeating: "a", count: 64),
            downloadPath: "installed.tar.gz"
        )
        let manifestB = OhMyZshResourceManifest(
            version: "2026.08.2",
            sizeBytes: 2,
            sha256: String(repeating: "b", count: 64),
            downloadPath: "snapshot-b.tar.gz"
        )
        let manifestC = OhMyZshResourceManifest(
            version: "2026.08.3",
            sizeBytes: 3,
            sha256: String(repeating: "c", count: 64),
            downloadPath: "snapshot-c.tar.gz"
        )
        let session = try ImmediateOhMyZshManifestSession(
            manifests: [installedManifest, manifestB, manifestC, manifestB]
        )
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            baseURL: URL(string: "https://ohmyzsh-download-gate.invalid/oh-my-zsh")!,
            session: session
        )
        let releaseCallback = DispatchSemaphore(value: 0)
        let callbackEntered = expectation(description: "queued-explicit-downloads-after-gate-callback-entered")
        let b1Finished = expectation(description: "queued-explicit-download-b1-finished")
        let b2Finished = expectation(description: "queued-explicit-download-b2-finished")
        let cFinished = expectation(description: "queued-explicit-download-c-finished")
        let b1Outcome = LockedValue<Result<Void, Error>>()
        let b2Outcome = LockedValue<Result<Void, Error>>()
        let cOutcome = LockedValue<Result<Void, Error>>()

        manager.downloadIfNeeded { _ in
            manager.download { result in
                b1Outcome.set(result)
                b1Finished.fulfill()
            }
            manager.download { result in
                cOutcome.set(result)
                cFinished.fulfill()
            }
            manager.download { result in
                b2Outcome.set(result)
                b2Finished.fulfill()
            }
            callbackEntered.fulfill()
            _ = releaseCallback.wait(timeout: .now() + 5)
        }

        wait(for: [callbackEntered], timeout: 5)
        XCTAssertEqual(session.downloadRequestCount, 0, "所有公开下载都必须等待 after-gate 交接完成")
        releaseCallback.signal()

        XCTAssertTrue(session.waitForDownloadRequestCount(1))
        XCTAssertEqual(session.downloadRequestPaths, ["/oh-my-zsh/snapshot-b.tar.gz"])
        session.completeNextDownload(error: URLError(.cannotConnectToHost))
        wait(for: [b1Finished, b2Finished], timeout: 5)

        XCTAssertTrue(session.waitForDownloadRequestCount(1))
        XCTAssertEqual(
            session.downloadRequestPaths,
            ["/oh-my-zsh/snapshot-b.tar.gz", "/oh-my-zsh/snapshot-c.tar.gz"]
        )
        session.completeNextDownload(error: URLError(.timedOut))
        wait(for: [cFinished], timeout: 5)

        for result in [b1Outcome.value, b2Outcome.value] {
            guard case let .failure(error)? = result else {
                return XCTFail("同 manifest 等待者应共享第一个任务结果：\(String(describing: result))")
            }
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        guard case let .failure(error)? = cOutcome.value else {
            return XCTFail("不同 manifest 等待者应收到后续任务结果：\(String(describing: cOutcome.value))")
        }
        XCTAssertEqual((error as? URLError)?.code, .timedOut)
    }

    func testStatusAndDirectoryQueriesCoalesceBackgroundTreeValidation() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }

        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let counter = LockedCounter()
        let validationStarted = expectation(description: "tree-validation-started")
        let releaseValidation = DispatchSemaphore(value: 0)
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            integrityRevalidationInterval: 3_600,
            treeDigestProvider: { url in
                counter.increment()
                if counter.value == 1 {
                    validationStarted.fulfill()
                    _ = releaseValidation.wait(timeout: .now() + 5)
                }
                return try digestManager.directoryTreeDigest(at: url)
            }
        )

        let startedAt = Date()
        let firstStatus = manager.status()
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
        XCTAssertTrue(firstStatus.isValidating)
        XCTAssertFalse(firstStatus.isInstalled)

        wait(for: [validationStarted], timeout: 2)
        let firstValidationFinished = expectation(
            forNotification: OhMyZshResourceManager.statusDidChangeNotification,
            object: manager
        ) { _ in true }
        for _ in 0..<20 {
            _ = manager.status()
            _ = manager.installedDirectoryURL
        }
        XCTAssertEqual(counter.value, 1, "并发状态查询必须复用同一次后台摘要校验")

        releaseValidation.signal()
        wait(for: [firstValidationFinished], timeout: 10)
        XCTAssertEqual(manager.status().installedVersion, "2026.08.1")
        XCTAssertEqual(manager.installedDirectoryURL, root)
        XCTAssertEqual(counter.value, 1, "TTL 内的状态查询不得重新扫描资源树")

        try writeFile("tampered\n", to: root.appendingPathComponent("plugins/git/git.plugin.zsh"))
        waitForValidation(manager, expected: false)
        XCTAssertEqual(counter.value, 2)
        XCTAssertNil(manager.installedDirectoryURL)
        XCTAssertTrue(manager.status().requiresRedownload)
    }

    func testExpiredValidationDoesNotSwallowFirstSettingsApplication() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let counter = LockedCounter()
        let expiredScanStarted = expectation(description: "expired-scan-started")
        let releaseExpiredScan = DispatchSemaphore(value: 0)
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            integrityRevalidationInterval: 300,
            clock: { clock.now() },
            treeDigestProvider: { url in
                counter.increment()
                let digest = try digestManager.directoryTreeDigest(at: url)
                if counter.value == 2 {
                    expiredScanStarted.fulfill()
                    _ = releaseExpiredScan.wait(timeout: .now() + 5)
                }
                return digest
            }
        )
        waitForValidation(manager, expected: true)
        clock.advance(by: 301)
        XCTAssertTrue(manager.status().isValidating)
        wait(for: [expiredScanStarted], timeout: 2)

        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let applied = expectation(description: "settings-application-after-validation")
        let applyCount = LockedCounter()
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            localApply: { _, resourceURL in
                XCTAssertNotNil(resourceURL)
                XCTAssertNotEqual(resourceURL, root)
                applyCount.increment()
                applied.fulfill()
            }
        )

        applier.forceApply()
        XCTAssertEqual(applyCount.value, 0, "校验完成前不得部署")
        releaseExpiredScan.signal()
        wait(for: [applied], timeout: 10)
        XCTAssertEqual(applyCount.value, 1)
        XCTAssertEqual(counter.value, 3, "到期扫描期间发出的强制门禁必须执行后续新扫描")
    }

    func testRemoteFirstAutoApplyWaitsForIntegrityValidation() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let scanStarted = expectation(description: "remote-first-scan-started")
        let releaseScan = DispatchSemaphore(value: 0)
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            treeDigestProvider: { url in
                let digest = try digestManager.directoryTreeDigest(at: url)
                scanStarted.fulfill()
                _ = releaseScan.wait(timeout: .now() + 5)
                return digest
            }
        )
        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deployCount = LockedCounter()
        let completionCalled = LockedCounter()
        let completed = expectation(description: "remote-first-auto-apply")
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            remoteSessionApply: { _, _, _, _, resourceURL in
                XCTAssertNotNil(resourceURL)
                XCTAssertNotEqual(resourceURL, root)
                deployCount.increment()
            }
        )
        let config = SshConnectionConfig(
            host: "example.invalid",
            port: 22,
            username: "root",
            authMethod: .agent,
            connectTimeoutMs: 1_000
        )

        applier.autoApplyRemoteSession(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: ""
        ) { result in
            completionCalled.increment()
            if case let .failure(error) = result {
                XCTFail("有效资源首次校验后应部署成功：\(error)")
            }
            completed.fulfill()
        }
        wait(for: [scanStarted], timeout: 2)
        XCTAssertEqual(deployCount.value, 0)
        XCTAssertEqual(completionCalled.value, 0, "未部署时不得提前回 success")
        releaseScan.signal()
        wait(for: [completed], timeout: 10)
        XCTAssertEqual(deployCount.value, 1)
        XCTAssertEqual(completionCalled.value, 1)
    }

    func testTamperedCachedResourceCannotReachLocalOrRemoteDeployment() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            integrityRevalidationInterval: 3_600
        )
        waitForValidation(manager, expected: true)
        try writeFile("tampered payload\n", to: root.appendingPathComponent("plugins/git/git.plugin.zsh"))

        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let localCalled = LockedCounter()
        let remoteCalled = LockedCounter()
        let localFinished = expectation(description: "tampered-local-rejected")
        let remoteFinished = expectation(description: "tampered-remote-rejected")
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            localApply: { _, _ in localCalled.increment() },
            remoteSessionApply: { _, _, _, _, _ in remoteCalled.increment() }
        )
        applier.onLocalDeployFinished = { result in
            if case .success = result {
                XCTFail("篡改资源不得报告本地部署成功")
            }
            localFinished.fulfill()
        }
        applier.forceApply()

        let config = SshConnectionConfig(
            host: "example.invalid",
            port: 22,
            username: "root",
            authMethod: .agent,
            connectTimeoutMs: 1_000
        )
        applier.autoApplyRemoteSession(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: ""
        ) { result in
            if case .success = result {
                XCTFail("篡改资源未部署时不得报告远端成功")
            }
            remoteFinished.fulfill()
        }

        wait(for: [localFinished, remoteFinished], timeout: 10)
        XCTAssertEqual(localCalled.value, 0)
        XCTAssertEqual(remoteCalled.value, 0)
        XCTAssertTrue(manager.status().requiresRedownload)
    }

    func testSettingsChangeDuringValidationExecutesOnlyLatestDisabledState() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let scanStarted = expectation(description: "stale-enable-scan-started")
        let releaseScan = DispatchSemaphore(value: 0)
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            treeDigestProvider: { url in
                let digest = try digestManager.directoryTreeDigest(at: url)
                scanStarted.fulfill()
                _ = releaseScan.wait(timeout: .now() + 5)
                return digest
            }
        )
        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let states = LockedEvents()
        let disabledApplied = expectation(description: "latest-disabled-state-applied")
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            localApply: { settings, _ in
                states.append(settings.ohmyzshEnabled ? "enabled" : "disabled")
                if settings.ohmyzshEnabled == false {
                    disabledApplied.fulfill()
                }
            }
        )

        applier.forceApply()
        wait(for: [scanStarted], timeout: 2)
        store.update { $0.ohmyzshEnabled = false }
        applier.forceApply()
        wait(for: [disabledApplied], timeout: 2)
        releaseScan.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(states.values, ["disabled"], "过期的启用请求不得在校验完成后反向覆盖最新设置")
    }

    func testForceRequestDuringScanRunsPostRequestValidation() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let counter = LockedCounter()
        let firstDigestCaptured = expectation(description: "first-digest-captured")
        let releaseFirstDigest = DispatchSemaphore(value: 0)
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            treeDigestProvider: { url in
                counter.increment()
                let digest = try digestManager.directoryTreeDigest(at: url)
                if counter.value == 1 {
                    firstDigestCaptured.fulfill()
                    _ = releaseFirstDigest.wait(timeout: .now() + 5)
                }
                return digest
            }
        )

        _ = manager.status()
        wait(for: [firstDigestCaptured], timeout: 2)
        let forced = expectation(description: "post-request-force-validation")
        manager.refreshIntegrityValidation { isValid in
            XCTAssertFalse(isValid, "force 必须看到请求后发生的篡改")
            forced.fulfill()
        }
        try writeFile("mutated after force request\n", to: root.appendingPathComponent("plugins/git/git.plugin.zsh"))
        releaseFirstDigest.signal()
        wait(for: [forced], timeout: 10)
        XCTAssertEqual(counter.value, 2)
        XCTAssertTrue(manager.status().requiresRedownload)
    }

    func testMarkerlessInternalBuildRequiresNonDestructiveRedownload() throws {
        let root = try makeInstalledResource(includeTreeMarker: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalScript = try Data(contentsOf: root.appendingPathComponent("oh-my-zsh.sh"))
        let manager = OhMyZshResourceManager(resourceDirectoryURL: root)

        waitForValidation(manager, expected: false)

        let status = manager.status()
        XCTAssertFalse(status.isInstalled)
        XCTAssertTrue(status.requiresRedownload)
        XCTAssertNil(manager.installedDirectoryURL)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("oh-my-zsh.sh")), originalScript)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(OhMyZshResourceManager.versionMarkerFileName).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(OhMyZshResourceManager.installTreeHashMarkerFileName).path
        ))
    }

    func testFontRegistrationFailureRetriesAndSuccessIsDeduplicated() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = LockedCounter()
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            fontRegistrar: { _ in
                counter.increment()
                return counter.value >= 2
            }
        )
        waitForValidation(manager, expected: true)

        XCTAssertFalse(manager.registerNerdFontIfNeeded())
        XCTAssertTrue(manager.registerNerdFontIfNeeded())
        XCTAssertTrue(manager.registerNerdFontIfNeeded())
        XCTAssertEqual(counter.value, 2, "成功后才可抑制同一字体资源的重复注册")
    }

    func testFontUpdateUninstallAndReinstallUseOwnedCoreTextLifecycle() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = LockedEvents()
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            fontRegistrar: { url in
                events.append("register:\((try? String(contentsOf: url, encoding: .utf8)) ?? "missing")")
                return true
            },
            fontUnregistrar: { url in
                events.append("unregister:\((try? String(contentsOf: url, encoding: .utf8)) ?? "missing")")
                return true
            }
        )
        waitForValidation(manager, expected: true)
        XCTAssertTrue(manager.registerNerdFontIfNeeded())

        try writeFile("new font bytes\n", to: root.appendingPathComponent("fonts/\(OhMyZshResourceManager.nerdFontFileName)"))
        try refreshTreeMarker(at: root)
        waitForValidation(manager, expected: true)
        XCTAssertTrue(manager.registerNerdFontIfNeeded())

        let suiteName = "test-omz-font-uninstall-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try manager.uninstall(settingsStore: AppSettingsStore(defaults: defaults))

        let recreated = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: recreated) }
        try FileManager.default.moveItem(at: recreated, to: root)
        waitForValidation(manager, expected: true)
        XCTAssertTrue(manager.registerNerdFontIfNeeded())
        XCTAssertEqual(events.values, [
            "register:font bytes\n",
            "unregister:font bytes\n",
            "register:new font bytes\n",
            "unregister:new font bytes\n",
            "register:font bytes\n"
        ])
    }

    func testFontUnregisterFailureIsRetryableAndBlocksReplacement() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = LockedEvents()
        let unregisterAttempts = LockedCounter()
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            fontRegistrar: { _ in
                events.append("register")
                return true
            },
            fontUnregistrar: { _ in
                unregisterAttempts.increment()
                events.append("unregister")
                return unregisterAttempts.value >= 2
            }
        )
        waitForValidation(manager, expected: true)
        XCTAssertTrue(manager.registerNerdFontIfNeeded())
        try writeFile("new font bytes\n", to: root.appendingPathComponent("fonts/\(OhMyZshResourceManager.nerdFontFileName)"))
        try refreshTreeMarker(at: root)
        waitForValidation(manager, expected: true)

        XCTAssertFalse(manager.registerNerdFontIfNeeded(), "注销失败时不得把新字体记成成功")
        XCTAssertTrue(manager.registerNerdFontIfNeeded(), "注销失败后必须可重试")
        XCTAssertTrue(manager.registerNerdFontIfNeeded(), "成功注册后应去重")
        XCTAssertEqual(events.values, ["register", "unregister", "unregister", "register"])
    }

    func testFontUnregisterFailureBlocksUninstallAndCanRetry() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let unregisterAttempts = LockedCounter()
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            fontRegistrar: { _ in true },
            fontUnregistrar: { _ in
                unregisterAttempts.increment()
                return unregisterAttempts.value >= 2
            }
        )
        waitForValidation(manager, expected: true)
        XCTAssertTrue(manager.registerNerdFontIfNeeded())

        let suiteName = "test-omz-font-uninstall-retry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { $0.ohmyzshEnabled = true }
        XCTAssertThrowsError(try manager.uninstall(settingsStore: store)) { error in
            XCTAssertEqual(error as? OhMyZshResourceError, .fontUnregistrationFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(store.snapshot().ohmyzshEnabled)

        XCTAssertNoThrow(try manager.uninstall(settingsStore: store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(store.snapshot().ohmyzshEnabled)
        XCTAssertEqual(unregisterAttempts.value, 2)
    }

    @MainActor
    func testBatchHandlerEnumeratesOnMainActorAndConsumesValidatedSnapshot() throws {
        let root = try makeInstalledResource()
        let uploaded = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-batch-upload-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: uploaded)
        }
        let manager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let applied = expectation(description: "batch-handler-completed")
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            localApply: { _, leaseURL in
                XCTAssertNotEqual(leaseURL, root, "部署必须使用私有 lease，不能暴露可变安装目录")
                try "tampered after gate\n".write(
                    to: root.appendingPathComponent("plugins/git/git.plugin.zsh"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        )
        applier.localTerminalPanesProvider = {
            XCTAssertTrue(Thread.isMainThread, "AppKit pane 枚举必须位于 MainActor")
            return []
        }
        applier.remoteApplyHandler = { settings, lease, completion in
            XCTAssertTrue(Thread.isMainThread, "远端目标快照必须位于 MainActor")
            XCTAssertTrue(settings.ohmyzshEnabled)
            guard let lease else {
                completion(.failure(OhMyZshResourceError.integrityValidationFailed))
                return
            }
            XCTAssertNotEqual(lease.directoryURL, root)
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<Void, Error> = Result {
                    try FileManager.default.copyItem(at: lease.directoryURL, to: uploaded)
                }
                Task { @MainActor in completion(result) }
            }
        }
        applier.onApplyFinished = { result in
            if case let .failure(error) = result {
                XCTFail("批量部署应成功：\(error)")
            }
            applied.fulfill()
        }

        applier.forceApply()
        wait(for: [applied], timeout: 10)
        XCTAssertEqual(
            try String(contentsOf: uploaded.appendingPathComponent("plugins/git/git.plugin.zsh")),
            "git plugin\n",
            "远端上传必须读取门禁产出的快照，而不是门禁后被篡改的安装目录"
        )
    }

    @MainActor
    func testBatchRemoteSettingsAreSerializedSoNewestFinishesLast() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.update { $0.ohmyzshTheme = "A" }
        let events = LockedEvents()
        let firstStarted = expectation(description: "remote-A-started")
        let bothFinished = expectation(description: "remote-A-and-B-finished")
        bothFinished.expectedFulfillmentCount = 2
        let releaseFirst = DispatchSemaphore(value: 0)
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            localApply: { _, _ in }
        )
        applier.remoteApplyHandler = { settings, lease, completion in
            XCTAssertNotNil(lease)
            let theme = settings.ohmyzshTheme ?? ""
            events.append("start-\(theme)")
            if theme == "A" {
                firstStarted.fulfill()
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = releaseFirst.wait(timeout: .now() + 5)
                    Task { @MainActor in
                        events.append("finish-A")
                        completion(.success(()))
                    }
                }
            } else {
                events.append("finish-\(theme)")
                completion(.success(()))
            }
        }
        applier.onApplyFinished = { _ in bothFinished.fulfill() }

        applier.forceApply()
        wait(for: [firstStarted], timeout: 10)
        store.update { $0.ohmyzshTheme = "B" }
        applier.forceApply()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(events.values, ["start-A"], "B 不能与仍在运行的 A 并发")
        releaseFirst.signal()
        wait(for: [bothFinished], timeout: 10)
        XCTAssertEqual(events.values, ["start-A", "finish-A", "start-B", "finish-B"])
    }

    @MainActor
    func testLatestDesiredSettingsWinWhenSwitchingAtoBtoA() throws {
        try assertLatestDesiredSettingsWinWhenSwitchingAtoBtoA(bShouldFail: false)
    }

    @MainActor
    func testLatestDesiredSettingsWinWhenIntermediateBFailureOccurs() throws {
        try assertLatestDesiredSettingsWinWhenSwitchingAtoBtoA(bShouldFail: true)
    }

    @MainActor
    private func assertLatestDesiredSettingsWinWhenSwitchingAtoBtoA(
        bShouldFail: Bool
    ) throws {
        struct ExpectedFailure: Error {}

        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.update { $0.ohmyzshTheme = "A" }

        let events = LockedEvents()
        let callbackResults = LockedEvents()
        let initialFinished = expectation(description: "initial-A-finished")
        let bStarted = expectation(description: "B-started")
        let finalFinished = expectation(description: "final-A-finished")
        let releaseB = DispatchSemaphore(value: 0)
        let finishCount = LockedCounter()
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            localApply: { _, _ in }
        )
        applier.remoteApplyHandler = { settings, lease, completion in
            XCTAssertNotNil(lease)
            let theme = settings.ohmyzshTheme ?? ""
            events.append("start-\(theme)")
            if theme == "B" {
                bStarted.fulfill()
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = releaseB.wait(timeout: .now() + 5)
                    Task { @MainActor in
                        events.append(bShouldFail ? "fail-B" : "finish-B")
                        if bShouldFail {
                            completion(.failure(ExpectedFailure()))
                        } else {
                            completion(.success(()))
                        }
                    }
                }
            } else {
                events.append("finish-A")
                completion(.success(()))
            }
        }
        applier.onApplyFinished = { result in
            finishCount.increment()
            switch result {
            case .success:
                callbackResults.append("success")
            case .failure:
                callbackResults.append("failure")
            }
            if finishCount.value == 1 {
                initialFinished.fulfill()
            } else if finishCount.value == 3 {
                finalFinished.fulfill()
            }
        }
        applier.start()
        defer { applier.stop() }

        applier.forceApply()
        wait(for: [initialFinished], timeout: 10)
        store.update { $0.ohmyzshTheme = "B" }
        wait(for: [bStarted], timeout: 10)
        store.update { $0.ohmyzshTheme = "A" }
        releaseB.signal()
        wait(for: [finalFinished], timeout: 10)

        let expectedMiddle = bShouldFail ? "fail-B" : "finish-B"
        XCTAssertEqual(
            events.values,
            ["start-A", "finish-A", "start-B", expectedMiddle, "start-A", "finish-A"]
        )
        XCTAssertEqual(
            callbackResults.values,
            bShouldFail
                ? ["success", "failure", "success"]
                : ["success", "success", "success"]
        )
        XCTAssertEqual(store.snapshot().ohmyzshTheme, "A")
    }

    @MainActor
    func testBatchRemoteFailureIsObservable() throws {
        struct ExpectedFailure: Error {}
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let finished = expectation(description: "remote-failure-observed")
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            localApply: { _, _ in }
        )
        applier.remoteApplyHandler = { _, lease, completion in
            XCTAssertNotNil(lease)
            completion(.failure(ExpectedFailure()))
        }
        applier.onApplyFinished = { result in
            guard case .failure = result else {
                return XCTFail("远端失败不得被吞成 success")
            }
            finished.fulfill()
        }
        applier.forceApply()
        wait(for: [finished], timeout: 10)
    }

    func testConnectedSessionUsesSettingsChangedDuringIntegrityGate() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let scanStarted = expectation(description: "session-integrity-started")
        let releaseScan = DispatchSemaphore(value: 0)
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            treeDigestProvider: { url in
                let digest = try digestManager.directoryTreeDigest(at: url)
                scanStarted.fulfill()
                _ = releaseScan.wait(timeout: .now() + 5)
                return digest
            }
        )
        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.update { $0.ohmyzshTheme = "A" }
        let themes = LockedEvents()
        let completed = expectation(description: "connected-session-applied")
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            remoteSessionApply: { _, _, _, settings, resourceURL in
                XCTAssertNotNil(resourceURL)
                themes.append(settings.ohmyzshTheme ?? "")
            }
        )
        let config = SshConnectionConfig(
            host: "example.invalid",
            port: 22,
            username: "root",
            authMethod: .agent,
            connectTimeoutMs: 1_000
        )

        applier.autoApplyRemoteSession(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: ""
        ) { result in
            if case let .failure(error) = result { XCTFail("应使用最新设置成功部署：\(error)") }
            completed.fulfill()
        }
        wait(for: [scanStarted], timeout: 2)
        store.update { $0.ohmyzshTheme = "B" }
        releaseScan.signal()
        wait(for: [completed], timeout: 10)
        XCTAssertEqual(themes.values, ["B"])
    }

    func testConcurrentDeploymentLeaseRequestsBothReceiveIndependentSnapshots() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let scanCount = LockedCounter()
        let firstScanCaptured = expectation(description: "first-lease-scan-captured")
        let releaseFirstScan = DispatchSemaphore(value: 0)
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            treeDigestProvider: { url in
                scanCount.increment()
                let digest = try digestManager.directoryTreeDigest(at: url)
                if scanCount.value == 1 {
                    firstScanCaptured.fulfill()
                    _ = releaseFirstScan.wait(timeout: .now() + 5)
                }
                return digest
            }
        )
        let firstLease = LockedValue<OhMyZshDeploymentLease>()
        let secondLease = LockedValue<OhMyZshDeploymentLease>()
        let firstFinished = expectation(description: "first-lease-finished")
        let secondFinished = expectation(description: "second-lease-finished")

        manager.validatedResourceLeaseForDeployment { result in
            if case let .success(lease) = result {
                firstLease.set(lease)
            } else {
                XCTFail("首个合法租约请求不应被后续 force 扫描误伤")
            }
            firstFinished.fulfill()
        }
        wait(for: [firstScanCaptured], timeout: 2)
        manager.validatedResourceLeaseForDeployment { result in
            if case let .success(lease) = result {
                secondLease.set(lease)
            } else {
                XCTFail("第二个合法租约请求应在请求后的扫描完成后成功")
            }
            secondFinished.fulfill()
        }
        releaseFirstScan.signal()
        wait(for: [firstFinished, secondFinished], timeout: 10)

        let leaseA = try XCTUnwrap(firstLease.value)
        let leaseB = try XCTUnwrap(secondLease.value)
        defer {
            leaseA.release()
            leaseB.release()
        }
        XCTAssertEqual(scanCount.value, 2)
        XCTAssertNotEqual(leaseA.directoryURL, leaseB.directoryURL)
        XCTAssertEqual(
            try String(contentsOf: leaseA.directoryURL.appendingPathComponent("plugins/git/git.plugin.zsh")),
            "git plugin\n"
        )
        XCTAssertEqual(
            try String(contentsOf: leaseB.directoryURL.appendingPathComponent("plugins/git/git.plugin.zsh")),
            "git plugin\n"
        )
    }

    func testConcurrentDeploymentLeaseRequestsFailClosedAfterPostRequestTamper() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let scanCount = LockedCounter()
        let snapshotCopyCount = LockedCounter()
        let firstScanCaptured = expectation(description: "tamper-first-scan-captured")
        let secondScanCaptured = expectation(description: "tamper-second-scan-captured")
        let releaseFirstScan = DispatchSemaphore(value: 0)
        let releaseSecondScan = DispatchSemaphore(value: 0)
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            treeDigestProvider: { url in
                scanCount.increment()
                let digest = try digestManager.directoryTreeDigest(at: url)
                if scanCount.value == 1 {
                    firstScanCaptured.fulfill()
                    _ = releaseFirstScan.wait(timeout: .now() + 5)
                } else if scanCount.value == 2 {
                    secondScanCaptured.fulfill()
                    _ = releaseSecondScan.wait(timeout: .now() + 5)
                }
                return digest
            },
            deploymentSnapshotCopier: { source, destination in
                snapshotCopyCount.increment()
                try FileManager.default.copyItem(at: source, to: destination)
            }
        )
        let firstFinished = expectation(description: "tampered-first-lease-finished")
        let secondFinished = expectation(description: "tampered-second-lease-finished")
        let results = LockedEvents()

        manager.validatedResourceLeaseForDeployment { result in
            switch result {
            case let .success(lease):
                results.append("success")
                lease.release()
            case .failure:
                results.append("failure")
            }
            firstFinished.fulfill()
        }
        wait(for: [firstScanCaptured], timeout: 2)
        manager.validatedResourceLeaseForDeployment { result in
            switch result {
            case let .success(lease):
                results.append("success")
                lease.release()
            case .failure:
                results.append("failure")
            }
            secondFinished.fulfill()
        }
        try writeFile(
            "tampered after lease request\n",
            to: root.appendingPathComponent("plugins/git/git.plugin.zsh")
        )
        releaseFirstScan.signal()
        wait(for: [secondScanCaptured], timeout: 5)
        XCTAssertTrue(
            results.values.isEmpty,
            "最新强制扫描结束前，不得提前用已被撤销的 validatedInstallation 完成任何租约请求"
        )
        releaseSecondScan.signal()
        wait(for: [firstFinished, secondFinished], timeout: 10)

        XCTAssertEqual(scanCount.value, 2)
        XCTAssertEqual(results.values, ["failure", "failure"])
        XCTAssertEqual(snapshotCopyCount.value, 0)
        XCTAssertTrue(manager.status().requiresRedownload)
    }

    @MainActor
    func testGlobalAndConnectedSessionApplyCanShareOverlappingIntegrityGate() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let digestManager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let scanCount = LockedCounter()
        let firstScanCaptured = expectation(description: "overlap-first-scan-captured")
        let releaseFirstScan = DispatchSemaphore(value: 0)
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            treeDigestProvider: { url in
                scanCount.increment()
                let digest = try digestManager.directoryTreeDigest(at: url)
                if scanCount.value == 1 {
                    firstScanCaptured.fulfill()
                    _ = releaseFirstScan.wait(timeout: .now() + 5)
                }
                return digest
            }
        )
        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let localCount = LockedCounter()
        let batchCount = LockedCounter()
        let connectedCount = LockedCounter()
        let globalFinished = expectation(description: "overlap-global-finished")
        let connectedFinished = expectation(description: "overlap-connected-finished")
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            localApply: { _, resourceURL in
                XCTAssertNotNil(resourceURL)
                localCount.increment()
            },
            remoteSessionApply: { _, _, _, _, resourceURL in
                XCTAssertNotNil(resourceURL)
                connectedCount.increment()
            }
        )
        applier.remoteApplyHandler = { _, lease, completion in
            XCTAssertNotNil(lease)
            batchCount.increment()
            completion(.success(()))
        }
        applier.onApplyFinished = { result in
            if case let .failure(error) = result {
                XCTFail("重叠门禁不应丢失全局部署：\(error)")
            }
            globalFinished.fulfill()
        }
        let config = SshConnectionConfig(
            host: "example.invalid",
            port: 22,
            username: "root",
            authMethod: .agent,
            connectTimeoutMs: 1_000
        )

        applier.forceApply()
        wait(for: [firstScanCaptured], timeout: 2)
        applier.autoApplyRemoteSession(
            config: config,
            secret: .agent,
            expectedFingerprintSHA256: ""
        ) { result in
            if case let .failure(error) = result {
                XCTFail("重叠门禁不应丢失连接时部署：\(error)")
            }
            connectedFinished.fulfill()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        releaseFirstScan.signal()
        wait(for: [globalFinished, connectedFinished], timeout: 10)

        XCTAssertEqual(scanCount.value, 2)
        XCTAssertEqual(localCount.value, 1)
        XCTAssertEqual(batchCount.value, 1)
        XCTAssertEqual(connectedCount.value, 1)
    }

    func testSnapshotDigestRejectsContentChangedByControlledCopier() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        let copiedDestination = LockedEvents()
        let manager = OhMyZshResourceManager(
            resourceDirectoryURL: root,
            deploymentSnapshotCopier: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                copiedDestination.append(destination.path)
                try "changed while copying\n".write(
                    to: destination.appendingPathComponent("plugins/git/git.plugin.zsh"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        )
        let finished = expectation(description: "snapshot-copy-rejected")
        manager.validatedResourceLeaseForDeployment { result in
            guard case let .failure(error) = result else {
                return XCTFail("摘要不匹配的部署快照必须 fail closed")
            }
            XCTAssertEqual(error as? OhMyZshResourceError, .integrityValidationFailed)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertTrue(manager.status().requiresRedownload)
        XCTAssertEqual(copiedDestination.values.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedDestination.values[0]))
    }

    func testLeaseRemainsCompleteWhenInstalledResourceIsUninstalledMidCopy() throws {
        let root = try makeInstalledResource()
        let copied = FileManager.default.temporaryDirectory
            .appendingPathComponent("omz-controlled-local-copy-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: copied)
        }
        let manager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let lease = try waitForLease(manager)
        defer { lease.release() }
        let firstPartCopied = expectation(description: "first-lease-part-copied")
        let copyCompleted = expectation(description: "lease-copy-completed")
        let continueCopy = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
                try FileManager.default.copyItem(
                    at: lease.directoryURL.appendingPathComponent("oh-my-zsh.sh"),
                    to: copied.appendingPathComponent("oh-my-zsh.sh")
                )
                firstPartCopied.fulfill()
                _ = continueCopy.wait(timeout: .now() + 5)
                for name in ["plugins", "themes", "fonts"] {
                    try FileManager.default.copyItem(
                        at: lease.directoryURL.appendingPathComponent(name),
                        to: copied.appendingPathComponent(name)
                    )
                }
                copyCompleted.fulfill()
            } catch {
                XCTFail("独立 lease 不应被安装目录卸载破坏：\(error)")
            }
        }
        wait(for: [firstPartCopied], timeout: 5)
        let suiteName = "test-omz-lease-uninstall-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try manager.uninstall(settingsStore: AppSettingsStore(defaults: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        continueCopy.signal()
        wait(for: [copyCompleted], timeout: 10)
        XCTAssertEqual(
            try String(contentsOf: copied.appendingPathComponent("plugins/git/git.plugin.zsh")),
            "git plugin\n"
        )
    }

    @MainActor
    func testIntegrityFailureThenTrustedResourceAutomaticallyRetriesExactlyOnce() throws {
        let root = try makeInstalledResource()
        defer { try? FileManager.default.removeItem(at: root) }
        try "tampered\n".write(
            to: root.appendingPathComponent("plugins/git/git.plugin.zsh"),
            atomically: true,
            encoding: .utf8
        )
        let manager = OhMyZshResourceManager(resourceDirectoryURL: root)
        let (store, defaults, suiteName) = try makeEnabledSettingsStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let applyCount = LockedCounter()
        let firstFailure = expectation(description: "initial-integrity-failure")
        let recovered = expectation(description: "trusted-resource-auto-retry")
        let finishCount = LockedCounter()
        let applier = OhMyZshAutoApplier(
            settingsStore: store,
            resourceManager: manager,
            debounceInterval: 0,
            localApply: { _, _ in applyCount.increment() }
        )
        applier.onApplyFinished = { result in
            finishCount.increment()
            switch result {
            case .failure:
                firstFailure.fulfill()
            case .success:
                recovered.fulfill()
            }
        }
        applier.start()
        defer { applier.stop() }

        applier.forceApply()
        wait(for: [firstFailure], timeout: 10)
        try "git plugin\n".write(
            to: root.appendingPathComponent("plugins/git/git.plugin.zsh"),
            atomically: true,
            encoding: .utf8
        )
        try refreshTreeMarker(at: root)
        let trustedAgain = expectation(description: "resource-trusted-again")
        manager.refreshIntegrityValidation { isValid in
            XCTAssertTrue(isValid)
            trustedAgain.fulfill()
        }
        wait(for: [trustedAgain, recovered], timeout: 10)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(applyCount.value, 1)
        XCTAssertEqual(finishCount.value, 2, "资源恢复只能触发一次自动重试")
    }
}

// MARK: - Review 修复回归：tar 成员路径安全（zip-slip 纵深防御）

final class OhMyZshArchiveMemberSafetyTests: XCTestCase {
    func testUnsafeMembersRejected() {
        XCTAssertTrue(OhMyZshResourceManager.archiveMemberIsUnsafe("/etc/passwd"), "绝对路径成员拒绝")
        XCTAssertTrue(OhMyZshResourceManager.archiveMemberIsUnsafe("../evil"), ".. 穿越成员拒绝")
        XCTAssertTrue(OhMyZshResourceManager.archiveMemberIsUnsafe("dir/../../etc"), "深层 .. 拒绝")
        XCTAssertTrue(OhMyZshResourceManager.archiveMemberIsUnsafe("/tmp/x\n"), "尾随换行不影响判定")
    }

    func testSafeMembersAccepted() {
        XCTAssertFalse(OhMyZshResourceManager.archiveMemberIsUnsafe("./oh-my-zsh/custom/theme.zsh"), "./ 前缀安全")
        XCTAssertFalse(OhMyZshResourceManager.archiveMemberIsUnsafe("oh-my-zsh/README.md"))
        XCTAssertFalse(OhMyZshResourceManager.archiveMemberIsUnsafe("dir/with.dots/in.name"), "文件名中的点安全")
    }

    func testSymbolicLinkTargetsStayInsideExtractedRoot() {
        let root = "/tmp/omz-staging"
        XCTAssertTrue(
            OhMyZshResourceManager.archiveSymbolicLinkIsUnsafe(
                target: "/etc/passwd",
                linkPath: root + "/themes/evil",
                rootPath: root
            )
        )
        XCTAssertTrue(
            OhMyZshResourceManager.archiveSymbolicLinkIsUnsafe(
                target: "../../../outside",
                linkPath: root + "/themes/nested/evil",
                rootPath: root
            )
        )
        XCTAssertFalse(
            OhMyZshResourceManager.archiveSymbolicLinkIsUnsafe(
                target: "macovsky.zsh-theme",
                linkPath: root + "/themes/macovsky-ruby.zsh-theme",
                rootPath: root
            )
        )
    }
}
