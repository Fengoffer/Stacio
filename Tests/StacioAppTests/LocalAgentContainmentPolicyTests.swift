import XCTest
import Foundation
@testable import StacioApp

/// P8-2：LocalAgentContainmentPolicy（OS 强制边界、软控制不替代、工作目录三选、PATH/环境白名单、managed 五维验证）。
final class LocalAgentContainmentPolicyTests: XCTestCase {

    // MARK: - OS 强制边界 vs 软控制

    func testOSEnforceableBoundaries() {
        XCTAssertTrue(LocalAgentContainmentPolicy.osEnforceableBoundaries(),
                      "OS 可强制的进程/文件系统/网络边界")
        XCTAssertTrue(LocalAgentContainmentPolicy.softControlsCannotReplaceContainment(),
                      "PATH/环境白名单/提示词/AGENTS.md/CLI 自带审批不能替代 containment")
    }

    // MARK: - 工作目录

    func testWorkingDirectoryRequiresVerifiedLocalReference() {
        XCTAssertTrue(LocalAgentContainmentPolicy.workingDirectoryRequiresVerifiedLocalReference(),
                      "AgentProcessWorkingDirectory 只接受已验证 Mac 本地引用")
        XCTAssertTrue(LocalAgentContainmentPolicy.remoteTargetWorkingDirectoryCannotPassToMacChdir(),
                      "远程 targetWorkingDirectory 不能传给 Mac chdir")
    }

    func testDirectoryModesThreeChoiceAndNoFallback() {
        XCTAssertEqual(LocalWorkingDirectoryMode.allCases, [.managedWorkspace, .userSelectedLocalDirectory, .askEveryTurn],
                       "本地进程目录三选")
        XCTAssertTrue(LocalAgentContainmentPolicy.unavailableDirectoryPausesInsteadOfFallback(),
                      "目录不可用时暂停不回退 Home/tmp/仓库根")
    }

    // MARK: - PATH 与环境白名单

    func testPathPoliciesThreeChoice() {
        XCTAssertEqual(LocalAgentPathPolicy.allCases, [.controlled, .loginShell, .explicitList],
                       "PATH 三策略")
    }

    func testEnvWhitelistDefaultsAndDescriptorRequired() {
        XCTAssertEqual(LocalAgentContainmentPolicy.defaultEnvWhitelist, ["LANG", "LC_*", "TERM", "TMPDIR"])
        XCTAssertTrue(LocalAgentContainmentPolicy.envWhitelistAllows("LANG", descriptorRequiredKeys: []))
        XCTAssertTrue(LocalAgentContainmentPolicy.envWhitelistAllows("LC_ALL", descriptorRequiredKeys: []), "LC_* 通配")
        XCTAssertTrue(LocalAgentContainmentPolicy.envWhitelistAllows("STACIO_REQUIRED", descriptorRequiredKeys: ["STACIO_REQUIRED"]),
                      "descriptor 必需项放行")
        XCTAssertFalse(LocalAgentContainmentPolicy.envWhitelistAllows("HOME", descriptorRequiredKeys: []))
    }

    func testEnvAlwaysRejectedSensitiveVariables() {
        XCTAssertTrue(LocalAgentContainmentPolicy.envAlwaysRejected("GITHUB_TOKEN"))
        XCTAssertTrue(LocalAgentContainmentPolicy.envAlwaysRejected("SSH_AUTH_SOCK"))
        XCTAssertTrue(LocalAgentContainmentPolicy.envAlwaysRejected("KEYCHAIN_PASSWORD"))
        XCTAssertTrue(LocalAgentContainmentPolicy.envAlwaysRejected("HTTPS_PROXY_PASS"))
        XCTAssertTrue(LocalAgentContainmentPolicy.envAlwaysRejected("OAUTH_CLIENT_SECRET"))
        XCTAssertFalse(LocalAgentContainmentPolicy.envAlwaysRejected("TERM"))
    }

    // MARK: - managed 五维验证

    func testManagedLaunchRequiresAllFiveVerified() {
        let allVerified = ContainmentVerificationResult(
            processIsolation: .verified, fileSystemIsolation: .verified,
            networkEgress: .verified, toolProxy: .verified, launchCapability: .verified
        )
        XCTAssertTrue(LocalAgentContainmentPolicy.managedLaunchAllowed(allVerified))

        // 任一未知阻止
        let unknownNetwork = ContainmentVerificationResult(
            processIsolation: .verified, fileSystemIsolation: .verified,
            networkEgress: .unknown, toolProxy: .verified, launchCapability: .verified
        )
        XCTAssertFalse(LocalAgentContainmentPolicy.managedLaunchAllowed(unknownNetwork),
                       "任一未知阻止 managed launch")

        // 任一失效阻止
        let failedFS = ContainmentVerificationResult(
            processIsolation: .verified, fileSystemIsolation: .failed,
            networkEgress: .verified, toolProxy: .verified, launchCapability: .verified
        )
        XCTAssertFalse(LocalAgentContainmentPolicy.managedLaunchAllowed(failedFS),
                       "任一失效阻止 managed launch")
    }
}
