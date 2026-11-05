import Foundation
import XCTest
@testable import StacioApp

final class AppSettingsStoreTests: XCTestCase {
    func testAutomaticReconnectDefaultsToDisabledWithConservativeValues() {
        let suiteName = "StacioAppTests.AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(defaults: defaults).snapshot()

        XCTAssertFalse(settings.terminalAutomaticReconnectEnabled)
        XCTAssertEqual(settings.terminalAutomaticReconnectIntervalSeconds, 5)
        XCTAssertEqual(settings.terminalAutomaticReconnectAttempts, 3)
    }

    func testAutomaticReconnectSettingsAreClampedAndPersisted() {
        let suiteName = "StacioAppTests.AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.terminalAutomaticReconnectEnabled = true
            settings.terminalAutomaticReconnectIntervalSeconds = 0
            settings.terminalAutomaticReconnectAttempts = 999
        }

        let settings = store.snapshot()
        XCTAssertTrue(settings.terminalAutomaticReconnectEnabled)
        XCTAssertEqual(settings.terminalAutomaticReconnectIntervalSeconds, 1)
        XCTAssertEqual(settings.terminalAutomaticReconnectAttempts, 20)
    }
}
