import XCTest
@testable import StacioApp

final class WorkspaceCapabilityPolicyTests: XCTestCase {
    func testConsoleAllowsTerminalAdjacentCapabilitiesOnly() {
        let allowed = WorkspaceCapability.allCases.filter {
            WorkspaceCapabilityPolicy.allows($0, for: .console)
        }

        XCTAssertEqual(Set(allowed), [.ai, .diagnostics])
        XCTAssertFalse(WorkspaceCapabilityPolicy.allows(.deviceDashboard, for: .console))
        XCTAssertFalse(WorkspaceCapabilityPolicy.allows(.files, for: .console))
        XCTAssertFalse(WorkspaceCapabilityPolicy.allows(.tunnels, for: .console))
    }

    func testSSHAllowsEveryRemoteWorkspaceCapability() {
        for capability in WorkspaceCapability.allCases {
            XCTAssertTrue(WorkspaceCapabilityPolicy.allows(capability, for: .ssh), "\(capability)")
        }
    }

    func testUnsupportedRemoteProtocolsDenyEveryRemoteWorkspaceCapability() {
        let protocols: [WorkspaceSessionProtocol] = [
            .scp,
            .sftp,
            .vnc,
            .serial,
            .telnet,
            .unsupportedRemote("rdp")
        ]

        for sessionProtocol in protocols {
            for capability in WorkspaceCapability.allCases {
                XCTAssertFalse(
                    WorkspaceCapabilityPolicy.allows(capability, for: sessionProtocol),
                    "\(sessionProtocol): \(capability)"
                )
            }
        }
    }

    func testNonRemoteWorkspaceStatesPreserveExistingCapabilityAvailability() {
        for sessionProtocol in [
            WorkspaceSessionProtocol.noSession,
            .local,
            .browser,
            .unmanaged
        ] {
            for capability in WorkspaceCapability.allCases {
                XCTAssertTrue(
                    WorkspaceCapabilityPolicy.allows(capability, for: sessionProtocol),
                    "\(sessionProtocol): \(capability)"
                )
            }
        }
    }

    func testRemoteProtocolNamesNormalizeIntoExhaustivePolicyInputs() {
        XCTAssertEqual(WorkspaceSessionProtocol(remoteProtocolName: " SSH "), .ssh)
        XCTAssertEqual(WorkspaceSessionProtocol(remoteProtocolName: "SCP"), .scp)
        XCTAssertEqual(WorkspaceSessionProtocol(remoteProtocolName: "sFtP"), .sftp)
        XCTAssertEqual(WorkspaceSessionProtocol(remoteProtocolName: "VNC"), .vnc)
        XCTAssertEqual(WorkspaceSessionProtocol(remoteProtocolName: "Serial"), .serial)
        XCTAssertEqual(WorkspaceSessionProtocol(remoteProtocolName: " Console "), .console)
        XCTAssertEqual(WorkspaceSessionProtocol(remoteProtocolName: "TELNET"), .telnet)
        XCTAssertEqual(
            WorkspaceSessionProtocol(remoteProtocolName: "RDP"),
            .unsupportedRemote("rdp")
        )
    }
}
