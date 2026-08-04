import Foundation
import XCTest
@testable import StacioApp

final class TerminalSensitiveInputStateMachineTests: XCTestCase {
    func testRecognizesInteractivePasswordPromptsWithoutRecordingPromptText() {
        let prompts = [
            "Password:",
            "[sudo] password for deploy:",
            "deploy@example.com's password:",
            "Enter passphrase for key '/Users/mac/.ssh/id_ed25519':",
            "Current password:",
            "New password:",
            "Retype new password:",
            "(current) UNIX password:",
            "Password (again):",
            "请输入密码：",
            "root 的密码：",
            "当前密码：",
            "请输入新密码：",
            "请再次输入新密码："
        ]

        for prompt in prompts {
            let state = TerminalSensitiveInputStateMachine()

            state.ingestOutput(Array(prompt.utf8))

            XCTAssertTrue(state.isAwaitingSensitiveInput, prompt)
            XCTAssertEqual(state.retainedOutputByteCountForTesting, 0, prompt)
        }
    }

    func testRecognizesANSIWrappedPromptSplitAcrossOutputBatches() {
        let state = TerminalSensitiveInputStateMachine()

        state.ingestOutput(Array("\u{001B}[33mPass".utf8))
        XCTAssertFalse(state.isAwaitingSensitiveInput)

        state.ingestOutput(Array("word:\u{001B}[0m".utf8))

        XCTAssertTrue(state.isAwaitingSensitiveInput)
    }

    func testSubmittedOrdinaryInputClearsPreviousPromptPrefixBeforePasswordPrompt() {
        let state = TerminalSensitiveInputStateMachine()
        state.ingestOutput(Array("deploy@example.com $ ".utf8))

        state.noteOrdinaryInput(Array("sudo id\r".utf8))
        state.ingestOutput(Array("Password:".utf8))

        XCTAssertTrue(state.isAwaitingSensitiveInput)
    }

    func testRecognizesChinesePromptSplitInsideUTF8ScalarAcrossOutputBatches() {
        let state = TerminalSensitiveInputStateMachine()
        let bytes = Array("请输入密码：".utf8)
        let splitIndex = 2

        state.ingestOutput(Array(bytes[..<splitIndex]))
        XCTAssertFalse(state.isAwaitingSensitiveInput)

        state.ingestOutput(Array(bytes[splitIndex...]))

        XCTAssertTrue(state.isAwaitingSensitiveInput)
    }

    func testDoesNotTreatOrdinaryPasswordLogsAsInteractivePrompts() {
        let samples = [
            "password authentication failed\n",
            "updated password: success\n",
            "{\"field\":\"password\"}\n",
            "the password policy was refreshed",
            "错误密码：请重试\n"
        ]

        for sample in samples {
            let state = TerminalSensitiveInputStateMachine()

            state.ingestOutput(Array(sample.utf8))

            XCTAssertFalse(state.isAwaitingSensitiveInput, sample)
        }
    }

    func testOversizedLineIsDiscardedUntilBoundaryWithoutBlockingNextPrompt() {
        let state = TerminalSensitiveInputStateMachine()

        state.ingestOutput(Array(repeating: UInt8(ascii: "x"), count: 10_000))

        XCTAssertEqual(state.retainedOutputByteCountForTesting, 0)
        XCTAssertFalse(state.isAwaitingSensitiveInput)

        state.ingestOutput(Array("\nPassword:".utf8))

        XCTAssertTrue(state.isAwaitingSensitiveInput)
    }

    func testSubmittingOrCancellingSensitiveInputImmediatelyEndsSensitiveMode() {
        for terminator in [[UInt8(ascii: "\r")], [UInt8(ascii: "\n")], [3]] {
            let state = TerminalSensitiveInputStateMachine()
            state.ingestOutput(Array("Password:".utf8))

            XCTAssertTrue(state.consumeSensitiveInput(Array("secret".utf8)))
            XCTAssertTrue(state.isAwaitingSensitiveInput)
            XCTAssertTrue(state.consumeSensitiveInput(terminator))

            XCTAssertFalse(state.isAwaitingSensitiveInput)
        }
    }

    func testSensitiveInputOnlyAcceptsBytesThroughFirstTerminator() {
        let state = TerminalSensitiveInputStateMachine()
        state.ingestOutput(Array("Password:".utf8))

        let accepted = state.consumeSensitiveInputBytes(
            Array("single-secret\rwhoami\r".utf8)
        )

        XCTAssertEqual(accepted, Array("single-secret\r".utf8))
        XCTAssertFalse(state.isAwaitingSensitiveInput)
    }

