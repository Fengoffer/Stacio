import Foundation
import XCTest
@testable import StacioApp

final class ProductOpsPresenceTests: XCTestCase {
    func testSignedLicenseUsesAnonymousDeviceAndExplicitLicenseID() {
        let state = LicenseState(signedLicenseToken: "signed-token", status: .active)

        let identity = ProductOpsPresenceIdentityResolver.resolve(
            state: state,
            anonymousDeviceID: "anonymous-device",
            licenseIDFromSignedToken: { token in token == "signed-token" ? "license-123" : nil }
        )

        XCTAssertEqual(identity, ProductOpsPresenceIdentity(licenseID: "license-123", deviceID: "anonymous-device"))
    }

    func testOfflineDeviceAuthorizationUsesBoundHardwareDeviceID() {
        let authorization = OfflineDeviceAuthorization(
            productID: "stacio",
            deviceID: "offline-hardware-device",
            username: "offline-user",
            email: "offline@example.com",
            plan: "professional",
            issuedAt: "2026-08-27T00:00:00Z",
            expiresAt: "2027-08-27T00:00:00Z",
            signatureKeyID: "offline-signing-key",
            signature: "signature"
        )
        let state = LicenseState(
            username: authorization.username,
            email: authorization.email,
            plan: authorization.plan,
            status: .offlineActive,
            offlineDeviceAuthorization: authorization
        )

        let identity = ProductOpsPresenceIdentityResolver.resolve(
            state: state,
            anonymousDeviceID: "anonymous-device",
            licenseIDFromSignedToken: { _ in nil }
        )

        XCTAssertEqual(identity, ProductOpsPresenceIdentity(licenseID: nil, deviceID: "offline-hardware-device"))
    }

    func testMissingLicenseUsesAnonymousDeviceWithoutLicenseID() {
        let identity = ProductOpsPresenceIdentityResolver.resolve(
            state: nil,
            anonymousDeviceID: "anonymous-device",
            licenseIDFromSignedToken: { _ in nil }
        )

        XCTAssertEqual(identity, ProductOpsPresenceIdentity(licenseID: nil, deviceID: "anonymous-device"))
    }

    func testPresenceEligibilityRequiresAuthorizedIdentity() {
        XCTAssertFalse(
            ProductOpsPresenceIdentityResolver.isEligible(
                state: nil,
                licenseIDFromSignedToken: { _ in "license-123" }
            )
        )

        XCTAssertFalse(
            ProductOpsPresenceIdentityResolver.isEligible(
                state: LicenseState(status: .inactive),
                licenseIDFromSignedToken: { _ in "license-123" }
            )
        )

        XCTAssertTrue(
            ProductOpsPresenceIdentityResolver.isEligible(
                state: LicenseState(signedLicenseToken: "signed-token", status: .active),
                licenseIDFromSignedToken: { token in token == "signed-token" ? "license-123" : nil }
            )
        )

        XCTAssertFalse(
            ProductOpsPresenceIdentityResolver.isEligible(
                state: LicenseState(signedLicenseToken: "invalid-token", status: .active),
                licenseIDFromSignedToken: { _ in nil }
            )
        )
    }

    func testSignedLicenseIdentityTrimsTokenAndResolvedLicenseID() {
        let state = LicenseState(signedLicenseToken: "  signed-token\n", status: .active)

        XCTAssertTrue(
            ProductOpsPresenceIdentityResolver.isEligible(
                state: state,
                licenseIDFromSignedToken: { token in
                    token == "signed-token" ? "  license-123\n" : nil
                }
            )
        )
        XCTAssertEqual(
            ProductOpsPresenceIdentityResolver.resolve(
                state: state,
                anonymousDeviceID: "anonymous-device",
                licenseIDFromSignedToken: { token in
                    token == "signed-token" ? "  license-123\n" : nil
                }
            ),
            ProductOpsPresenceIdentity(licenseID: "license-123", deviceID: "anonymous-device")
        )
    }

