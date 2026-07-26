import Foundation
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class RemoteChromiumRuntimeTests: XCTestCase {
    func testLaunchUsesKnownChromiumBinariesAndNeverAcceptsAUserURL() {
        let command = RemoteChromiumRuntime.launchCommand

        XCTAssertTrue(command.contains("chromium chromium-browser google-chrome google-chrome-stable"))
        XCTAssertTrue(command.contains("--remote-debugging-address=127.0.0.1"))
        XCTAssertTrue(command.contains("--remote-debugging-port=0"))
        XCTAssertTrue(command.contains("about:blank"))
        XCTAssertFalse(command.contains("example.com"))
        XCTAssertFalse(command.contains("--no-sandbox"))
        XCTAssertTrue(command.contains("__STACIO_CHROMIUM_ERROR__=root_not_supported"))
    }

    func testLaunchReportsOwnedDirectoryAndPIDBeforeWaitingForDevTools() throws {
        let command = RemoteChromiumRuntime.launchCommand
        let directoryMarker = try XCTUnwrap(command.range(of: "__STACIO_CHROMIUM_DIR__"))
        let makeProfile = try XCTUnwrap(command.range(of: "mkdir -p"))
        let pidMarker = try XCTUnwrap(command.range(of: "__STACIO_CHROMIUM_PID__"))
        let readinessLoop = try XCTUnwrap(command.range(of: "STACIO_CHROMIUM_ATTEMPT=0"))

        XCTAssertLessThan(directoryMarker.lowerBound, makeProfile.lowerBound)
        XCTAssertLessThan(pidMarker.lowerBound, readinessLoop.lowerBound)
    }

    func testStartParsesRecordedResourcesAndCreatesLoopbackCDPTunnel() throws {
        let executor = RecordingRemoteChromiumCommandExecutor(outputs: [Self.launchOutput])
        let tunnelBridge = RecordingRemoteChromiumTunnelBridge()
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: tunnelBridge,
            pageEndpointResolver: { localPort in
                URL(string: "ws://127.0.0.1:\(localPort)/devtools/page/page-1")!
            },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )

        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)

        XCTAssertEqual(executor.commands, [RemoteChromiumRuntime.launchCommand])
        XCTAssertEqual(session.remoteProcessID, 4_242)
        XCTAssertEqual(session.remoteTemporaryDirectory, "/tmp/stacio-chromium.AbC123")
        XCTAssertEqual(session.remoteDownloadsDirectory, "/tmp/stacio-chromium.AbC123/downloads")
        XCTAssertNotEqual(session.leaseID, UUID())
        XCTAssertEqual(session.pageWebSocketURL.absoluteString, "ws://127.0.0.1:19090/devtools/page/page-1")
        XCTAssertEqual(tunnelBridge.startedProfiles.count, 1)
        XCTAssertEqual(tunnelBridge.startedProfiles.first?.kind, .local)
        XCTAssertEqual(tunnelBridge.startedProfiles.first?.localHost, "127.0.0.1")
        XCTAssertEqual(tunnelBridge.startedProfiles.first?.localPort, 19_090)
        XCTAssertEqual(tunnelBridge.startedProfiles.first?.remoteHost, "127.0.0.1")
        XCTAssertEqual(tunnelBridge.startedProfiles.first?.remotePort, 43_210)
    }

    func testStopOnlyTargetsTheRecordedPIDDirectoryAndTunnel() throws {
        let executor = RecordingRemoteChromiumCommandExecutor(outputs: [Self.launchOutput, ""])
        let tunnelBridge = RecordingRemoteChromiumTunnelBridge()
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: tunnelBridge,
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1:19090/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)

        runtime.stop(session: session)

        XCTAssertEqual(tunnelBridge.stoppedProfiles.map(\.id), tunnelBridge.startedProfiles.map(\.id))
        XCTAssertEqual(executor.commands.count, 2)
        XCTAssertTrue(executor.commands[1].contains("kill '4242'"))
        XCTAssertTrue(executor.commands[1].contains("rm -rf -- '/tmp/stacio-chromium.AbC123'"))
        XCTAssertTrue(executor.commands[1].contains("--user-data-dir=/tmp/stacio-chromium.AbC123/profile"))
        XCTAssertTrue(executor.commands[1].contains("id -u"))
        XCTAssertFalse(executor.commands[1].contains("example.com"))
    }

    func testStoppingAnOlderLeaseCannotStopOrCleanANewerRuntime() throws {
        let secondLaunchOutput = """
        __STACIO_CHROMIUM_PID__=5252
        __STACIO_CHROMIUM_DIR__=/tmp/stacio-chromium.XyZ789
        __STACIO_CHROMIUM_PORT__=43211
        __STACIO_CHROMIUM_BINARY__=/usr/bin/chromium
        """
        let executor = RecordingRemoteChromiumCommandExecutor(
            outputs: [Self.launchOutput, secondLaunchOutput, "", ""]
        )
        let tunnelBridge = RecordingRemoteChromiumTunnelBridge()
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: tunnelBridge,
            pageEndpointResolver: { port in URL(string: "ws://127.0.0.1:\(port)/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )

        let older = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let newer = try runtime.start(context: Self.liveContext, localPort: 19_091)
        runtime.stop(session: older)

        XCTAssertEqual(tunnelBridge.stoppedProfiles.map(\.id), [tunnelBridge.startedProfiles[0].id])
        XCTAssertTrue(executor.commands.last?.contains("kill '4242'") == true)
        XCTAssertFalse(executor.commands.last?.contains("5252") == true)

        runtime.stop(session: newer)
        XCTAssertEqual(tunnelBridge.stoppedProfiles.map(\.id), tunnelBridge.startedProfiles.map(\.id))
        XCTAssertTrue(executor.commands.last?.contains("kill '5252'") == true)
    }

    func testRejectsLaunchMetadataOutsideOwnedTemporaryDirectory() {
        let executor = RecordingRemoteChromiumCommandExecutor(outputs: [
            """
            __STACIO_CHROMIUM_PID__=4242
            __STACIO_CHROMIUM_DIR__=/tmp/other-product
            __STACIO_CHROMIUM_PORT__=43210
            __STACIO_CHROMIUM_BINARY__=/usr/bin/chromium
            """
        ])
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )

        XCTAssertThrowsError(try runtime.start(context: Self.liveContext, localPort: 19_090)) { error in
            XCTAssertEqual(error as? RemoteChromiumRuntimeError, .invalidLaunchMetadata)
        }
        XCTAssertEqual(executor.commands.count, 1, "Untrusted metadata must never be interpolated into cleanup shell.")
    }

    func testTunnelFailureCleansUpOnlyValidatedRemoteResources() {
        let executor = RecordingRemoteChromiumCommandExecutor(outputs: [Self.launchOutput, ""])
        let tunnelBridge = RecordingRemoteChromiumTunnelBridge(startError: TestRemoteChromiumError.failed)
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: tunnelBridge,
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )

        XCTAssertThrowsError(try runtime.start(context: Self.liveContext, localPort: 19_090))
        XCTAssertEqual(executor.commands.count, 2)
        XCTAssertTrue(executor.commands[1].contains("kill '4242'"))
        XCTAssertTrue(executor.commands[1].contains("'/tmp/stacio-chromium.AbC123'"))
    }

    func testInvalidMetadataCleansValidatedPartialResources() {
        let partialOutput = """
        __STACIO_CHROMIUM_PID__=4242
        __STACIO_CHROMIUM_DIR__=/tmp/stacio-chromium.AbC123
        __STACIO_CHROMIUM_PORT__=not-a-port
        """
        let executor = RecordingRemoteChromiumCommandExecutor(outputs: [partialOutput, ""])
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )

        XCTAssertThrowsError(try runtime.start(context: Self.liveContext, localPort: 19_090))
        XCTAssertEqual(executor.commands.count, 2)
        XCTAssertTrue(executor.commands[1].contains("kill '4242'"))
        XCTAssertTrue(executor.commands[1].contains("'/tmp/stacio-chromium.AbC123'"))
    }

    func testInvalidMetadataWithOnlyOwnedDirectoryRemovesDirectoryWithoutKillingPID() {
        let partialOutput = """
        __STACIO_CHROMIUM_DIR__=/tmp/stacio-chromium.AbC123
        __STACIO_CHROMIUM_PORT__=not-a-port
        """
        let executor = RecordingRemoteChromiumCommandExecutor(outputs: [partialOutput, ""])
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )

        XCTAssertThrowsError(try runtime.start(context: Self.liveContext, localPort: 19_090))
        XCTAssertEqual(executor.commands.count, 2)
        XCTAssertTrue(executor.commands[1].contains("rm -rf -- '/tmp/stacio-chromium.AbC123'"))
        XCTAssertFalse(executor.commands[1].contains("kill "))
    }

    func testTimedOutLaunchCleansResourcesRecoveredFromPartialOutput() {
        let partialOutput = """
        __STACIO_CHROMIUM_PID__=4242
        __STACIO_CHROMIUM_DIR__=/tmp/stacio-chromium.AbC123
        """
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .failure(
                RemoteChromiumCommandExecutionFailure(
                    error: .commandTimedOut,
                    partialOutput: partialOutput
                )
            ),
            .success("")
        ])
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )

        XCTAssertThrowsError(try runtime.start(context: Self.liveContext, localPort: 19_090))
        XCTAssertEqual(executor.commands.count, 2)
        XCTAssertTrue(executor.commands[1].contains("kill '4242'"))
    }

    func testCommandBridgeFailurePreservesPartialLaunchOutputForCleanup() {
        let partialOutput = """
        __STACIO_CHROMIUM_DIR__=/tmp/stacio-chromium.AbC123
        __STACIO_CHROMIUM_PID__=4242
        """
        let executor = CoreRemoteChromiumCommandExecutor(
            shellStarter: RecordingRemoteChromiumLiveShellStarter(),
            runtimeBridge: FailingAfterPartialOutputRuntimeBridge(output: partialOutput),
            pollInterval: 0
        )

        XCTAssertThrowsError(
            try executor.execute(
                command: RemoteChromiumRuntime.launchCommand,
                context: Self.liveContext,
                timeout: 1
            )
        ) { error in
            let failure = error as? RemoteChromiumCommandExecutionFailure
            XCTAssertEqual(failure?.error, .commandFailed("bridge failed"))
            XCTAssertTrue(failure?.partialOutput.contains("__STACIO_CHROMIUM_PID__=4242") == true)
        }
    }

    func testFailedPartialLaunchCleanupIsRetriedBeforeTheNextLaunchWithoutReplacingOriginalError() throws {
        let invalidOutput = """
        __STACIO_CHROMIUM_PID__=4242
        __STACIO_CHROMIUM_DIR__=/tmp/stacio-chromium.AbC123
        __STACIO_CHROMIUM_PORT__=not-a-port
        """
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .success(invalidOutput),
            .failure(TestRemoteChromiumError.failed),
            .success(""),
            .success(Self.launchOutput),
            .success("")
        ])
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )

        XCTAssertThrowsError(try runtime.start(context: Self.liveContext, localPort: 19_090)) { error in
            XCTAssertEqual(error as? RemoteChromiumRuntimeError, .invalidLaunchMetadata)
        }

        let session = try runtime.start(context: Self.liveContext, localPort: 19_091)

        XCTAssertEqual(session.remoteProcessID, 4_242)
        XCTAssertEqual(executor.commands.prefix(4).filter { $0 == RemoteChromiumRuntime.launchCommand }.count, 2)
        XCTAssertTrue(executor.commands[1].contains("kill '4242'"))
        XCTAssertTrue(executor.commands[2].contains("kill '4242'"))
        runtime.stop(session: session)
    }

    func testStopRetriesResourcesWhoseCleanupFailed() throws {
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .success(Self.launchOutput),
            .failure(TestRemoteChromiumError.failed),
            .success("")
        ])
        let tunnelBridge = RecordingRemoteChromiumTunnelBridge(
            stopResults: [
                .failure(TestRemoteChromiumError.failed),
                .success(TunnelRuntimeStatus(profileId: "placeholder", state: .stopped, message: "stopped"))
            ]
        )
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: tunnelBridge,
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)

        runtime.stop(session: session)
        runtime.stop(session: session)

        XCTAssertEqual(tunnelBridge.stoppedProfiles.count, 2)
        XCTAssertEqual(executor.commands.count, 3)
        XCTAssertTrue(executor.commands.dropFirst().allSatisfy { $0.contains("kill '4242'") })
    }

    func testStopCleanupFailuresAreWrittenToDiagnostics() throws {
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .success(Self.launchOutput),
            .failure(TestRemoteChromiumError.failed)
        ])
        let tunnelBridge = RecordingRemoteChromiumTunnelBridge(
            stopResults: [.failure(TestRemoteChromiumError.failed)]
        )
        let log = RecordingRemoteChromiumLog()
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: tunnelBridge,
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0,
            diagnosticLog: log
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)

        runtime.stop(session: session)

        XCTAssertTrue(
            log.messages.contains {
                $0.contains("remote.chromium.cleanup.failed stage=stop")
                    && $0.contains("tunnel=")
                    && $0.contains("browser=")
            }
        )
    }

    func testStopCleanupFailureRetriesAutomaticallyWithoutAnotherLifecycleCall() async throws {
        let retriedTunnelCleanup = expectation(description: "tunnel cleanup retried")
        let retriedBrowserCleanup = expectation(description: "browser cleanup retried")
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .success(Self.launchOutput),
            .failure(TestRemoteChromiumError.failed),
            .success("")
        ])
        executor.commandExpectations = [nil, nil, retriedBrowserCleanup]
        let tunnelBridge = RecordingRemoteChromiumTunnelBridge(
            stopResults: [
                .failure(TestRemoteChromiumError.failed),
                .success(TunnelRuntimeStatus(profileId: "placeholder", state: .stopped, message: "stopped"))
            ]
        )
        tunnelBridge.stopExpectations = [nil, retriedTunnelCleanup]
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: tunnelBridge,
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            cleanupRetryDelays: [0.01],
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)

        runtime.stop(session: session)

        await fulfillment(of: [retriedTunnelCleanup, retriedBrowserCleanup], timeout: 1)
        XCTAssertEqual(tunnelBridge.stoppedProfiles.count, 2)
        XCTAssertEqual(executor.commands.count, 3)
    }

    func testFailedDownloadAcknowledgementRetriesAutomaticallyBeforeReleasingOwnership() async throws {
        let retryCompleted = expectation(description: "download cleanup retried")
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .success(Self.launchOutput),
            .failure(TestRemoteChromiumError.failed),
            .success("")
        ])
        executor.commandExpectations = [nil, nil, retryCompleted]
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            cleanupRetryDelays: [0.01],
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/download-guid",
            suggestedFilename: "report.pdf"
        )
        XCTAssertTrue(runtime.retainDownload(download))
        let acknowledged = expectation(description: "ack succeeds after retry")

        XCTAssertTrue(runtime.acknowledgeDownload(download) { result in
            if case let .failure(error) = result {
                XCTFail("Automatic acknowledgement retry failed: \(error)")
            }
            acknowledged.fulfill()
        })
        XCTAssertFalse(runtime.acknowledgeDownload(download) { _ in })

        await fulfillment(of: [retryCompleted, acknowledged], timeout: 1)
        XCTAssertFalse(runtime.acknowledgeDownload(download) { _ in })
    }

    func testRetainDownloadReturnsWhileLifecycleQueueIsBusyWithRemoteCleanup() async throws {
        let cleanupEntered = expectation(description: "download cleanup entered")
        let executor = BlockingRemoteChromiumAcknowledgementExecutor(
            launchOutput: Self.launchOutput,
            cleanupEntered: cleanupEntered
        )
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let first = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/first-guid",
            suggestedFilename: "first.txt"
        )
        let second = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/second-guid",
            suggestedFilename: "second.txt"
        )
        XCTAssertTrue(runtime.retainDownload(first))
        XCTAssertTrue(runtime.acknowledgeDownload(first) { _ in })
        await fulfillment(of: [cleanupEntered], timeout: 1)

        let retainCompleted = DispatchSemaphore(value: 0)
        let retained = LockedBoolean()
        let runtimeBox = TestUncheckedSendable(value: runtime)
        DispatchQueue.global(qos: .userInitiated).async {
            retained.value = runtimeBox.value.retainDownload(second)
            retainCompleted.signal()
        }

        XCTAssertEqual(
            retainCompleted.wait(timeout: .now() + 0.1),
            .success,
            "A download completion callback must not wait behind a remote cleanup command."
        )
        XCTAssertTrue(retained.value)
        executor.releaseCleanup()
    }

    func testExhaustedDownloadCleanupIsRetriedByNextCloseFromRecoverableRegistry() async throws {
        let acknowledgementExhausted = expectation(description: "ack cleanup exhausted")
        let closeRetriedDownloadCleanup = expectation(description: "close retried download cleanup")
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .success(Self.launchOutput),
            .failure(TestRemoteChromiumError.failed),
            .failure(TestRemoteChromiumError.failed),
            .success(""),
            .success("")
        ])
        executor.commandExpectations = [nil, nil, nil, nil, closeRetriedDownloadCleanup]
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            cleanupRetryDelays: [0.01],
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/download-guid",
            suggestedFilename: "report.pdf"
        )
        XCTAssertTrue(runtime.retainDownload(download))
        XCTAssertTrue(runtime.acknowledgeDownload(download) { result in
            if case .failure = result {
                acknowledgementExhausted.fulfill()
            } else {
                XCTFail("The scripted acknowledgement cleanup must exhaust its retry budget")
            }
        })
        await fulfillment(of: [acknowledgementExhausted], timeout: 1)

        runtime.stop(session: session)

        await fulfillment(of: [closeRetriedDownloadCleanup], timeout: 1)
        XCTAssertFalse(runtime.acknowledgeDownload(download) { _ in })
        XCTAssertEqual(executor.commands.count, 5)
    }

    func testRuntimeDeinitRetriesExhaustedVerifiedDownloadCleanup() async throws {
        let acknowledgementExhausted = expectation(description: "ack cleanup exhausted")
        let deinitRetriedDownloadCleanup = expectation(description: "deinit retried download cleanup")
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .success(Self.launchOutput),
            .failure(TestRemoteChromiumError.failed),
            .failure(TestRemoteChromiumError.failed),
            .success(""),
            .success("")
        ])
        executor.commandExpectations = [nil, nil, nil, nil, deinitRetriedDownloadCleanup]
        var runtime: RemoteChromiumRuntime? = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            cleanupRetryDelays: [0.01],
            pollInterval: 0
        )
        let session = try XCTUnwrap(runtime).start(context: Self.liveContext, localPort: 19_090)
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/download-guid",
            suggestedFilename: "report.pdf"
        )
        XCTAssertTrue(runtime?.retainDownload(download) == true)
        XCTAssertTrue(runtime?.acknowledgeDownload(download) { result in
            if case .failure = result { acknowledgementExhausted.fulfill() }
        } == true)
        await fulfillment(of: [acknowledgementExhausted], timeout: 1)

        runtime = nil

        await fulfillment(of: [deinitRetriedDownloadCleanup], timeout: 1)
        XCTAssertEqual(executor.commands.count, 5)
    }

    func testChromeDevToolsDecoderExtractsScreencastFramesAndDownloadCompletion() throws {
        let frameJSON = """
        {"method":"Page.screencastFrame","params":{"data":"aGVsbG8=","sessionId":17,"metadata":{"deviceWidth":1280,"deviceHeight":720}}}
        """
        let downloadJSON = """
        {"method":"Browser.downloadProgress","params":{"guid":"download-guid","state":"completed","receivedBytes":5,"totalBytes":5}}
        """

        XCTAssertEqual(
            try ChromeDevToolsClient.decodeEvent(Data(frameJSON.utf8)),
            .screencastFrame(data: Data("hello".utf8), sessionID: 17, width: 1_280, height: 720)
        )
        XCTAssertEqual(
            try ChromeDevToolsClient.decodeEvent(Data(downloadJSON.utf8)),
            .downloadProgress(guid: "download-guid", state: "completed")
        )
    }

    func testChromeDevToolsDecoderExtractsSuggestedRemoteDownloadFilename() throws {
        let json = """
        {"method":"Browser.downloadWillBegin","params":{"frameId":"frame-1","guid":"guid-1","url":"https://example.com/report","suggestedFilename":"quarterly report.pdf"}}
        """

        XCTAssertEqual(
            try ChromeDevToolsClient.decodeEvent(Data(json.utf8)),
            .downloadWillBegin(guid: "guid-1", suggestedFilename: "quarterly report.pdf")
        )
    }

    func testChromeDevToolsDecoderIgnoresSubframeNavigationAndLoading() throws {
        let decoder = ChromeDevToolsEventDecoder()
        let mainNavigation = Data(
            #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main","url":"https://example.com"}}}"#.utf8
        )
        let subframeNavigation = Data(
            #"{"method":"Page.frameNavigated","params":{"frame":{"id":"child","parentId":"main","url":"https://ads.example"}}}"#.utf8
        )
        let childStarted = Data(
            #"{"method":"Page.frameStartedLoading","params":{"frameId":"child"}}"#.utf8
        )
        let mainStarted = Data(
            #"{"method":"Page.frameStartedLoading","params":{"frameId":"main"}}"#.utf8
        )

        XCTAssertEqual(try decoder.decode(mainNavigation), .frameNavigated(url: "https://example.com"))
        XCTAssertEqual(try decoder.decode(subframeNavigation), .ignored)
        XCTAssertEqual(try decoder.decode(childStarted), .ignored)
        XCTAssertEqual(try decoder.decode(mainStarted), .loading(true))
    }

    func testChromeDevToolsDecoderReportsNetworkNavigationFailures() throws {
        let failure = Data(
            #"{"method":"Network.loadingFailed","params":{"requestId":"1","type":"Document","errorText":"net::ERR_CONNECTION_REFUSED","canceled":false}}"#.utf8
        )

        XCTAssertEqual(
            try ChromeDevToolsClient.decodeEvent(failure),
            .navigationFailed(errorText: "net::ERR_CONNECTION_REFUSED")
        )

        let subresourceFailure = Data(
            #"{"method":"Network.loadingFailed","params":{"requestId":"2","type":"Image","errorText":"net::ERR_BLOCKED_BY_CLIENT","canceled":false}}"#.utf8
        )
        XCTAssertEqual(try ChromeDevToolsClient.decodeEvent(subresourceFailure), .ignored)
    }

    func testChromeDevToolsReportsPageNavigateErrorTextAsNavigationFailure() async throws {
        let transport = RecordingChromeDevToolsWebSocketTransport()
        let client = ChromeDevToolsClient(
            webSocketTransport: transport,
            session: Self.chromeDevToolsSession,
            startupTimeout: 1
        )
        let connected = expectation(description: "connected")
        let failed = expectation(description: "navigation failed")
        client.onEvent = { event in
            if event == .connected {
                connected.fulfill()
            }
            if event == .navigationFailed(errorText: "net::ERR_NAME_NOT_RESOLVED") {
                failed.fulfill()
            }
        }
        client.connect()
        transport.completePing()
        let didSendInitialization = await transport.waitUntilCommandCountIsAtLeast(5)
        XCTAssertTrue(didSendInitialization)
        for method in [
            "Page.enable",
            "Page.setLifecycleEventsEnabled",
            "Runtime.enable",
            "Browser.setDownloadBehavior",
            "Page.startScreencast"
        ] {
            transport.completeResponse(forMethod: method)
        }
        await fulfillment(of: [connected], timeout: 1)

        client.send(method: "Page.navigate", parameters: ["url": "https://unresolvable.invalid"])
        transport.completePageNavigateResponse(errorText: "net::ERR_NAME_NOT_RESOLVED")

        await fulfillment(of: [failed], timeout: 1)
    }

    func testOptionalNetworkDomainFailureDoesNotDisconnectRemoteBrowser() async throws {
        let transport = RecordingChromeDevToolsWebSocketTransport()
        let client = ChromeDevToolsClient(
            webSocketTransport: transport,
            session: Self.chromeDevToolsSession,
            startupTimeout: 1
        )
        let connected = expectation(description: "connected")
        let disconnected = expectation(description: "unexpected disconnect")
        disconnected.isInverted = true
        client.onEvent = { event in
            if event == .connected { connected.fulfill() }
        }
        client.onFailure = { _ in disconnected.fulfill() }
        client.connect()
        transport.completePing()
        let didSendInitialization = await transport.waitUntilCommandCountIsAtLeast(5)
        XCTAssertTrue(didSendInitialization)
        for method in [
            "Page.enable",
            "Page.setLifecycleEventsEnabled",
            "Runtime.enable",
            "Browser.setDownloadBehavior",
            "Page.startScreencast"
        ] {
            transport.completeResponse(forMethod: method)
        }
        await fulfillment(of: [connected], timeout: 1)

        transport.completeResponse(forMethod: "Network.enable", errorMessage: "method not found")
        await fulfillment(of: [disconnected], timeout: 0.05)
        client.send(method: "Page.navigate", parameters: ["url": "https://example.com"])

        let methods = transport.sentData.compactMap { data -> String? in
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["method"] as? String
        }
        XCTAssertEqual(methods.last, "Page.navigate")
    }

    func testRuntimeDeinitRetriesCleanupAfterImmediateAttemptsAreExhausted() async throws {
        let retriedCleanup = expectation(description: "deinit cleanup retried")
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .success(Self.launchOutput),
            .failure(TestRemoteChromiumError.failed),
            .failure(TestRemoteChromiumError.failed),
            .failure(TestRemoteChromiumError.failed),
            .success("")
        ])
        executor.commandExpectations = [nil, nil, nil, nil, retriedCleanup]
        var runtime: RemoteChromiumRuntime? = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            cleanupRetryDelays: [0.01, 0.01],
            pollInterval: 0
        )
        _ = try XCTUnwrap(runtime).start(context: Self.liveContext, localPort: 19_090)

        runtime = nil

        await fulfillment(of: [retriedCleanup], timeout: 1)
        XCTAssertEqual(executor.commands.count, 5)
    }

    func testRuntimeDeinitLogsCleanupExhaustionAfterDelayedRetries() async throws {
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .success(Self.launchOutput),
            .failure(TestRemoteChromiumError.failed),
            .failure(TestRemoteChromiumError.failed),
            .failure(TestRemoteChromiumError.failed)
        ])
        let log = RecordingRemoteChromiumLog()
        var runtime: RemoteChromiumRuntime? = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1/devtools/page/1")! },
            cleanupRetryDelays: [0.01],
            pollInterval: 0,
            diagnosticLog: log
        )
        _ = try XCTUnwrap(runtime).start(context: Self.liveContext, localPort: 19_090)

        runtime = nil

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline,
              log.messages.contains(where: { $0.contains("remote.chromium.cleanup.exhausted stage=deinit") }) == false
        {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(
            log.messages.contains {
                $0.contains("remote.chromium.cleanup.exhausted stage=deinit")
            }
        )
    }

    func testChromeDevToolsPongDoesNotReportConnectedBeforeInitializationResponses() async throws {
        let transport = RecordingChromeDevToolsWebSocketTransport()
        let client = ChromeDevToolsClient(
            webSocketTransport: transport,
            session: Self.chromeDevToolsSession,
            startupTimeout: 1
        )
        var events: [ChromeDevToolsEvent] = []
        client.onEvent = { events.append($0) }

        client.connect()

        XCTAssertTrue(transport.didResume)
        XCTAssertTrue(transport.sentData.isEmpty)
        XCTAssertEqual(transport.pendingPingCount, 1)

        transport.completePing()
        let didSendInitialization = await transport.waitUntilCommandCountIsAtLeast(5)
        XCTAssertTrue(didSendInitialization)

        XCTAssertFalse(events.contains(.connected))
    }

    func testChromeDevToolsReportsConnectedOnlyAfterInitializationBarrierSucceeds() async throws {
        let transport = RecordingChromeDevToolsWebSocketTransport()
        let client = ChromeDevToolsClient(
            webSocketTransport: transport,
            session: Self.chromeDevToolsSession,
            startupTimeout: 1
        )
        let connected = expectation(description: "connected after initialization responses")
        let partialBarrierProcessed = expectation(description: "first four initialization responses processed")
        var events: [ChromeDevToolsEvent] = []
        client.onEvent = { event in
            events.append(event)
            if event == .connected { connected.fulfill() }
            if event == .frameNavigated(url: "https://barrier.example/") {
                partialBarrierProcessed.fulfill()
            }
        }

        client.connect()
        transport.completePing()
        let didSendInitialization = await transport.waitUntilCommandCountIsAtLeast(5)
        XCTAssertTrue(didSendInitialization)

        let commands = try transport.sentData.map { data -> [String: Any] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let downloadCommand = try XCTUnwrap(
            commands.first { ($0["method"] as? String) == "Browser.setDownloadBehavior" }
        )
        let downloadParameters = try XCTUnwrap(downloadCommand["params"] as? [String: Any])
        XCTAssertEqual(downloadParameters["behavior"] as? String, "allowAndName")
        let screencastCommand = try XCTUnwrap(
            commands.first { ($0["method"] as? String) == "Page.startScreencast" }
        )
        let screencastParameters = try XCTUnwrap(screencastCommand["params"] as? [String: Any])
        XCTAssertEqual(screencastParameters["everyNthFrame"] as? Int, 2)

        let initializationMethods = [
            "Page.enable",
            "Page.setLifecycleEventsEnabled",
            "Runtime.enable",
            "Browser.setDownloadBehavior",
            "Page.startScreencast"
        ]
        for method in initializationMethods.dropLast() {
            transport.completeResponse(forMethod: method)
        }
        transport.sendEvent(
            #"{"method":"Page.frameNavigated","params":{"frame":{"id":"main","url":"https://barrier.example/"}}}"#
        )
        await fulfillment(of: [partialBarrierProcessed], timeout: 1)
        XCTAssertFalse(events.contains(.connected))

        transport.completeResponse(forMethod: try XCTUnwrap(initializationMethods.last))
        await fulfillment(of: [connected], timeout: 1)
        XCTAssertEqual(events.filter { $0 == .connected }.count, 1)
    }

    func testChromeDevToolsEvaluateStringReturnsOnlyTheRemoteStringValue() async throws {
        let transport = RecordingChromeDevToolsWebSocketTransport()
        let client = ChromeDevToolsClient(
            webSocketTransport: transport,
            session: Self.chromeDevToolsSession,
            startupTimeout: 1
        )
        let connected = expectation(description: "connected")
        client.onEvent = { event in
            if event == .connected { connected.fulfill() }
        }
        client.connect()
        transport.completePing()
        let didSendInitialization = await transport.waitUntilCommandCountIsAtLeast(5)
        XCTAssertTrue(didSendInitialization)
        for method in [
            "Page.enable",
            "Page.setLifecycleEventsEnabled",
            "Runtime.enable",
            "Browser.setDownloadBehavior",
            "Page.startScreencast"
        ] {
            transport.completeResponse(forMethod: method)
        }
        await fulfillment(of: [connected], timeout: 1)
        let evaluated = expectation(description: "evaluated string")

        client.evaluateString("document.title") { result in
            XCTAssertEqual(try? result.get(), "Operations")
            evaluated.fulfill()
        }
        let didSendEvaluation = await transport.waitUntilCommandCountIsAtLeast(7)
        XCTAssertTrue(didSendEvaluation)
        transport.completeStringResponse(forMethod: "Runtime.evaluate", value: "Operations")

        await fulfillment(of: [evaluated], timeout: 1)
    }

    func testChromeDevToolsHandshakeTimeoutFailsWithoutReportingConnected() async {
        let transport = RecordingChromeDevToolsWebSocketTransport()
        let client = ChromeDevToolsClient(
            webSocketTransport: transport,
            session: Self.chromeDevToolsSession,
            startupTimeout: 0.01
        )
        let failed = expectation(description: "startup timeout")
        var events: [ChromeDevToolsEvent] = []
        client.onEvent = { events.append($0) }
        client.onFailure = { error in
            XCTAssertEqual(error as? RemoteChromiumRuntimeError, .webSocketConnectionTimedOut)
            failed.fulfill()
        }

        client.connect()
        await fulfillment(of: [failed], timeout: 1)

        XCTAssertFalse(events.contains(.connected))
        XCTAssertTrue(transport.didCancel)
    }

    func testChromeDevToolsInitializationTimeoutFailsAfterSuccessfulPong() async {
        let transport = RecordingChromeDevToolsWebSocketTransport()
        let client = ChromeDevToolsClient(
            webSocketTransport: transport,
            session: Self.chromeDevToolsSession,
            startupTimeout: 0.05
        )
        let failed = expectation(description: "initialization response timeout")
        var events: [ChromeDevToolsEvent] = []
        client.onEvent = { events.append($0) }
        client.onFailure = { error in
            XCTAssertEqual(error as? RemoteChromiumRuntimeError, .webSocketConnectionTimedOut)
            failed.fulfill()
        }

        client.connect()
        transport.completePing()
        await fulfillment(of: [failed], timeout: 1)

        XCTAssertFalse(events.contains(.connected))
        XCTAssertTrue(transport.didCancel)
    }

    func testChromeDevToolsInitializationErrorFailsWithoutReportingConnected() async throws {
        let transport = RecordingChromeDevToolsWebSocketTransport()
        let client = ChromeDevToolsClient(
            webSocketTransport: transport,
            session: Self.chromeDevToolsSession,
            startupTimeout: 1
        )
        let failed = expectation(description: "initialization response error")
        var events: [ChromeDevToolsEvent] = []
        client.onEvent = { events.append($0) }
        client.onFailure = { error in
            XCTAssertEqual(
                error as? RemoteChromiumRuntimeError,
                .commandFailed("Page domain unavailable")
            )
            failed.fulfill()
        }

        client.connect()
        transport.completePing()
        let didSendInitialization = await transport.waitUntilCommandCountIsAtLeast(5)
        XCTAssertTrue(didSendInitialization)
        transport.completeResponse(forMethod: "Page.enable", errorMessage: "Page domain unavailable")
        await fulfillment(of: [failed], timeout: 1)

        XCTAssertFalse(events.contains(.connected))
    }

    func testDownloadTrackerReturnsExactGUIDPathAndSanitizedSuggestedFilenameExactlyOnce() {
        var tracker = ChromeDevToolsDownloadPathTracker(
            session: Self.chromeDevToolsSession
        )
        tracker.record(guid: "guid-1", suggestedFilename: "../../quarterly report.pdf")

        XCTAssertEqual(
            tracker.takeCompletedDownload(guid: "guid-1"),
            RemoteChromiumDownload(
                session: Self.chromeDevToolsSession,
                remotePath: Self.chromeDevToolsSession.remoteDownloadsDirectory + "/guid-1",
                suggestedFilename: "quarterly report.pdf"
            )
        )
        XCTAssertNil(tracker.takeCompletedDownload(guid: "guid-1"))
    }

    func testDownloadTrackerRejectsGUIDThatCouldEscapeTheDownloadDirectory() {
        var tracker = ChromeDevToolsDownloadPathTracker(
            session: Self.chromeDevToolsSession
        )
        tracker.record(guid: "../outside", suggestedFilename: "report.pdf")

        XCTAssertNil(tracker.takeCompletedDownload(guid: "../outside"))
    }

    func testDownloadTrackerRejectsDotAndDotDotGUIDs() {
        var tracker = ChromeDevToolsDownloadPathTracker(
            session: Self.chromeDevToolsSession
        )
        tracker.record(guid: ".", suggestedFilename: "dot.txt")
        tracker.record(guid: "..", suggestedFilename: "dot-dot.txt")

        XCTAssertNil(tracker.takeCompletedDownload(guid: "."))
        XCTAssertNil(tracker.takeCompletedDownload(guid: ".."))
    }

    func testStopRetainsCompletedDownloadUntilItIsAcknowledgedAfterLocalVerification() async throws {
        let acknowledged = expectation(description: "download acknowledged")
        let executor = RecordingRemoteChromiumCommandExecutor(outputs: [Self.launchOutput, "", ""])
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1:19090/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/download-guid",
            suggestedFilename: "report.pdf"
        )

        XCTAssertTrue(runtime.retainDownload(download))
        runtime.stop(session: session)

        XCTAssertEqual(executor.commands.count, 2)
        XCTAssertTrue(executor.commands[1].contains("kill '4242'"))
        XCTAssertFalse(executor.commands[1].contains("rm -rf -- '/tmp/stacio-chromium.AbC123'"))

        XCTAssertTrue(
            runtime.acknowledgeDownload(download) { result in
                if case let .failure(error) = result {
                    XCTFail("Acknowledgement failed: \(error)")
                }
                acknowledged.fulfill()
            }
        )
        await fulfillment(of: [acknowledged], timeout: 1)
        XCTAssertEqual(executor.commands.count, 3)
        XCTAssertTrue(executor.commands[2].contains("rm -rf -- '/tmp/stacio-chromium.AbC123'"))
    }

    func testRuntimeDeinitStopsProcessWithoutDeletingDirectoryContainingRetainedDownload() throws {
        let executor = RecordingRemoteChromiumCommandExecutor(outputs: [Self.launchOutput, ""])
        let tunnelBridge = RecordingRemoteChromiumTunnelBridge()
        var runtime: RemoteChromiumRuntime? = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: tunnelBridge,
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1:19090/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let session = try XCTUnwrap(runtime).start(context: Self.liveContext, localPort: 19_090)
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/download-guid",
            suggestedFilename: "report.pdf"
        )
        XCTAssertTrue(runtime?.retainDownload(download) == true)

        runtime = nil

        XCTAssertEqual(tunnelBridge.stoppedProfiles.map(\.id), tunnelBridge.startedProfiles.map(\.id))
        XCTAssertEqual(executor.commands.count, 2)
        XCTAssertTrue(executor.commands[1].contains("kill '4242'"))
        XCTAssertFalse(executor.commands[1].contains("rm -rf -- '/tmp/stacio-chromium.AbC123'"))
    }

    func testAcknowledgeDownloadReturnsBeforeRemoteCleanupCompletesAndRejectsDuplicate() async throws {
        let cleanupCompleted = expectation(description: "remote cleanup completed")
        let executor = BlockingRemoteChromiumAcknowledgementExecutor(
            launchOutput: Self.launchOutput
        )
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1:19090/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/download-guid",
            suggestedFilename: "report.pdf"
        )
        XCTAssertTrue(runtime.retainDownload(download))

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            executor.releaseCleanup()
        }
        let startedAt = Date()
        XCTAssertTrue(
            runtime.acknowledgeDownload(download) { result in
                XCTAssertTrue(Thread.isMainThread)
                if case let .failure(error) = result {
                    XCTFail("Unexpected cleanup failure: \(error)")
                }
                cleanupCompleted.fulfill()
            }
        )
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.1)
        XCTAssertFalse(
            runtime.acknowledgeDownload(download) { _ in
                XCTFail("A duplicate in-flight acknowledgement must not start cleanup")
            }
        )

        await fulfillment(of: [cleanupCompleted], timeout: 1)
    }

    func testFailedAcknowledgementPreservesDownloadForRetry() async throws {
        let firstAttemptCompleted = expectation(description: "first cleanup failed")
        let retryCompleted = expectation(description: "retry cleanup succeeded")
        let executor = RecordingRemoteChromiumCommandExecutor(results: [
            .success(Self.launchOutput),
            .failure(TestRemoteChromiumError.failed),
            .success("")
        ])
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1:19090/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let download = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/download-guid",
            suggestedFilename: "report.pdf"
        )
        XCTAssertTrue(runtime.retainDownload(download))

        XCTAssertTrue(
            runtime.acknowledgeDownload(download) { result in
                if case .success = result {
                    XCTFail("The scripted first cleanup must fail")
                }
                firstAttemptCompleted.fulfill()
            }
        )
        await fulfillment(of: [firstAttemptCompleted], timeout: 1)

        XCTAssertTrue(
            runtime.acknowledgeDownload(download) { result in
                if case let .failure(error) = result {
                    XCTFail("Retry unexpectedly failed: \(error)")
                }
                retryCompleted.fulfill()
            }
        )
        await fulfillment(of: [retryCompleted], timeout: 1)
        XCTAssertFalse(runtime.acknowledgeDownload(download) { _ in })
    }

    func testStoppedRuntimeDeletesAcknowledgedFilesThenRemovesDirectoryAfterFinalDownload() async throws {
        let firstAcknowledged = expectation(description: "first download acknowledged")
        let finalAcknowledged = expectation(description: "final download acknowledged")
        let executor = RecordingRemoteChromiumCommandExecutor(
            outputs: [Self.launchOutput, "", "", ""]
        )
        let runtime = RemoteChromiumRuntime(
            commandExecutor: executor,
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1:19090/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let first = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/download-one",
            suggestedFilename: "one.pdf"
        )
        let final = RemoteChromiumDownload(
            session: session,
            remotePath: session.remoteDownloadsDirectory + "/download-two",
            suggestedFilename: "two.pdf"
        )
        XCTAssertTrue(runtime.retainDownload(first))
        XCTAssertTrue(runtime.retainDownload(final))
        runtime.stop(session: session)

        XCTAssertTrue(
            runtime.acknowledgeDownload(first) { result in
                if case let .failure(error) = result {
                    XCTFail("First acknowledgement failed: \(error)")
                }
                firstAcknowledged.fulfill()
            }
        )
        await fulfillment(of: [firstAcknowledged], timeout: 1)
        XCTAssertTrue(executor.commands[2].contains("rm -f -- '\(first.remotePath)'"))
        XCTAssertFalse(executor.commands[2].contains("rm -rf --"))

        XCTAssertTrue(
            runtime.acknowledgeDownload(final) { result in
                if case let .failure(error) = result {
                    XCTFail("Final acknowledgement failed: \(error)")
                }
                finalAcknowledged.fulfill()
            }
        )
        await fulfillment(of: [finalAcknowledged], timeout: 1)
        XCTAssertTrue(executor.commands[3].contains("rm -rf -- '\(session.remoteTemporaryDirectory)'"))
    }

    func testRuntimeRejectsFabricatedDownloadWithMatchingLeaseAndCanonicalPath() throws {
        let runtime = RemoteChromiumRuntime(
            commandExecutor: RecordingRemoteChromiumCommandExecutor(outputs: [Self.launchOutput, ""]),
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1:19090/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let fabricated = RemoteChromiumDownload(
            sessionLeaseID: session.leaseID,
            remotePath: session.remoteDownloadsDirectory + "/download-guid",
            suggestedFilename: "report.pdf"
        )

        XCTAssertFalse(runtime.retainDownload(fabricated))
    }

    func testRuntimeRejectsDownloadFromAnotherSessionLease() throws {
        let secondLaunchOutput = """
        __STACIO_CHROMIUM_PID__=5252
        __STACIO_CHROMIUM_DIR__=/tmp/stacio-chromium.XyZ789
        __STACIO_CHROMIUM_PORT__=43211
        __STACIO_CHROMIUM_BINARY__=/usr/bin/chromium
        """
        let runtime = RemoteChromiumRuntime(
            commandExecutor: RecordingRemoteChromiumCommandExecutor(
                outputs: [Self.launchOutput, secondLaunchOutput, "", ""]
            ),
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { port in URL(string: "ws://127.0.0.1:\(port)/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let sessionA = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let sessionB = try runtime.start(context: Self.liveContext, localPort: 19_091)
        let mismatched = RemoteChromiumDownload(
            session: sessionA,
            remotePath: sessionB.remoteDownloadsDirectory + "/download-guid",
            suggestedFilename: "report.pdf"
        )

        XCTAssertFalse(runtime.retainDownload(mismatched))
        XCTAssertFalse(runtime.acknowledgeDownload(mismatched) { _ in })
    }

    func testRuntimeRejectsNoncanonicalDownloadPaths() throws {
        let runtime = RemoteChromiumRuntime(
            commandExecutor: RecordingRemoteChromiumCommandExecutor(outputs: [Self.launchOutput, ""]),
            tunnelBridge: RecordingRemoteChromiumTunnelBridge(),
            pageEndpointResolver: { _ in URL(string: "ws://127.0.0.1:19090/devtools/page/1")! },
            performsCleanupAsynchronously: false,
            pollInterval: 0
        )
        let session = try runtime.start(context: Self.liveContext, localPort: 19_090)
        let invalidPaths = [
            session.remoteDownloadsDirectory + "/.",
            session.remoteDownloadsDirectory + "/..",
            session.remoteDownloadsDirectory + "/nested/file",
            session.remoteDownloadsDirectory + "/file/../other"
        ]

        for path in invalidPaths {
            XCTAssertFalse(
                runtime.retainDownload(
                    RemoteChromiumDownload(
                        session: session,
                        remotePath: path,
                        suggestedFilename: "report.pdf"
                    )
                ),
                "Unexpectedly retained \(path)"
            )
        }
    }

    func testChromeDevToolsCommandEncodesNavigationURLAsJSONData() throws {
        let url = "https://example.com/search?q='; rm -rf / &value=\"quoted\""
        let data = try ChromeDevToolsClient.commandData(
            id: 7,
            method: "Page.navigate",
            parameters: ["url": url]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parameters = try XCTUnwrap(object["params"] as? [String: Any])

        XCTAssertEqual(object["method"] as? String, "Page.navigate")
        XCTAssertEqual(parameters["url"] as? String, url)
    }

    func testRemoteChromiumInputMapperConvertsAppKitCoordinatesToRemoteViewport() throws {
        let parameters = try XCTUnwrap(
            RemoteChromiumInputMapper.mouseParameters(
                type: "mousePressed",
                button: "left",
                location: NSPoint(x: 250, y: 150),
                canvasBounds: NSRect(x: 0, y: 0, width: 500, height: 300),
                frameSize: NSSize(width: 1_000, height: 500),
                clickCount: 1
            )
        )

        XCTAssertEqual(parameters["type"] as? String, "mousePressed")
        XCTAssertEqual(parameters["button"] as? String, "left")
        XCTAssertEqual(try XCTUnwrap(parameters["x"] as? Double), 500, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(parameters["y"] as? Double), 250, accuracy: 0.1)
        XCTAssertEqual(parameters["clickCount"] as? Int, 1)
    }

    func testRemoteChromiumInputMapperAccountsForPageScaleWhenMappingCoordinates() throws {
        let parameters = try XCTUnwrap(
            RemoteChromiumInputMapper.mouseParameters(
                type: "mousePressed",
                button: "left",
                location: NSPoint(x: 250, y: 150),
                canvasBounds: NSRect(x: 0, y: 0, width: 500, height: 300),
                frameSize: NSSize(width: 1_000, height: 500),
                pageScaleFactor: 2,
                clickCount: 1
            )
        )

        XCTAssertEqual(try XCTUnwrap(parameters["x"] as? Double), 250, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(parameters["y"] as? Double), 125, accuracy: 0.1)
    }

    func testRemoteChromiumInputMapperMapsMacKeyCodesToCDPIdentity() throws {
        let letter = try XCTUnwrap(
            RemoteChromiumInputMapper.keyParameters(
                type: "rawKeyDown",
                keyCode: 0,
                characters: "a",
                modifierFlags: []
            )
        )
        XCTAssertEqual(letter["key"] as? String, "a")
        XCTAssertEqual(letter["code"] as? String, "KeyA")
        XCTAssertEqual(letter["windowsVirtualKeyCode"] as? Int, 65)
        XCTAssertEqual(letter["nativeVirtualKeyCode"] as? Int, 0)

        let arrow = try XCTUnwrap(
            RemoteChromiumInputMapper.keyParameters(
                type: "rawKeyDown",
                keyCode: 123,
                characters: nil,
                modifierFlags: []
            )
        )
        XCTAssertEqual(arrow["key"] as? String, "ArrowLeft")
        XCTAssertEqual(arrow["code"] as? String, "ArrowLeft")
        XCTAssertEqual(arrow["windowsVirtualKeyCode"] as? Int, 37)
    }

    func testRemoteChromiumModifierMappingEmitsDownAndUpForFlagsChanged() throws {
        let pressed = try XCTUnwrap(
            RemoteChromiumInputMapper.modifierKeyParameters(
                keyCode: 56,
                modifierFlags: [.shift]
            )
        )
        let released = try XCTUnwrap(
            RemoteChromiumInputMapper.modifierKeyParameters(
                keyCode: 56,
                modifierFlags: []
            )
        )

        XCTAssertEqual(pressed["type"] as? String, "rawKeyDown")
        XCTAssertEqual(pressed["key"] as? String, "Shift")
        XCTAssertEqual(pressed["code"] as? String, "ShiftLeft")
        XCTAssertEqual(pressed["windowsVirtualKeyCode"] as? Int, 16)
        XCTAssertEqual(released["type"] as? String, "keyUp")
    }

    private static let launchOutput = """
    __STACIO_CHROMIUM_PID__=4242
    __STACIO_CHROMIUM_DIR__=/tmp/stacio-chromium.AbC123
    __STACIO_CHROMIUM_PORT__=43210
    __STACIO_CHROMIUM_BINARY__=/usr/bin/chromium
    """

    private static let chromeDevToolsSession = RemoteChromiumRuntimeSession(
        leaseID: UUID(uuidString: "A0A0A0A0-0000-4000-8000-000000000001")!,
        remoteProcessID: 4_242,
        remoteTemporaryDirectory: "/tmp/stacio-chromium.AbC123",
        remoteDownloadsDirectory: "/tmp/stacio-chromium.AbC123/downloads",
        localDebugPort: 19_090,
        pageWebSocketURL: URL(string: "ws://127.0.0.1:19090/devtools/page/page-1")!
    )

    private static let liveContext = TunnelLiveSessionContext(
        config: SshConnectionConfig(
            host: "server.internal",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 2_000
        ),
        secret: .agent,
        expectedFingerprintSHA256: "SHA256:test"
    )
}

private enum TestRemoteChromiumError: Error {
    case failed
}

private final class RecordingRemoteChromiumLog: StacioLogWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMessages: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMessages
    }

    func append(
        level: StacioLogLevel,
        category: String,
        message: String,
        sensitiveValues: [String]
    ) {
        lock.lock()
        recordedMessages.append(message)
        lock.unlock()
    }
}

private struct TestRemoteChromiumBridgeError: Error, LocalizedError {
    var errorDescription: String? { "bridge failed" }
}

private final class RecordingRemoteChromiumLiveShellStarter: LiveShellStarting {
    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: "remote-chromium-test", status: "running", diagnostic: "")
    }
}

