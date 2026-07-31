import AppKit
import XCTest
@testable import StacioApp

final class RemoteEditorPresentationStoreTests: XCTestCase {
    func testRoundTripsIndependentSidecarFrameAndScreenValues() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsRemoteEditorPresentationStore(
            defaults: defaults,
            frameAutosaveName: .init("Workbench.Test")
        )
        let identity = RemoteEditorScreenIdentity(
            displayID: 42,
            localizedName: "Studio Display",
            frame: NSRect(x: 1_440, y: 0, width: 2_560, height: 1_440)
        )

        store.saveSidecarTargetWidth(760)
        store.saveFloatingFrame(NSRect(x: 100, y: 120, width: 980, height: 720))
        store.saveScreenIdentity(identity)

        XCTAssertEqual(store.sidecarTargetWidth(), 760)
        XCTAssertEqual(store.floatingFrame(), NSRect(x: 100, y: 120, width: 980, height: 720))
        XCTAssertEqual(store.screenIdentity(), identity)
    }

    func testRejectsNonFiniteAndOutOfContractValuesWithoutOverwritingLastGoodValues() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsRemoteEditorPresentationStore(
            defaults: defaults,
            frameAutosaveName: .init("Workbench.Test")
        )
        let validFrame = NSRect(x: 10, y: 20, width: 980, height: 720)
        store.saveSidecarTargetWidth(680)
        store.saveFloatingFrame(validFrame)

        store.saveSidecarTargetWidth(.nan)
        store.saveSidecarTargetWidth(479)
        store.saveSidecarTargetWidth(4_097)
        store.saveFloatingFrame(NSRect(x: CGFloat.infinity, y: 0, width: 0, height: -1))

        XCTAssertEqual(store.sidecarTargetWidth(), 680)
        XCTAssertEqual(store.floatingFrame(), validFrame)
    }

    func testSidecarKeyIsScopedByWorkbenchAutosaveName() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = UserDefaultsRemoteEditorPresentationStore(
            defaults: defaults,
            frameAutosaveName: .init("A")
        )
        let second = UserDefaultsRemoteEditorPresentationStore(
            defaults: defaults,
            frameAutosaveName: .init("B")
        )

        first.saveSidecarTargetWidth(720)

        XCTAssertEqual(first.sidecarTargetWidth(), 720)
        XCTAssertNil(second.sidecarTargetWidth())
    }

    func testInvalidPersistedDataReadsAsMissingAndNilScreenRemovesIdentity() throws {
        let suiteName = "\(#function)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsRemoteEditorPresentationStore(
            defaults: defaults,
            frameAutosaveName: .init("Workbench.Test")
        )

        defaults.set("not-a-number", forKey: store.sidecarWidthKeyForTesting)
        defaults.set("not-a-frame", forKey: UserDefaultsRemoteEditorPresentationStore.floatingFrameKey)
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsRemoteEditorPresentationStore.screenKey)

        XCTAssertNil(store.sidecarTargetWidth())
        XCTAssertNil(store.floatingFrame())
        XCTAssertNil(store.screenIdentity())

        store.saveScreenIdentity(.init(
            displayID: 7,
            localizedName: "Display",
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        ))
        XCTAssertNotNil(store.screenIdentity())
        store.saveScreenIdentity(nil)
        XCTAssertNil(store.screenIdentity())
    }
}