    func testWhitespaceOnlyAuthorizedIdentityIsRejected() {
        let offlineAuthorization = OfflineDeviceAuthorization(
            productID: "stacio",
            deviceID: " \n",
            username: "offline-user",
            email: "offline@example.com",
            plan: "professional",
            issuedAt: "2026-08-27T00:00:00Z",
            expiresAt: "2027-08-27T00:00:00Z",
            signatureKeyID: "offline-signing-key",
            signature: "signature"
        )
        let state = LicenseState(
            signedLicenseToken: " signed-token ",
            status: .offlineActive,
            offlineDeviceAuthorization: offlineAuthorization
        )

        XCTAssertFalse(
            ProductOpsPresenceIdentityResolver.isEligible(
                state: state,
                licenseIDFromSignedToken: { _ in " \n" }
            )
        )
        XCTAssertEqual(
            ProductOpsPresenceIdentityResolver.resolve(
                state: state,
                anonymousDeviceID: "anonymous-device",
                licenseIDFromSignedToken: { _ in " \n" }
            ),
            ProductOpsPresenceIdentity(licenseID: nil, deviceID: "anonymous-device")
        )
    }

    func testPresenceRetryClassificationStopsForPermanentFailures() {
        XCTAssertFalse(
            ProductOpsError.client(message: "HTTP 404", requestID: nil).isRetryablePresenceFailure
        )
        XCTAssertFalse(
            ProductOpsError.backend(code: "NOT_FOUND", message: "HTTP 404", requestID: nil, statusCode: 404)
                .isRetryablePresenceFailure
        )
        XCTAssertFalse(ProductOpsError.invalidURL.isRetryablePresenceFailure)
        XCTAssertTrue(ProductOpsError.server(message: "HTTP 503", requestID: nil).isRetryablePresenceFailure)
        XCTAssertTrue(
            ProductOpsError.backend(code: "UNAVAILABLE", message: "HTTP 503", requestID: nil, statusCode: 503)
                .isRetryablePresenceFailure
        )
    }

    func testPresenceRetryPolicyHonorsRetryAfterAndCapsIt() {
        let retryAfter = ProductOpsPresenceRetryPolicy.delay(
            for: .rateLimited(retryAfter: 17, requestID: nil),
            attempt: 0,
            randomUnit: 0
        )
        XCTAssertEqual(retryAfter ?? -1, 17, accuracy: 0.001)

        let capped = ProductOpsPresenceRetryPolicy.delay(
            for: .rateLimited(retryAfter: 10_000, requestID: nil),
            attempt: 0,
            randomUnit: 0
        )
        XCTAssertEqual(capped ?? -1, ProductOpsPresenceRetryPolicy.maximumDelay, accuracy: 0.001)
    }

    func testRetryAfterParsesHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: now.addingTimeInterval(45))

        XCTAssertEqual(
            ProductOpsError.retryAfter(from: header, now: now) ?? -1,
            45,
            accuracy: 0.001
        )
    }

    func testRetryAfterRejectsInvalidValue() {
        XCTAssertNil(
            ProductOpsError.retryAfter(
                from: "not-a-retry-date",
                now: Date(timeIntervalSince1970: 1_900_000_000)
            )
        )
    }

    func testPresenceRetryPolicyUsesBoundedBackoff() {
        let first = ProductOpsPresenceRetryPolicy.delay(
            for: .server(message: "HTTP 503", requestID: nil),
            attempt: 0,
            randomUnit: 0.5
        )
        let second = ProductOpsPresenceRetryPolicy.delay(
            for: .server(message: "HTTP 503", requestID: nil),
            attempt: 1,
            randomUnit: 0.5
        )
        XCTAssertEqual(first ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(second ?? -1, 60, accuracy: 0.001)
        XCTAssertNil(
            ProductOpsPresenceRetryPolicy.delay(
                for: .server(message: "HTTP 503", requestID: nil),
                attempt: ProductOpsPresenceRetryPolicy.maximumAttempts,
                randomUnit: 0.5
            )
        )
    }

    func testPresencePayloadEncodesSelectedUpdateChannel() throws {
        let payload = ProductOpsPresencePayload(
            licenseID: "license-123",
            anonymousDeviceID: "anonymous-device",
            appVersion: "0.14.10",
            buildNumber: "474",
            architecture: "arm64",
            updateChannel: .beta
        )

        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["updateChannel"] as? String, "beta")
    }
}