private final class FailingAfterPartialOutputRuntimeBridge: AgentBackgroundRuntimeBridging {
    private let output: String
    private var pollCount = 0

    init(output: String) {
        self.output = output
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: "remote-chromium-test", status: "running", diagnostic: "")
    }

    func writeTerminalInput(runtimeID: String, bytes: [UInt8]) throws {}

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        pollCount += 1
        if pollCount > 1 {
            throw TestRemoteChromiumBridgeError()
        }
        return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "")
    }

    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        TerminalOutputBatch(
            runtimeId: runtimeID,
            bytes: Data(output.utf8),
            droppedByteCount: 0
        )
    }

    func closeTerminalRuntime(runtimeID: String) throws {}
}

private struct TestUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class RecordingRemoteChromiumCommandExecutor: RemoteChromiumCommandExecuting {
    private var results: [Result<String, Error>]
    private(set) var commands: [String] = []
    var commandExpectations: [XCTestExpectation?] = []

    init(outputs: [String]) {
        self.results = outputs.map(Result.success)
    }

    init(results: [Result<String, Error>]) {
        self.results = results
    }

    func execute(
        command: String,
        context: TunnelLiveSessionContext,
        timeout: TimeInterval
    ) throws -> String {
        commands.append(command)
        if commandExpectations.isEmpty == false {
            commandExpectations.removeFirst()?.fulfill()
        }
        return try (results.isEmpty ? .success("") : results.removeFirst()).get()
    }
}

