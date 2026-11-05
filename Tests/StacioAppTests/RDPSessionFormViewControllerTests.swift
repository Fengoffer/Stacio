import AppKit
import XCTest
@testable import StacioApp

final class RDPSessionFormViewControllerTests: XCTestCase {
    func testPrefillRestoresSavedRDPConnectionSettings() {
        let prefill = RDPSessionFormPrefill(
            user: "Administrator",
            configJSON: #"{"rdpDomain":" CORP ","rdpSecurity":"TLS","rdpIgnoreCert":true,"startupCommand":"whoami"}"#
        )

        XCTAssertEqual(
            prefill,
            RDPSessionFormPrefill(
                user: "Administrator",
                domain: "CORP",
                security: .tls,
                ignoreCert: true
            )
        )
    }

    func testPrefillRejectsLegacyOrMalformedSecurityWithoutEnablingIt() {
        XCTAssertEqual(
            RDPSessionFormPrefill(
                user: "admin",
                configJSON: #"{"rdpSecurity":"rdp","rdpIgnoreCert":true}"#
            ).security,
            .nla
        )
        XCTAssertEqual(
            RDPSessionFormPrefill(
                user: "admin",
                configJSON: #"{"rdpSecurity":"kerberos"}"#
            ).security,
            .nla
        )
        XCTAssertEqual(
            RDPSessionFormPrefill(user: "admin", configJSON: "not-json"),
            RDPSessionFormPrefill(user: "admin")
        )
    }

    func testUSBRegistryPropertiesMapToStableDeviceMetadata() throws {
        let device = try XCTUnwrap(
            IOKitRDPUSBDeviceEnumerator.deviceInfo(
                from: [
                    "idVendor": NSNumber(value: 0x0951),
                    "idProduct": NSNumber(value: 0x1666),
                    "USB Product Name": "Kingston DataTraveler",
                    "locationID": NSNumber(value: UInt32(0x1234_0000))
                ],
                interfaceClasses: [0x08]
            )
        )

        XCTAssertEqual(device.vendorID, 0x0951)
        XCTAssertEqual(device.productID, 0x1666)
        XCTAssertEqual(device.productName, "Kingston DataTraveler")
        XCTAssertEqual(device.category, .storage)
        XCTAssertEqual(device.locationID, 0x1234_0000)
    }

    func testFormResultCarriesOptionalDriveIntoOptionsAndLaunchArguments() {
        let result = RDPSessionFormResult(
            user: "Administrator",
            password: "secret",
            domain: "CORP",
            security: .nla,
            ignoreCert: false,
            width: 1440,
            height: 900,
            quality: 8,
            drive: "Shared:/tmp/rdp-share"
        )

        XCTAssertEqual(result.makeOptions(host: "rdp.example.test", port: 3389).drive, "Shared:/tmp/rdp-share")
        XCTAssertEqual(
            Array(result.makeAdapterArguments().suffix(2)),
            ["--drive", "Shared:/tmp/rdp-share"]
        )
    }

    @MainActor
    func testDriveFieldsSubmitOptionalRDPDRShare() throws {
        var submitted: RDPSessionFormResult?
        let controller = RDPSessionFormViewController { submitted = $0 }
        let rootView = controller.view

        let userField = try XCTUnwrap(
            rdpFormSubview(
                in: rootView,
                identifier: "Stacio.RDP.user",
                as: NSTextField.self
            )
        )
        let passwordField = try XCTUnwrap(
            rdpFormSubview(
                in: rootView,
                identifier: "Stacio.RDP.password",
                as: NSSecureTextField.self
            )
        )
        let driveNameField = try XCTUnwrap(
            rdpFormSubview(
                in: rootView,
                identifier: "Stacio.RDP.driveName",
                as: NSTextField.self
            )
        )
        let drivePathField = try XCTUnwrap(
            rdpFormSubview(
                in: rootView,
                identifier: "Stacio.RDP.drivePath",
                as: NSTextField.self
            )
        )
        let connectButton = try XCTUnwrap(
            rdpFormSubview(
                in: rootView,
                identifier: "Stacio.RDP.connect",
                as: NSButton.self
            )
        )

        userField.stringValue = "Administrator"
        passwordField.stringValue = "secret"
        driveNameField.stringValue = "Shared"
        drivePathField.stringValue = FileManager.default.temporaryDirectory.path
        _ = drivePathField.sendAction(drivePathField.action, to: drivePathField.target)
        connectButton.performClick(nil as Any?)

        XCTAssertEqual(
            submitted?.drive,
            "Shared:\(FileManager.default.temporaryDirectory.path)"
        )
    }

