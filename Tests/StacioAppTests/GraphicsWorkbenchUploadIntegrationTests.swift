import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class GraphicsWorkbenchUploadIntegrationTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func testOpeningSavedVNCInjectsUploadHandlerAndReportsMissingSSH() throws {
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            graphicsRuntimeManager: UploadIntegrationGraphicsRuntimeManager(),
            graphicsAdapterPathProvider: { _ in
                "/Applications/Stacio.app/Contents/Adapters/vnc"
            }
        )
        let session = SessionRecord(
            id: "session_vnc_upload_integration",
            folderId: nil,
            name: "VNC Desktop",
            protocol: "vnc",
            host: "desktop.example.com",
            port: 5900,
            username: "admin",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        controller.loadWindow()
        _ = try controller.openSavedSession(session)
        let pane = try XCTUnwrap(
            workspace.currentTerminalPane as? GraphicsSessionPaneViewController
        )

        let handler = try XCTUnwrap(pane.fileUploadHandler)
        var uploadError: String?
        handler(["/tmp/report.txt"]) { result in
            if case let .failure(error) = result {
                uploadError = error.localizedDescription
            }
        }

        XCTAssertEqual(
            uploadError,
            "请先建立同一主机的 SSH 连接以使用文件传输功能"
        )
    }

    #if STACIO_RDP
    func testCancelingRDPFormRemovesPendingGraphicsPane() throws {
        var formPresentationCount = 0
        let recentRecorder = UploadIntegrationSavedSessionOpenRecorder()
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-rdp-cancel-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            savedSessionOpenRecorder: recentRecorder,
            databasePathProvider: { databaseURL.path },
            graphicsRuntimeManager: UploadIntegrationGraphicsRuntimeManager(),
            rdpSessionFormPresenter: { _, _, completion in
                formPresentationCount += 1
                completion(nil)
            },
            graphicsAdapterPathProvider: { _ in "" }
        )

        controller.loadWindow()
        _ = try controller.openSavedSession(Self.rdpSession())
        let pendingPane = try XCTUnwrap(
            workspace.currentTerminalPane as? GraphicsSessionPaneViewController
        )

        XCTAssertTrue(waitUntil {
            formPresentationCount == 1 && workspace.openTerminalPaneCount == 0
        })
        XCTAssertFalse(workspace.currentTerminalPane === pendingPane)
        XCTAssertTrue(recentRecorder.requests.isEmpty)
    }

    func testSavedRDPConfigPrefillsFormAndFlowsIntoRuntimeArguments() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-rdp-prefill-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let session = try CoreBridge.createSessionRecord(
            databasePath: databaseURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "RDP Desktop",
                protocol: "rdp",
                host: "windows.example.com",
                port: 3389,
                username: "Administrator",
                privateKeyPath: nil,
                credentialId: nil,
                tags: [],
                configJson: #"{"rdpDomain":"CORP","rdpSecurity":"tls","rdpIgnoreCert":true}"#
            )
        )
        let runtimeManager = SequencedUploadIntegrationGraphicsRuntimeManager(
            outcomes: [
                .success(
                    GraphicsRuntimeStatus(
                        runtimeID: "graphics_rdp_prefill",
                        status: "running",
                        diagnostic: "connected",
                        presentation: .embeddedSurface
                    )
                )
            ]
        )
        let recentRecorder = UploadIntegrationSavedSessionOpenRecorder()
        var capturedPrefill: RDPSessionFormPrefill?
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            savedSessionOpenRecorder: recentRecorder,
            databasePathProvider: { databaseURL.path },
            graphicsRuntimeManager: runtimeManager,
            rdpSessionFormPresenter: { _, prefill, completion in
                capturedPrefill = prefill
                completion(
                    RDPSessionFormResult(
                        user: prefill.user,
                        password: "runtime-only-secret",
                        domain: prefill.domain,
                        security: prefill.security,
                        ignoreCert: prefill.ignoreCert,
                        width: 1440,
                        height: 900,
                        quality: 8
                    )
                )
            },
            graphicsAdapterPathProvider: { _ in "" }
        )

        controller.loadWindow()
        _ = try controller.openSavedSession(session)

        XCTAssertTrue(waitUntil { runtimeManager.requests.count == 1 })
        XCTAssertEqual(
            capturedPrefill,
            RDPSessionFormPrefill(
                user: "Administrator",
                domain: "CORP",
                security: .tls,
                ignoreCert: true
            )
        )
        let arguments = try XCTUnwrap(runtimeManager.requests.first?.arguments)
        XCTAssertEqual(uploadIntegrationArgumentValue("--domain", in: arguments), "CORP")
        XCTAssertEqual(uploadIntegrationArgumentValue("--security", in: arguments), "tls")
        XCTAssertTrue(arguments.contains("--ignore-cert"))
        XCTAssertEqual(recentRecorder.requests.map(\.id), [session.id])
    }
    #endif

    func testVNCFailureRetryReusesRequestStopsOldRuntimeAndAttachesReplacement() throws {
        let replacementSession = UploadIntegrationEmbeddedGraphicsSession()
        let replacementAttachment = GraphicsRuntimeAttachment(
            runtimeID: "graphics_vnc_retry_replacement",
            kind: .embeddedGraphics,
            session: replacementSession
        )
        let runtimeManager = SequencedUploadIntegrationGraphicsRuntimeManager(
            outcomes: [
                .failure(GraphicsUploadIntegrationTestError.startFailed),
                .success(
                    GraphicsRuntimeStatus(
                        runtimeID: "graphics_vnc_retry_replacement",
                        status: "running",
                        diagnostic: "connected",
                        attachment: replacementAttachment,
                        presentation: .embeddedSurface
                    )
                )
            ],
            gatedAttempt: 2
        )
        defer { runtimeManager.releaseStartGate() }
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            graphicsRuntimeManager: runtimeManager,
            graphicsAdapterPathProvider: { _ in
                "/Applications/Stacio.app/Contents/Adapters/vnc"
            }
        )

        controller.loadWindow()
        _ = try controller.openSavedSession(Self.vncSession())
        let pane = try XCTUnwrap(
            workspace.currentTerminalPane as? GraphicsSessionPaneViewController
        )
        let pendingRuntimeID = pane.runtimeID

        XCTAssertTrue(waitUntil {
            runtimeManager.requests.count == 1
                && pane.visibleTextSnapshotForTesting.contains(
                    L10n.TerminalLifecycle.connectionFailed
                )
        })
        let retryButton = try XCTUnwrap(
            uploadIntegrationSubview(
                in: pane.view,
                identifier: "Stacio.ConnectionState.retry"
            ) as? NSButton
        )
        XCTAssertFalse(retryButton.isHidden)

        retryButton.performClick(nil as Any?)

        XCTAssertTrue(waitUntil { runtimeManager.requests.count == 2 })
        XCTAssertEqual(
            pane.visibleTextSnapshotForTesting,
            "\(L10n.TerminalLifecycle.connecting)\nVNC · desktop.example.com:5900"
        )
        XCTAssertEqual(runtimeManager.stoppedRuntimeIDs, [pendingRuntimeID])
        XCTAssertEqual(runtimeManager.requests[0], runtimeManager.requests[1])

        runtimeManager.releaseStartGate()

        XCTAssertTrue(waitUntil {
            pane.runtimeID == "graphics_vnc_retry_replacement"
                && pane.hasEmbeddedRenderSurfaceForTesting
        })

        pane.closeGraphicsRuntime()
        pane.closeGraphicsRuntime()

        XCTAssertEqual(
            runtimeManager.stoppedRuntimeIDs,
            [pendingRuntimeID, "graphics_vnc_retry_replacement"]
        )
    }

    #if STACIO_RDP
    func testRDPFailureRetryReusesInMemoryCredentialsWithoutPresentingFormAgain() throws {
        let runtimeManager = SequencedUploadIntegrationGraphicsRuntimeManager(
            outcomes: [
                .failure(GraphicsUploadIntegrationTestError.startFailed),
                .success(
                    GraphicsRuntimeStatus(
                        runtimeID: "graphics_rdp_retry_replacement",
                        status: "running",
                        diagnostic: "connected",
                        presentation: .embeddedSurface
                    )
                )
            ]
        )
        var formPresentationCount = 0
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            graphicsRuntimeManager: runtimeManager,
            rdpSessionFormPresenter: { _, prefill, completion in
                formPresentationCount += 1
                XCTAssertEqual(prefill.user, "admin")
                completion(
                    RDPSessionFormResult(
                        user: "admin",
                        password: "rdp-secret",
                        domain: "CORP",
                        security: .nla,
                        ignoreCert: true,
                        width: 1440,
                        height: 900,
                        quality: 8
                    )
                )
            },
            graphicsAdapterPathProvider: { _ in "" }
        )

        controller.loadWindow()
        _ = try controller.openSavedSession(Self.rdpSession())
        let pane = try XCTUnwrap(
            workspace.currentTerminalPane as? GraphicsSessionPaneViewController
        )
        let pendingRuntimeID = pane.runtimeID

        XCTAssertTrue(waitUntil {
            formPresentationCount == 1
                && runtimeManager.requests.count == 1
                && pane.visibleTextSnapshotForTesting.contains(
                    L10n.TerminalLifecycle.connectionFailed
                )
        })
        let retryButton = try XCTUnwrap(
            uploadIntegrationSubview(
                in: pane.view,
                identifier: "Stacio.ConnectionState.retry"
            ) as? NSButton
        )

        retryButton.performClick(nil as Any?)

        XCTAssertTrue(waitUntil {
            runtimeManager.requests.count == 2
                && pane.runtimeID == "graphics_rdp_retry_replacement"
        })
        XCTAssertEqual(formPresentationCount, 1)
        XCTAssertEqual(runtimeManager.requests[0], runtimeManager.requests[1])
        XCTAssertTrue(runtimeManager.requests[1].arguments.contains("rdp-secret"))
        XCTAssertFalse(pane.diagnostic.launchArguments.contains("rdp-secret"))
        XCTAssertTrue(pane.diagnostic.launchArguments.contains("<redacted>"))
        XCTAssertFalse(pane.visibleTextSnapshotForTesting.contains("rdp-secret"))
        XCTAssertEqual(runtimeManager.stoppedRuntimeIDs, [pendingRuntimeID])
    }
    #endif

    func testLateSuccessfulRuntimeIsStoppedWhenPendingGraphicsPaneWasClosed() throws {
        let lateSession = UploadIntegrationEmbeddedGraphicsSession()
        let lateAttachment = GraphicsRuntimeAttachment(
            runtimeID: "graphics_late_after_close",
            kind: .embeddedGraphics,
            session: lateSession
        )
        let runtimeManager = SequencedUploadIntegrationGraphicsRuntimeManager(
            outcomes: [
                .success(
                    GraphicsRuntimeStatus(
                        runtimeID: "graphics_late_after_close",
                        status: "running",
                        diagnostic: "connected",
                        attachment: lateAttachment,
                        presentation: .embeddedSurface
                    )
                )
            ],
            gatedAttempt: 1
        )
        defer { runtimeManager.releaseStartGate() }
        let workspace = WorkspaceViewController(autoStartTerminalProcesses: false)
        let controller = WorkbenchWindowController(
            workspaceViewController: workspace,
            graphicsRuntimeManager: runtimeManager,
            graphicsAdapterPathProvider: { _ in
                "/Applications/Stacio.app/Contents/Adapters/vnc"
            }
        )

        controller.loadWindow()
        _ = try controller.openSavedSession(Self.vncSession())
        let pane = try XCTUnwrap(
            workspace.currentTerminalPane as? GraphicsSessionPaneViewController
        )
        XCTAssertTrue(waitUntil { runtimeManager.requests.count == 1 })

        pane.closeGraphicsRuntime()
        runtimeManager.releaseStartGate()

        XCTAssertTrue(waitUntil {
            runtimeManager.stoppedRuntimeIDs == ["graphics_late_after_close"]
        })
        XCTAssertNotEqual(pane.runtimeID, "graphics_late_after_close")
    }

    func testLateUploadCompletionDoesNotUpdateReplacementGraphicsSurface() throws {
        let diagnostic = GraphicsSessionDiagnostic(
            protocolName: "VNC",
            host: "desktop.example.com",
            port: 5900,
            adapterPath: "/Applications/Stacio.app/Contents/Adapters/vnc",
            launchArguments: ["desktop.example.com:5900"],
            status: "connected",
            presentation: .embeddedSurface
        )
        let firstSession = UploadIntegrationEmbeddedGraphicsSession()
        let pane = GraphicsSessionPaneViewController(
            runtimeID: "graphics_upload_first",
            title: "VNC Desktop",
            diagnostic: diagnostic,
            attachment: GraphicsRuntimeAttachment(
                runtimeID: "graphics_upload_first",
                kind: .embeddedGraphics,
                session: firstSession
            )
        )
        var pendingCompletion: ((Result<[String], Error>) -> Void)?
        pane.fileUploadHandler = { _, completion in
            pendingCompletion = completion
        }
        _ = pane.view

        pane.simulateRegisteredFileDropForTesting(paths: ["/tmp/report.txt"], at: .zero)
        XCTAssertTrue(pane.isStatusToastVisibleForTesting)
        XCTAssertTrue(pane.statusToastTextForTesting?.contains("正在上传") == true)

        let replacementSession = UploadIntegrationEmbeddedGraphicsSession()
        XCTAssertTrue(
            pane.attachRuntime(
                runtimeID: "graphics_upload_replacement",
                diagnostic: diagnostic,
                attachment: GraphicsRuntimeAttachment(
                    runtimeID: "graphics_upload_replacement",
                    kind: .embeddedGraphics,
                    session: replacementSession
                ),
                onClose: nil
            )
        )
        pendingCompletion?(.success(["/tmp/report.txt"]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(pane.isStatusToastVisibleForTesting)
        XCTAssertNil(pane.statusToastTextForTesting)
    }

    private static func vncSession() -> SessionRecord {
        SessionRecord(
            id: "session_vnc_retry_integration",
            folderId: nil,
            name: "VNC Desktop",
            protocol: "vnc",
            host: "desktop.example.com",
            port: 5900,
            username: "admin",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
    }

    private static func rdpSession() -> SessionRecord {
        SessionRecord(
            id: "session_rdp_retry_integration",
            folderId: nil,
            name: "RDP Desktop",
            protocol: "rdp",
            host: "windows.example.com",
            port: 3389,
            username: "admin",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
    }
}

private final class UploadIntegrationGraphicsRuntimeManager: GraphicsRuntimeManaging {
    func start(request: GraphicsRuntimeStartRequest) throws -> GraphicsRuntimeStatus {
        GraphicsRuntimeStatus(
            runtimeID: "graphics_vnc_upload_integration",
            status: "running",
            diagnostic: "connected"
        )
    }

    func stop(runtimeID: String) -> GraphicsRuntimeStatus {
        GraphicsRuntimeStatus(
            runtimeID: runtimeID,
            status: "stopped",
            diagnostic: "stopped"
        )
    }
}

private enum GraphicsUploadIntegrationTestError: Error {
    case startFailed
}

private final class SequencedUploadIntegrationGraphicsRuntimeManager: GraphicsRuntimeManaging {
    private let lock = NSLock()
    private var outcomes: [Result<GraphicsRuntimeStatus, Error>]
    private let gatedAttempt: Int?
    private let startGate = DispatchSemaphore(value: 0)
    private var recordedRequests: [GraphicsRuntimeStartRequest] = []
    private var recordedStoppedRuntimeIDs: [String] = []

    init(
        outcomes: [Result<GraphicsRuntimeStatus, Error>],
        gatedAttempt: Int? = nil
    ) {
        self.outcomes = outcomes
        self.gatedAttempt = gatedAttempt
    }

    var requests: [GraphicsRuntimeStartRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    var stoppedRuntimeIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStoppedRuntimeIDs
    }

    func start(request: GraphicsRuntimeStartRequest) throws -> GraphicsRuntimeStatus {
        let attempt: Int
        let outcome: Result<GraphicsRuntimeStatus, Error>
        lock.lock()
        recordedRequests.append(request)
        attempt = recordedRequests.count
        outcome = outcomes.removeFirst()
        lock.unlock()

        if attempt == gatedAttempt {
            startGate.wait()
        }
        return try outcome.get()
    }

    func stop(runtimeID: String) -> GraphicsRuntimeStatus {
        lock.lock()
        recordedStoppedRuntimeIDs.append(runtimeID)
        lock.unlock()
        return GraphicsRuntimeStatus(
            runtimeID: runtimeID,
            status: "stopped",
            diagnostic: "stopped"
        )
    }

    func releaseStartGate() {
        startGate.signal()
    }
}

private final class UploadIntegrationEmbeddedGraphicsSession: EmbeddedGraphicsSession {
    var onFrame: ((GraphicsFrame) -> Void)?
    var onPointerPosition: ((_ x: Int, _ y: Int) -> Void)?
    var onPointerVisibilityChanged: ((_ isVisible: Bool) -> Void)?
    var onPointerBitmap: ((GraphicsPointerBitmap) -> Void)?

    func start() throws {}
    func stop() {}
    func sendInput(_ event: GraphicsInputEvent) {}
}

private final class UploadIntegrationSavedSessionOpenRecorder: SavedSessionOpenRecording {
    private(set) var requests: [(databasePath: String, id: String)] = []

    func markSessionRecordOpened(databasePath: String, id: String) throws -> SessionRecord {
        requests.append((databasePath: databasePath, id: id))
        return SessionRecord(
            id: id,
            folderId: nil,
            name: "RDP Desktop",
            protocol: "rdp",
            host: "windows.example.com",
            port: 3389,
            username: "Administrator",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: "2026-08-04T00:00:00Z"
        )
    }
}

private func uploadIntegrationArgumentValue(_ flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

@MainActor
private func uploadIntegrationSubview(in root: NSView, identifier: String) -> NSView? {
    if root.accessibilityIdentifier() == identifier {
        return root
    }
    for subview in root.subviews {
        if let match = uploadIntegrationSubview(in: subview, identifier: identifier) {
            return match
        }
    }
    return nil
}