private final class BlockingRemoteChromiumAcknowledgementExecutor: RemoteChromiumCommandExecuting, @unchecked Sendable {
    private let launchOutput: String
    private let cleanupEntered: XCTestExpectation?
    private let cleanupGate = DispatchSemaphore(value: 0)

    init(launchOutput: String, cleanupEntered: XCTestExpectation? = nil) {
        self.launchOutput = launchOutput
        self.cleanupEntered = cleanupEntered
    }

    func releaseCleanup() {
        cleanupGate.signal()
    }

    func execute(
        command: String,
        context: TunnelLiveSessionContext,
        timeout: TimeInterval
    ) throws -> String {
        guard command != RemoteChromiumRuntime.launchCommand else {
            return launchOutput
        }
        if command.contains("rm -f --") {
            cleanupEntered?.fulfill()
            _ = cleanupGate.wait(timeout: .now() + 1)
        }
        return ""
    }
}

private final class RecordingRemoteChromiumTunnelBridge: TunnelRuntimeBridging {
    let startError: Error?
    private var stopResults: [Result<TunnelRuntimeStatus, Error>]
    private(set) var startedProfiles: [TunnelProfile] = []
    private(set) var stoppedProfiles: [TunnelProfile] = []
    var stopExpectations: [XCTestExpectation?] = []