    @MainActor
    func testSecurityPopupDoesNotOfferUnsupportedLegacyRDP() throws {
        let controller = RDPSessionFormViewController { _ in }
        let popup = try XCTUnwrap(
            rdpFormSubviews(in: controller.view, as: NSPopUpButton.self).first {
                $0.itemTitles.contains(RDPSecurityType.nla.displayName)
            }
        )

        XCTAssertEqual(popup.itemTitles, [
            RDPSecurityType.nla.displayName,
            RDPSecurityType.tls.displayName
        ])
    }

    @MainActor
    func testFormAppliesSavedPrefillAndShowsUSBAsExplicitlyUnsupported() throws {
        let devices = [
            RDPUSBDeviceInfo(
                vendorID: 0x0951,
                productID: 0x1666,
                productName: "Kingston DataTraveler",
                category: .storage,
                locationID: 1
            ),
            RDPUSBDeviceInfo(
                vendorID: 0x046D,
                productID: 0xC534,
                productName: "USB Receiver",
                category: .hid,
                locationID: 2
            )
        ]
        let controller = RDPSessionFormViewController(
            prefill: RDPSessionFormPrefill(
                user: "Administrator",
                domain: "CORP",
                security: .tls,
                ignoreCert: true
            ),
            usbDeviceEnumerator: StaticRDPUSBDeviceEnumerator(devices: devices)
        ) { _ in }
        let root = controller.view

        XCTAssertEqual(
            rdpFormSubview(in: root, identifier: "Stacio.RDP.user", as: NSTextField.self)?.stringValue,
            "Administrator"
        )
        XCTAssertEqual(
            rdpFormSubview(in: root, identifier: "Stacio.RDP.domain", as: NSTextField.self)?.stringValue,
            "CORP"
        )
        XCTAssertEqual(
            rdpFormSubview(in: root, identifier: "Stacio.RDP.security", as: NSPopUpButton.self)?.titleOfSelectedItem,
            RDPSecurityType.tls.displayName
        )
        XCTAssertEqual(
            rdpFormSubview(in: root, identifier: "Stacio.RDP.ignoreCert", as: NSSwitch.self)?.state,
            .on
        )

        let unsupported = try XCTUnwrap(
            rdpFormSubview(
                in: root,
                identifier: "Stacio.RDP.usbUnsupported",
                as: NSTextField.self
            )
        )
        XCTAssertEqual(unsupported.stringValue, RDPUSBRedirectCapabilityView.unsupportedMessage)
        let deviceSwitches = rdpFormSubviews(in: root, as: NSButton.self).filter {
            $0.identifier?.rawValue.hasPrefix("Stacio.RDP.usbDevice.") == true
        }
        XCTAssertEqual(deviceSwitches.count, devices.count)
        XCTAssertTrue(deviceSwitches.allSatisfy { !$0.isEnabled && $0.state == .off })
        XCTAssertFalse(
            rdpFormSubviews(in: root, as: NSButton.self).contains { $0.title == "应用并重连" }
        )
    }
}

private struct StaticRDPUSBDeviceEnumerator: RDPUSBDeviceEnumerating {
    let devices: [RDPUSBDeviceInfo]

    func enumerateDevices() -> [RDPUSBDeviceInfo] {
        devices
    }
}

private func rdpFormSubviews<T: NSView>(in root: NSView, as type: T.Type) -> [T] {
    var matches = root as? T == nil ? [] : [root as! T]
    for child in root.subviews {
        matches.append(contentsOf: rdpFormSubviews(in: child, as: type))
    }
    return matches
}

private func rdpFormSubview<T: NSView>(
    in root: NSView,
    identifier: String,
    as type: T.Type
) -> T? {
    if let matching = root as? T,
       matching.identifier?.rawValue == identifier
    {
        return matching
    }
    for child in root.subviews {
        if let matching = rdpFormSubview(in: child, identifier: identifier, as: type) {
            return matching
        }
    }
    return nil
}
