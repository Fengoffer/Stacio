import Foundation
@testable import StacioApp

func makeTestFeedbackDiagnosticLogStore() -> FeedbackDiagnosticLogStore {
    FeedbackDiagnosticLogStore(
        routeHashKey: Data(repeating: 0x42, count: 32),
        environmentProvider: {
            FeedbackDiagnosticLogEnvironment(
                appVersion: "0.14.2",
                build: "300",
                osVersion: "macOS 27.0",
                architecture: "arm64"
            )
        }
    )
}