    init(
        startError: Error? = nil,
        stopResults: [Result<TunnelRuntimeStatus, Error>] = []
    ) {
        self.startError = startError
        self.stopResults = stopResults
    }

    func start(profile: TunnelProfile) throws -> TunnelRuntimeStatus {
        try start(profile: profile, liveSessionContext: nil)
    }

    func start(
        profile: TunnelProfile,
        liveSessionContext: TunnelLiveSessionContext?
    ) throws -> TunnelRuntimeStatus {
        startedProfiles.append(profile)
        if let startError { throw startError }
        return TunnelRuntimeStatus(profileId: profile.id, state: .running, message: "running")
    }

    func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus {
        try start(profile: record.profile)
    }

    func poll(profileID: String) throws -> TunnelRuntimeStatus {
        TunnelRuntimeStatus(profileId: profileID, state: .running, message: "running")
    }

    func stop(profile: TunnelProfile, state: TunnelState) throws -> TunnelRuntimeStatus {
        stoppedProfiles.append(profile)
        if stopExpectations.isEmpty == false {
            stopExpectations.removeFirst()?.fulfill()
        }
        if stopResults.isEmpty == false {
            let result = stopResults.removeFirst()
            switch result {
            case let .failure(error):
                throw error
            case let .success(status):
                return TunnelRuntimeStatus(profileId: profile.id, state: status.state, message: status.message)
            }
        }
        return TunnelRuntimeStatus(profileId: profile.id, state: .stopped, message: "stopped")
    }
}

