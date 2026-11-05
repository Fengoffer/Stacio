import XCTest
import Foundation
@testable import StacioApp

/// P3-8c：CredentialUseLease owner 隔离、VerificationRequest 状态机、access mode 隔离与 setup 期限。
final class CredentialUseLeaseAndVerificationTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - use lease owner 隔离

    func testUseLeaseOwnerIsolation() {
        // 三类 owner 不能互换
        XCTAssertTrue(
            CredentialUseLeasePolicy.ownerIsolationValid(leaseOwner: .attempt, requestedBy: .attempt)
        )
        XCTAssertFalse(
            CredentialUseLeasePolicy.ownerIsolationValid(leaseOwner: .attempt, requestedBy: .setup),
            "Attempt lease 不能被 setup 操作"
        )
        XCTAssertFalse(
            CredentialUseLeasePolicy.ownerIsolationValid(leaseOwner: .attempt, requestedBy: .configurationAction)
        )
        XCTAssertFalse(
            CredentialUseLeasePolicy.ownerIsolationValid(leaseOwner: .setup, requestedBy: .configurationAction)
        )
        XCTAssertTrue(
            CredentialUseLeasePolicy.ownerIsolationValid(leaseOwner: .configurationAction, requestedBy: .configurationAction)
        )
    }

    // MARK: - verification request 状态机

    func testVerificationRequestClosedStateMachine() {
        // prepared → inFlight → settledSucceeded
        XCTAssertEqual(
            ConfigurationVerificationRequestStateMachine.destination(from: .prepared, event: .markInFlight),
            .inFlight
        )
        XCTAssertEqual(
            ConfigurationVerificationRequestStateMachine.destination(from: .inFlight, event: .settleSucceeded),
            .settledSucceeded
        )
        // prepared → settledCancelled
        XCTAssertEqual(
            ConfigurationVerificationRequestStateMachine.destination(from: .prepared, event: .settleCancelled),
            .settledCancelled
        )
        // inFlight → cancellationRequested → settled*
        XCTAssertEqual(
            ConfigurationVerificationRequestStateMachine.destination(from: .inFlight, event: .requestCancellation),
            .cancellationRequested
        )
        XCTAssertEqual(
            ConfigurationVerificationRequestStateMachine.destination(from: .cancellationRequested, event: .settleFailed),
            .settledFailed
        )
        // inFlight → stateUnknown
        XCTAssertEqual(
            ConfigurationVerificationRequestStateMachine.destination(from: .inFlight, event: .stateUnknown),
            .stateUnknown
        )
        // 终态无出口
        XCTAssertNil(
            ConfigurationVerificationRequestStateMachine.destination(from: .settledSucceeded, event: .markInFlight)
        )
        XCTAssertNil(
            ConfigurationVerificationRequestStateMachine.destination(from: .prepared, event: .settleSucceeded),
            "prepared 不能直接 settledSucceeded"
        )
        XCTAssertNil(
            ConfigurationVerificationRequestStateMachine.destination(from: .stateUnknown, event: .settleSucceeded)
        )
    }

    // MARK: - access mode 隔离

    func testNoneModeZeroCapabilityAndLateCallbackCannotMigrate() {
        XCTAssertTrue(CredentialAccessModePolicy.lateCallbackCannotMigrateFromNone(mode: .none))
        XCTAssertFalse(CredentialAccessModePolicy.lateCallbackCannotMigrateFromNone(mode: .setupPending))
        // none 零 generation/use lease/setup/lifecycle：任何操作拒绝
        XCTAssertFalse(
            CredentialAccessModePolicy.operationAllowed(mode: .none, operation: .setupOnly)
        )
        XCTAssertFalse(
            CredentialAccessModePolicy.operationAllowed(mode: .none, operation: .configurationOnly)
        )
        XCTAssertFalse(
            CredentialAccessModePolicy.operationAllowed(mode: .none, operation: .readOnly)
        )
        // setupPending 只允许 setup；activeConfiguration 只允许 configuration
        XCTAssertTrue(
            CredentialAccessModePolicy.operationAllowed(mode: .setupPending, operation: .setupOnly)
        )
        XCTAssertFalse(
            CredentialAccessModePolicy.operationAllowed(mode: .setupPending, operation: .configurationOnly)
        )
        XCTAssertTrue(
            CredentialAccessModePolicy.operationAllowed(mode: .activeConfiguration, operation: .configurationOnly)
        )
        XCTAssertFalse(
            CredentialAccessModePolicy.operationAllowed(mode: .activeConfiguration, operation: .setupOnly)
        )
    }

    // MARK: - setup operation 期限与 abandon

    func testEphemeral30MinuteOwnerLease() {
        XCTAssertTrue(CredentialSetupOperationPolicy.hasAutomaticDeadline(.ephemeralSetup))
        XCTAssertFalse(CredentialSetupOperationPolicy.hasAutomaticDeadline(.savedDraft), "savedDraft 无自动期限")

        let createdAt = Self.fixedDate
        XCTAssertFalse(
            CredentialSetupOperationPolicy.ephemeralLeaseExpired(
                createdAt: createdAt, now: createdAt.addingTimeInterval(29 * 60)
            )
        )
        XCTAssertTrue(
            CredentialSetupOperationPolicy.ephemeralLeaseExpired(
                createdAt: createdAt, now: createdAt.addingTimeInterval(31 * 60)
            ),
            "ephemeral 30min 后过期"
        )
    }

    func testPendingActivationAbandonAndDrain() {
        // pendingActivation→abandoned：仅 open/suspended 可放弃
        XCTAssertTrue(CredentialSetupOperationPolicy.abandonAllowed(state: .open))
        XCTAssertTrue(CredentialSetupOperationPolicy.abandonAllowed(state: .suspended))
        XCTAssertFalse(CredentialSetupOperationPolicy.abandonAllowed(state: .activating))
        XCTAssertFalse(CredentialSetupOperationPolicy.abandonAllowed(state: .completed))
        // drain：suspended/discardRequested
        XCTAssertTrue(CredentialSetupOperationPolicy.drainSuspends(state: .suspended))
        XCTAssertTrue(CredentialSetupOperationPolicy.drainSuspends(state: .discardRequested))
        XCTAssertFalse(CredentialSetupOperationPolicy.drainSuspends(state: .activating))
    }
}