    func testSensitiveModeExpiresWithoutRetainingInput() {
        var now = Date(timeIntervalSince1970: 1_000)
        let state = TerminalSensitiveInputStateMachine(
            timeout: 30,
            clock: { now }
        )
        state.ingestOutput(Array("Password:".utf8))
        XCTAssertTrue(state.consumeSensitiveInput(Array("never-store-me".utf8)))

        now = now.addingTimeInterval(31)

        XCTAssertFalse(state.isAwaitingSensitiveInput)
        XCTAssertEqual(state.retainedOutputByteCountForTesting, 0)
    }

    func testExpiredPromptStillPrivatelyConsumesTheNextInputLine() {
        var now = Date(timeIntervalSince1970: 2_000)
        let state = TerminalSensitiveInputStateMachine(
            timeout: 30,
            clock: { now }
        )
        state.ingestOutput(Array("Password:".utf8))

        now = now.addingTimeInterval(31)
        XCTAssertFalse(state.isAwaitingSensitiveInput)

        let accepted = state.consumeSensitiveInputBytes(Array("late-secret\rwhoami".utf8))

        XCTAssertEqual(accepted, Array("late-secret\r".utf8))
        XCTAssertFalse(state.isSensitiveInputProtectionActive)
    }

    func testObservationRedactionDropsPotentialEchoLineWithoutStoringSecret() {
        let state = TerminalSensitiveInputStateMachine()
        state.ingestOutput(Array("Password:".utf8))
        XCTAssertTrue(state.consumeSensitiveInput(Array("top-secret\r".utf8)))

        let observable = state.redactOutputForObservation(
            Array("top-secret\r\ncommand output\r\n".utf8)
        )

        XCTAssertFalse(String(decoding: observable, as: UTF8.self).contains("top-secret"))
        XCTAssertTrue(String(decoding: observable, as: UTF8.self).contains("command output"))
        XCTAssertEqual(state.retainedOutputByteCountForTesting, 0)
    }

    func testObservationRedactionSuppressesCharacterEchoBeforeReturn() {
        let state = TerminalSensitiveInputStateMachine()
        let prompt = Array("Password:".utf8)
        state.ingestOutput(prompt)

        XCTAssertEqual(state.redactOutputForObservation(prompt), prompt)
        XCTAssertTrue(state.consumeSensitiveInput(Array("partial-secret".utf8)))

        let prematureEcho = state.redactOutputForObservation(
            Array("partial-secret".utf8)
        )

        XCTAssertEqual(prematureEcho, [])
        XCTAssertTrue(state.consumeSensitiveInput([13]))
    }

    func testRetryPromptNeverReleasesPreviousPasswordEchoFromSameBatch() {
        let state = TerminalSensitiveInputStateMachine()
        let prompt = Array("Password:".utf8)
        state.ingestOutput(prompt)
        XCTAssertEqual(state.redactOutputForObservation(prompt), prompt)
        XCTAssertTrue(state.consumeSensitiveInput(Array("previous-secret\r".utf8)))

        let retryOutput = Array(
            "previous-secret\r\nSorry, try again.\r\nPassword:".utf8
        )
        state.ingestOutput(retryOutput)
        let observable = state.redactOutputForObservation(retryOutput)
        let text = String(decoding: observable, as: UTF8.self)

        XCTAssertFalse(text.contains("previous-secret"))
        XCTAssertTrue(text.contains("Sorry, try again."))
        XCTAssertTrue(text.contains("Password:"))
        XCTAssertTrue(state.isAwaitingSensitiveInput)
    }

    func testImmediateRetryPromptWithoutEchoRemainsObservable() {
        let state = TerminalSensitiveInputStateMachine()
        let prompt = Array("Password:".utf8)
        state.ingestOutput(prompt)
        XCTAssertEqual(state.redactOutputForObservation(prompt), prompt)
        XCTAssertTrue(state.consumeSensitiveInput(Array("wrong-secret\r".utf8)))

        state.ingestOutput(prompt)

        XCTAssertEqual(state.redactOutputForObservation(prompt), prompt)
        XCTAssertTrue(state.isAwaitingSensitiveInput)
    }

    func testPasswordLikeEchoWhileAlreadySensitiveRemainsRedacted() {
        let state = TerminalSensitiveInputStateMachine()
        let prompt = Array("Password:".utf8)
        state.ingestOutput(prompt)
        XCTAssertEqual(state.redactOutputForObservation(prompt), prompt)
        XCTAssertTrue(state.consumeSensitiveInput(prompt))

        state.ingestOutput(prompt)

        XCTAssertEqual(state.redactOutputForObservation(prompt), [])
        XCTAssertTrue(state.isAwaitingSensitiveInput)
    }
}