private final class RecordingChromeDevToolsWebSocketTransport: ChromeDevToolsWebSocketTransport {
    private(set) var didResume = false
    private(set) var didCancel = false
    private(set) var sentData: [Data] = []
    private var pingCompletions: [(Error?) -> Void] = []
    private var receiveCompletion: ((Result<ChromeDevToolsWebSocketMessage, Error>) -> Void)?
    private var queuedMessages: [ChromeDevToolsWebSocketMessage] = []

    var pendingPingCount: Int { pingCompletions.count }

    func resume() {
        didResume = true
    }

    func send(data: Data, completionHandler: @escaping (Error?) -> Void) {
        sentData.append(data)
        completionHandler(nil)
    }

    func receive(
        completionHandler: @escaping (Result<ChromeDevToolsWebSocketMessage, Error>) -> Void
    ) {
        if queuedMessages.isEmpty == false {
            completionHandler(.success(queuedMessages.removeFirst()))
            return
        }
        receiveCompletion = completionHandler
    }

    func sendPing(completionHandler: @escaping (Error?) -> Void) {
        pingCompletions.append(completionHandler)
    }

    func cancel() {
        didCancel = true
        receiveCompletion = nil
    }

    func completePing(error: Error? = nil) {
        guard pingCompletions.isEmpty == false else { return }
        pingCompletions.removeFirst()(error)
    }

