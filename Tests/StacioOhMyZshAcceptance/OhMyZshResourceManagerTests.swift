import AppKit
import Darwin
import XCTest
@testable import StacioApp

/// OhMyZshResourceManager 端到端测试：本地 HTTP 服务器提供 snapshot.tar.gz + manifest.json，
/// 验证 下载 → sha256 校验 → 解压安装 → 目录可被 catalog 使用 → 卸载。
///
/// 前置：`scripts/sync-ohmyzsh-resources.sh --release --out <dir>`，并用
/// `STACIO_OMZ_TEST_SNAPSHOT_DIR=<dir>` 指向它。需 `--disable-sandbox` 运行。
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
}
