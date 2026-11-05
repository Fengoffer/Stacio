import Foundation
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class GraphicsFileUploadCoordinatorTests: XCTestCase {
    func testTransferHostNormalizationMatchesAliases() {
        XCTAssertEqual(
            normalizedGraphicsTransferHost("Desktop.Example.COM."),
            normalizedGraphicsTransferHost("desktop.example.com")
        )
        XCTAssertEqual(
            normalizedGraphicsTransferHost("[2001:DB8::1]"),
            normalizedGraphicsTransferHost("2001:db8::1")
        )
    }

    func testTargetSelectionPrefersSingleDirectSessionOverProxyJump() throws {
        let proxyTarget = GraphicsSSHUploadTarget(
            runtimeID: "term_proxy",
            context: Self.liveContext(proxyJump: Self.proxyJump())
        )
        let directTarget = GraphicsSSHUploadTarget(
            runtimeID: "term_direct",
            context: Self.liveContext()
        )

        let selected = try GraphicsFileUploadCoordinator.selectTarget(
            from: [proxyTarget, directTarget]
        )

        XCTAssertEqual(selected.runtimeID, "term_direct")
    }

    func testTargetSelectionRejectsMultipleDirectSessions() {
        let targets = [
            GraphicsSSHUploadTarget(runtimeID: "term_one", context: Self.liveContext()),
            GraphicsSSHUploadTarget(runtimeID: "term_two", context: Self.liveContext())
        ]

        XCTAssertThrowsError(try GraphicsFileUploadCoordinator.selectTarget(from: targets)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "检测到多个同一主机的 SSH 连接，请仅保留目标连接后重试"
            )
        }
    }

    func testUploadPreparesPrivateRemoteFileBeforeScheduling() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-prepare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFile = temporaryDirectory.appendingPathComponent("private.txt")
        try Data("secret".utf8).write(to: localFile)

        let preparedPaths = LockedStringArray()
        let coordinator = GraphicsFileUploadCoordinator(
            remoteDirectoryLoader: { _, _ in [] },
            remoteFilePreparer: { _, path in
                preparedPaths.append(path)
            }
        )
        let scheduler = RecordingGraphicsUploadScheduler()
        let scheduled = expectation(description: "scheduled after preparation")
        scheduler.onJobScheduled = {
            XCTAssertEqual(preparedPaths.values, ["/tmp/private.txt"])
            scheduled.fulfill()
        }

        coordinator.upload(
            localPaths: [localFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { _ in }

        wait(for: [scheduled], timeout: 2.0)
    }

    func testBatchSerializesRemoteFilePreparation() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-serial-prepare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFiles = (1...4).map { temporaryDirectory.appendingPathComponent("file-\($0).txt") }
        for file in localFiles {
            try Data("content".utf8).write(to: file)
        }

        let preparationGauge = LockedConcurrencyGauge()
        let coordinator = GraphicsFileUploadCoordinator(
            remoteDirectoryLoader: { _, _ in [] },
            remoteFilePreparer: { _, _ in
                preparationGauge.enter()
                defer { preparationGauge.leave() }
                Thread.sleep(forTimeInterval: 0.02)
            },
            remoteFileCleaner: { _, _ in }
        )
        let scheduler = RecordingGraphicsUploadScheduler()
        let completion = expectation(description: "serialized batch completion")

        coordinator.upload(
            localPaths: localFiles.map(\.path),
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .failure(let error) = result {
                XCTFail("expected success, got \(error)")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertEqual(preparationGauge.maximum, 1)
        XCTAssertEqual(scheduler.jobs.count, 4)
    }

    func testPreparedRemoteFileIsCleanedWhenTargetClosesBeforeScheduling() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFile = temporaryDirectory.appendingPathComponent("cleanup.txt")
        try Data("content".utf8).write(to: localFile)

        let preparedPaths = LockedStringArray()
        let cleanedPaths = LockedStringArray()
        let coordinator = GraphicsFileUploadCoordinator(
            remoteDirectoryLoader: { _, _ in [] },
            remoteFilePreparer: { _, path in preparedPaths.append(path) },
            remoteFileCleaner: { _, path in cleanedPaths.append(path) }
        )
        let targetStates = LockedBooleanSequence([true, false])
        let scheduler = RecordingGraphicsUploadScheduler()
        let completion = expectation(description: "cleanup completion")

        coordinator.upload(
            localPaths: [localFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { targetStates.next() }
        ) { _ in
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertEqual(preparedPaths.values, ["/tmp/cleanup.txt"])
        XCTAssertEqual(cleanedPaths.values, ["/tmp/cleanup.txt"])
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testDirectoryDropIsRejectedBeforeRemoteWork() throws {
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }

        let coordinator = makeCoordinator(remoteDirectoryLoader: { _, _ in
            XCTFail("directory drop must not list remote files")
            return []
        })
        let scheduler = RecordingGraphicsUploadScheduler()
        let completion = expectation(description: "directory rejection")
        var failureMessage = ""

        coordinator.upload(
            localPaths: [localDirectory.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .failure(let error) = result {
                failureMessage = error.localizedDescription
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertEqual(failureMessage, "VNC 拖传暂不支持文件夹，请选择文件")
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testOptionLikeFileNameIsRejectedBeforeRemoteWork() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFile = temporaryDirectory.appendingPathComponent("-report.txt")
        try Data("content".utf8).write(to: localFile)

        let coordinator = makeCoordinator(remoteDirectoryLoader: { _, _ in
            XCTFail("unsupported name must not list remote files")
            return []
        })
        let scheduler = RecordingGraphicsUploadScheduler()
        let completion = expectation(description: "unsafe name rejection")
        var failureMessage = ""

        coordinator.upload(
            localPaths: [localFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .failure(let error) = result {
                failureMessage = error.localizedDescription
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertEqual(failureMessage, "文件名不受 SCP 安全规则支持，请重命名后重试")
        XCTAssertTrue(scheduler.jobs.isEmpty)
    }

    func testExistingRemoteConflictIsSkippedWithoutOverwrite() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFile = temporaryDirectory.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: localFile)

        let scheduler = RecordingGraphicsUploadScheduler()
        let coordinator = makeCoordinator(remoteDirectoryLoader: { _, _ in
            [
                RemoteFileEntry(
                    kind: .file,
                    path: "/tmp/report.txt",
                    size: 10,
                    modifiedTime: nil,
                    linkTarget: nil,
                    owner: nil,
                    permissions: nil
                )
            ]
        })
        let completion = expectation(description: "conflict completion")
        var failureMessage = ""

        coordinator.upload(
            localPaths: [localFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .failure(let error) = result {
                failureMessage = error.localizedDescription
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertEqual(failureMessage, "部分文件未加入上传队列")
    }

    func testConcurrentBatchesReserveDestinationAcrossRuntimeReattachment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-reservation-\(UUID().uuidString)", isDirectory: true)
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = firstDirectory.appendingPathComponent("report.txt")
        let secondFile = secondDirectory.appendingPathComponent("report.txt")
        try Data("first".utf8).write(to: firstFile)
        try Data("second".utf8).write(to: secondFile)

        let firstScheduled = expectation(description: "first scheduled")
        let scheduler = RecordingGraphicsUploadScheduler(terminalStatus: nil)
        scheduler.onJobScheduled = { firstScheduled.fulfill() }
        let coordinator = makeCoordinator(remoteDirectoryLoader: { _, _ in [] })
        coordinator.upload(
            localPaths: [firstFile.path],
            target: GraphicsSSHUploadTarget(
                runtimeID: "term_vnc_host",
                context: Self.liveContext(host: "Desktop.Example.COM.")
            ),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { _ in }
        wait(for: [firstScheduled], timeout: 2.0)

        scheduler.onJobScheduled = nil
        let secondCompletion = expectation(description: "second batch completion")
        var secondFailure = ""
        coordinator.upload(
            localPaths: [secondFile.path],
            target: GraphicsSSHUploadTarget(
                runtimeID: "term_vnc_host_reattached",
                context: Self.liveContext(host: "desktop.example.com")
            ),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .failure(let error) = result {
                secondFailure = error.localizedDescription
            }
            secondCompletion.fulfill()
        }

        wait(for: [secondCompletion], timeout: 2.0)
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(secondFailure, "部分文件未加入上传队列")
    }

    func testCompletedJobMissingFromActiveSnapshotIsNotMarkedFailed() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let firstFile = temporaryDirectory.appendingPathComponent("first.txt")
        let secondFile = temporaryDirectory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: firstFile)
        try Data("second".utf8).write(to: secondFile)

        let scheduler = ConcurrentSuccessGraphicsUploadScheduler()
        let coordinator = makeCoordinator(remoteDirectoryLoader: { _, _ in [] })
        let completion = expectation(description: "concurrent success")
        var resultPaths: [String] = []

        coordinator.upload(
            localPaths: [firstFile.path, secondFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .success(let paths) = result {
                resultPaths = paths
            } else {
                XCTFail("expected both uploads to succeed")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertEqual(resultPaths.count, 2)
    }

    func testDuplicateBasenamesAreRejectedBeforeScheduling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-duplicates-\(UUID().uuidString)", isDirectory: true)
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = firstDirectory.appendingPathComponent("report.txt")
        let secondFile = secondDirectory.appendingPathComponent("report.txt")
        try Data("first".utf8).write(to: firstFile)
        try Data("second".utf8).write(to: secondFile)

        let scheduler = RecordingGraphicsUploadScheduler()
        let coordinator = makeCoordinator(remoteDirectoryLoader: { _, _ in [] })
        let completion = expectation(description: "duplicate upload completion")
        var failureMessage = ""

        coordinator.upload(
            localPaths: [firstFile.path, secondFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .failure(let error) = result {
                failureMessage = error.localizedDescription
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertEqual(failureMessage, "拖入的文件包含同名项，请分开上传")
    }

    func testInactiveTargetAfterListingDoesNotScheduleUpload() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-inactive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFile = temporaryDirectory.appendingPathComponent("report.txt")
        try Data("content".utf8).write(to: localFile)

        let listingStarted = expectation(description: "listing started")
        let allowListingToFinish = DispatchSemaphore(value: 0)
        let scheduler = RecordingGraphicsUploadScheduler()
        let coordinator = makeCoordinator(remoteDirectoryLoader: { _, _ in
            listingStarted.fulfill()
            allowListingToFinish.wait()
            return []
        })
        let completion = expectation(description: "inactive target completion")
        var isTargetActive = true
        var failureMessage = ""

        coordinator.upload(
            localPaths: [localFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { isTargetActive }
        ) { result in
            if case .failure(let error) = result {
                failureMessage = error.localizedDescription
            }
            completion.fulfill()
        }

        wait(for: [listingStarted], timeout: 2.0)
        isTargetActive = false
        allowListingToFinish.signal()
        wait(for: [completion], timeout: 2.0)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertEqual(failureMessage, "请先建立同一主机的 SSH 连接以使用文件传输功能")
    }

    func testCanceledTransferCleansPreparedRemoteFile() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-canceled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFile = temporaryDirectory.appendingPathComponent("canceled.txt")
        try Data("content".utf8).write(to: localFile)

        let cleanedPaths = LockedStringArray()
        let coordinator = GraphicsFileUploadCoordinator(
            remoteDirectoryLoader: { _, _ in [] },
            remoteFilePreparer: { _, _ in },
            remoteFileCleaner: { _, path in cleanedPaths.append(path) }
        )
        let scheduler = RecordingGraphicsUploadScheduler(
            terminalStatus: nil,
            snapshotTerminalStatus: "canceled"
        )
        let completion = expectation(description: "canceled transfer completion")

        coordinator.upload(
            localPaths: [localFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .success = result {
                XCTFail("expected canceled upload to fail")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertEqual(cleanedPaths.values, ["/tmp/canceled.txt"])
    }

    func testStoppedTransferCompletesBatchAsFailure() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-stopped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFile = temporaryDirectory.appendingPathComponent("stopped.txt")
        try Data("content".utf8).write(to: localFile)

        let scheduler = RecordingGraphicsUploadScheduler(
            terminalStatus: nil,
            snapshotTerminalStatus: "stopped"
        )
        let cleanedPaths = LockedStringArray()
        let coordinator = GraphicsFileUploadCoordinator(
            remoteDirectoryLoader: { _, _ in [] },
            remoteFilePreparer: { _, _ in },
            remoteFileCleaner: { _, path in cleanedPaths.append(path) }
        )
        let completion = expectation(description: "stopped transfer completion")
        var failureMessage = ""

        coordinator.upload(
            localPaths: [localFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .failure(let error) = result {
                failureMessage = error.localizedDescription
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertEqual(failureMessage, "文件上传失败")
        XCTAssertEqual(cleanedPaths.values, ["/tmp/stopped.txt"])
    }

    func testUploadUsesAssociatedSSHRuntimeAndReturnsRemotePath() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFile = temporaryDirectory.appendingPathComponent("report.txt")
        try Data("content".utf8).write(to: localFile)

        let scheduler = RecordingGraphicsUploadScheduler()
        let coordinator = makeCoordinator(remoteDirectoryLoader: { _, path in
            XCTAssertEqual(path, "/tmp")
            return []
        })
        let completion = expectation(description: "upload completion")
        var uploadedPaths: [String] = []

        coordinator.upload(
            localPaths: [localFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .success(let paths) = result {
                uploadedPaths = paths
            } else {
                XCTFail("expected upload success")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertEqual(scheduler.runtimeIDs, ["term_vnc_host"])
        XCTAssertEqual(scheduler.jobs.map(\.sourcePath), [localFile.path])
        XCTAssertEqual(scheduler.jobs.map(\.destinationPath), ["/tmp/report.txt"])
        XCTAssertEqual(uploadedPaths, ["/tmp/report.txt"])
    }

    func testUploadReportsTransferFailure() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-vnc-upload-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let localFile = temporaryDirectory.appendingPathComponent("failed.txt")
        try Data("content".utf8).write(to: localFile)

        let scheduler = RecordingGraphicsUploadScheduler(terminalStatus: "failed")
        let cleanedPaths = LockedStringArray()
        let coordinator = GraphicsFileUploadCoordinator(
            remoteDirectoryLoader: { _, _ in [] },
            remoteFilePreparer: { _, _ in },
            remoteFileCleaner: { _, path in cleanedPaths.append(path) }
        )
        let completion = expectation(description: "upload failure")
        var failureMessage = ""

        coordinator.upload(
            localPaths: [localFile.path],
            target: GraphicsSSHUploadTarget(runtimeID: "term_vnc_host", context: Self.liveContext()),
            transferScheduler: scheduler,
            isTargetActive: { true }
        ) { result in
            if case .failure(let error) = result {
                failureMessage = error.localizedDescription
            } else {
                XCTFail("expected upload failure")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2.0)
        XCTAssertEqual(failureMessage, "文件上传失败")
        XCTAssertEqual(cleanedPaths.values, ["/tmp/failed.txt"])
    }

    private func makeCoordinator(
        remoteDirectoryLoader: @escaping GraphicsFileUploadCoordinator.RemoteDirectoryLoader
    ) -> GraphicsFileUploadCoordinator {
        GraphicsFileUploadCoordinator(
            remoteDirectoryLoader: remoteDirectoryLoader,
            remoteFilePreparer: { _, _ in },
            remoteFileCleaner: { _, _ in }
        )
    }

    private static func liveContext(
        host: String = "desktop.example.com",
        proxyJump: SshProxyJumpRuntimeConfig? = nil
    ) -> TunnelLiveSessionContext {
        TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: host,
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:desktop",
            proxyJump: proxyJump
        )
    }

    private static func proxyJump() -> SshProxyJumpRuntimeConfig {
        SshProxyJumpRuntimeConfig(
            jumpConfig: SshConnectionConfig(
                host: "bastion.example.com",
                port: 22,
                username: "jump",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            jumpSecret: .agent,
            jumpExpectedFingerprintSha256: "SHA256:bastion",
            targetExpectedFingerprintSha256: "SHA256:desktop"
        )
    }
}

private final class LockedConcurrencyGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maximumValue = 0

    var maximum: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumValue
    }

    func enter() {
        lock.lock()
        current += 1
        maximumValue = max(maximumValue, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}

private final class LockedBooleanSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return false }
        return values.removeFirst()
    }
}

private final class LockedStringArray: @unchecked Sendable {
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

@MainActor
private final class RecordingGraphicsUploadScheduler: SCPTransferScheduling, GraphicsTransferQueueObserving {
    private let terminalStatus: String?
    private let snapshotTerminalStatus: String?
    private(set) var runtimeIDs: [String] = []
    private(set) var jobs: [ScpTransferJob] = []
    var onJobScheduled: (() -> Void)?
    private var snapshotObservers: [UUID: (TransferQueueSnapshot) -> Void] = [:]

    init(terminalStatus: String? = "completed", snapshotTerminalStatus: String? = nil) {
        self.terminalStatus = terminalStatus
        self.snapshotTerminalStatus = snapshotTerminalStatus
    }

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        runtimeIDs.append(runtimeID)
        jobs.append(job)
        onJobScheduled?()
        publishSnapshot(job: job, status: "queued")
        if let terminalStatus {
            completion?(
                ScpTransferProgress(
                    jobId: job.id,
                    bytesDone: job.bytesTotal,
                    bytesTotal: job.bytesTotal,
                    status: terminalStatus
                )
            )
        }
        if let snapshotTerminalStatus {
            publishSnapshot(job: job, status: snapshotTerminalStatus)
        }
    }

    func disconnectTransfers(runtimeID: String) -> [String] { [] }

    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {}

    @discardableResult
    func observeQueue(
        runtimeIDs: @escaping () -> Set<String>,
        handler observer: @escaping (TransferQueueSnapshot) -> Void
    ) -> UUID {
        _ = runtimeIDs()
        let token = UUID()
        snapshotObservers[token] = observer
        observer(TransferQueueSnapshot(rows: []))
        return token
    }

    func removeQueueObservation(_ token: UUID) {
        snapshotObservers.removeValue(forKey: token)
    }

    private func publishSnapshot(job: ScpTransferJob, status: String) {
        let snapshot = TransferQueueSnapshot(
            rows: [
                TransferQueueSnapshot.Row(
                    jobID: job.id,
                    direction: job.direction,
                    sourcePath: job.sourcePath,
                    destinationPath: job.destinationPath,
                    bytesDone: status == "completed" ? job.bytesTotal : 0,
                    bytesTotal: job.bytesTotal,
                    rawStatus: status,
                    diagnostic: nil
                )
            ]
        )
        let observers = Array(snapshotObservers.values)
        for observer in observers {
            observer(snapshot)
        }
    }
}

@MainActor
private final class ConcurrentSuccessGraphicsUploadScheduler: SCPTransferScheduling, GraphicsTransferQueueObserving {
    private var scheduled: [(job: ScpTransferJob, completion: ((ScpTransferProgress) -> Void)?)] = []
    private var snapshotObservers: [UUID: (TransferQueueSnapshot) -> Void] = [:]

    func scheduleLiveTransfer(
        runtimeID: String,
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        job: ScpTransferJob,
        completion: ((ScpTransferProgress) -> Void)?
    ) {
        scheduled.append((job, completion))
        publish(rows: scheduled.map { row(job: $0.job, status: "queued") })
        guard scheduled.count == 2 else { return }

        let first = scheduled[0]
        let second = scheduled[1]
        publish(rows: [row(job: second.job, status: "running")])
        first.completion?(completedProgress(for: first.job))
        publish(rows: [row(job: second.job, status: "completed")])
        second.completion?(completedProgress(for: second.job))
    }

    func disconnectTransfers(runtimeID: String) -> [String] { [] }

    func updateScheduledTransferEstimatedByteTotal(jobID: String, bytesTotal: UInt64) {}

    @discardableResult
    func observeQueue(
        runtimeIDs: @escaping () -> Set<String>,
        handler observer: @escaping (TransferQueueSnapshot) -> Void
    ) -> UUID {
        _ = runtimeIDs()
        let token = UUID()
        snapshotObservers[token] = observer
        observer(TransferQueueSnapshot(rows: []))
        return token
    }

    func removeQueueObservation(_ token: UUID) {
        snapshotObservers.removeValue(forKey: token)
    }

    private func completedProgress(for job: ScpTransferJob) -> ScpTransferProgress {
        ScpTransferProgress(
            jobId: job.id,
            bytesDone: job.bytesTotal,
            bytesTotal: job.bytesTotal,
            status: "completed"
        )
    }

    private func row(job: ScpTransferJob, status: String) -> TransferQueueSnapshot.Row {
        TransferQueueSnapshot.Row(
            jobID: job.id,
            direction: job.direction,
            sourcePath: job.sourcePath,
            destinationPath: job.destinationPath,
            bytesDone: status == "completed" ? job.bytesTotal : 0,
            bytesTotal: job.bytesTotal,
            rawStatus: status,
            diagnostic: nil
        )
    }

    private func publish(rows: [TransferQueueSnapshot.Row]) {
        let snapshot = TransferQueueSnapshot(rows: rows)
        let observers = Array(snapshotObservers.values)
        for observer in observers {
            observer(snapshot)
        }
    }
}