    func completeResponse(forMethod method: String, errorMessage: String? = nil) {
        guard let command = sentData.compactMap({ data -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }).first(where: { ($0["method"] as? String) == method }),
              let id = command["id"] as? Int
        else {
            XCTFail("No recorded command for \(method)")
            return
        }
        var object: [String: Any] = ["id": id, "result": [:]]
        if let errorMessage {
            object["error"] = ["message": errorMessage]
            object.removeValue(forKey: "result")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            XCTFail("Could not encode response for \(method)")
            return
        }
        enqueue(.data(data))
    }

    func completeStringResponse(forMethod method: String, value: String) {
        guard let command = sentData.compactMap({ data -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }).last(where: { ($0["method"] as? String) == method }),
              let id = command["id"] as? Int,
              let data = try? JSONSerialization.data(withJSONObject: [
                  "id": id,
                  "result": ["result": ["type": "string", "value": value]]
              ])
        else {
            XCTFail("No recorded command for \(method)")
            return
        }
        enqueue(.data(data))
    }

    func completePageNavigateResponse(errorText: String) {
        guard let command = sentData.compactMap({ data -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }).last(where: { ($0["method"] as? String) == "Page.navigate" }),
              let id = command["id"] as? Int,
              let data = try? JSONSerialization.data(withJSONObject: [
                  "id": id,
                  "result": ["frameId": "main", "errorText": errorText]
              ])
        else {
            XCTFail("No recorded Page.navigate command")
            return
        }
        enqueue(.data(data))
    }

    func sendEvent(_ json: String) {
        enqueue(.data(Data(json.utf8)))
    }

    func waitUntilCommandCountIsAtLeast(_ count: Int) async -> Bool {
        for _ in 0..<100 {
            if sentData.count >= count { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    private func enqueue(_ message: ChromeDevToolsWebSocketMessage) {
        if let completion = receiveCompletion {
            receiveCompletion = nil
            completion(.success(message))
        } else {
            queuedMessages.append(message)
        }
    }
}
