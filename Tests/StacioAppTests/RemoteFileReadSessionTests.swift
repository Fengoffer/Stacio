import XCTest
@testable import StacioApp

final class RemoteFileReadSessionTests: XCTestCase {
    func testCloseIsIdempotentAndPreventsReads() throws {
        let readCount = LockedCounter()
        let closeCount = LockedCounter()
        let session = RemoteFileReadSession(
            read: { _, _, _ in
                readCount.increment()
                return Data([1, 2, 3])
            },
            close: {
                closeCount.increment()
            }
        )

        XCTAssertEqual(try session.read(remotePath: "/tmp/a", offset: 0, length: 3), Data([1, 2, 3]))
        session.close()
        session.close()

        XCTAssertEqual(readCount.value, 1)
        XCTAssertEqual(closeCount.value, 1)
        XCTAssertTrue(session.isClosed)
        XCTAssertThrowsError(try session.read(remotePath: "/tmp/a", offset: 0, length: 3)) { error in
            XCTAssertEqual(error as? RemoteFileReadSessionError, .closed)
        }
    }

    func testDeferredSessionOpensOnceAndClosesNativeSession() throws {
        let openCount = LockedCounter()
        let nativeReadCount = LockedCounter()
        let nativeCloseCount = LockedCounter()
        let fallbackReadCount = LockedCounter()
        let session = RemoteFileReadSession.deferred(
            open: {
                openCount.increment()
                return RemoteFileReadSession(
                    read: { _, _, _ in
                        nativeReadCount.increment()
                        return Data([4])
                    },
                    close: {
                        nativeCloseCount.increment()
                    }
                )
            },
            fallback: { _, _, _ in
                fallbackReadCount.increment()
                return Data([9])
            }
        )

        XCTAssertEqual(try session.read(remotePath: "/tmp/a", offset: 0, length: 1), Data([4]))
        XCTAssertEqual(try session.read(remotePath: "/tmp/a", offset: 1, length: 1), Data([4]))
        XCTAssertEqual(openCount.value, 1)
        XCTAssertEqual(nativeReadCount.value, 2)
        XCTAssertEqual(fallbackReadCount.value, 0)

        session.close()
        XCTAssertEqual(nativeCloseCount.value, 1)
    }

    func testDeferredSessionFallsBackWhenNativeOpenIsUnavailable() throws {
        let openCount = LockedCounter()
        let fallbackReadCount = LockedCounter()
        let session = RemoteFileReadSession.deferred(
            open: {
                openCount.increment()
                throw WorkbenchSessionOpenError.protocolRuntimeUnavailable("native-read-session")
            },
            fallback: { _, _, _ in
                fallbackReadCount.increment()
                return Data([7])
            }
        )

        XCTAssertEqual(try session.read(remotePath: "/tmp/a", offset: 0, length: 1), Data([7]))
        XCTAssertEqual(try session.read(remotePath: "/tmp/a", offset: 0, length: 1), Data([7]))
        XCTAssertEqual(openCount.value, 1)
        XCTAssertEqual(fallbackReadCount.value, 2)
    }

    func testCloseDoesNotWaitForDeferredNativeOpenAndClosesLateHandle() {
        let openStarted = DispatchSemaphore(value: 0)
        let releaseOpen = DispatchSemaphore(value: 0)
        let closeReturned = DispatchSemaphore(value: 0)
        let readFinished = DispatchSemaphore(value: 0)
        let nativeCloseCount = LockedCounter()
        let successfulReadCount = LockedCounter()
        let session = RemoteFileReadSession.deferred(
            open: {
                openStarted.signal()
                _ = releaseOpen.wait(timeout: .now() + 1)
                return RemoteFileReadSession(
                    read: { _, _, _ in Data([1]) },
                    close: { nativeCloseCount.increment() }
                )
            },
            fallback: { _, _, _ in Data([9]) }
        )

        DispatchQueue.global(qos: .userInitiated).async {
            if (try? session.read(remotePath: "/tmp/a", offset: 0, length: 1)) != nil {
                successfulReadCount.increment()
            }
            readFinished.signal()
        }
        XCTAssertEqual(openStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            session.close()
            closeReturned.signal()
        }
        let closeResult = closeReturned.wait(timeout: .now() + 0.2)
        releaseOpen.signal()

        XCTAssertEqual(closeResult, .success)
        XCTAssertEqual(readFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(successfulReadCount.value, 0)
        XCTAssertEqual(nativeCloseCount.value, 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
