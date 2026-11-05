import Foundation
import IOKit
import IOKit.usb

public enum RDPUSBDeviceCategory: String, CaseIterable, Equatable, Hashable {
    case storage
    case hid
    case printer
    case smartCard
    case other

    public var displayName: String {
        switch self {
        case .storage:
            return "存储"
        case .hid:
            return "HID"
        case .printer:
            return "打印机"
        case .smartCard:
            return "智能卡"
        case .other:
            return "其他"
        }
    }
}

public struct RDPUSBDeviceInfo: Equatable, Hashable {
    public let vendorID: Int
    public let productID: Int
    public let productName: String
    public let category: RDPUSBDeviceCategory
    public let locationID: UInt32?

    public init(
        vendorID: Int,
        productID: Int,
        productName: String,
        category: RDPUSBDeviceCategory,
        locationID: UInt32? = nil
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.category = category
        self.locationID = locationID
    }

    public var identifier: String {
        let location = locationID.map(String.init) ?? "unknown"
        return String(format: "%04x-%04x-%@", vendorID, productID, location)
    }

    public var vendorProductDescription: String {
        String(format: "VID %04X · PID %04X", vendorID, productID)
    }
}

public protocol RDPUSBDeviceEnumerating {
    func enumerateDevices() -> [RDPUSBDeviceInfo]
}

/// Enumerates USB metadata exposed by IOKit. Reading these registry properties
/// does not claim or detach a device and therefore does not require a USB
/// entitlement. The current embedded RDP transport uses the results only to
/// explain capability; it does not advertise unsupported URBDRC forwarding.
public final class IOKitRDPUSBDeviceEnumerator: RDPUSBDeviceEnumerating {
    public init() {}

    public func enumerateDevices() -> [RDPUSBDeviceInfo] {
        var devicesByIdentifier: [String: RDPUSBDeviceInfo] = [:]
        for className in ["IOUSBHostDevice", kIOUSBDeviceClassName] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != 0 {
                if let properties = Self.properties(for: service),
                   let device = Self.deviceInfo(
                       from: properties,
                       interfaceClasses: Self.interfaceClasses(for: service)
                   ) {
                    devicesByIdentifier[device.identifier] = device
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
        }

        return devicesByIdentifier.values.sorted {
            let comparison = $0.productName.localizedCaseInsensitiveCompare($1.productName)
            if comparison == .orderedSame {
                return $0.identifier < $1.identifier
            }
            return comparison == .orderedAscending
        }
    }

    static func deviceInfo(
        from properties: [String: Any],
        interfaceClasses: [Int] = []
    ) -> RDPUSBDeviceInfo? {
        guard let vendorID = intValue(in: properties, keys: ["idVendor", "kUSBVendorID"]),
              let productID = intValue(in: properties, keys: ["idProduct", "kUSBProductID"]),
              (1...0xFFFF).contains(vendorID),
              (1...0xFFFF).contains(productID)
        else {
            return nil
        }

        let rawProductName = stringValue(
            in: properties,
            keys: ["USB Product Name", "kUSBProductString", "Product Name"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let productName = rawProductName?.isEmpty == false
            ? rawProductName!
            : String(format: "USB %04X:%04X", vendorID, productID)
        let deviceClass = intValue(in: properties, keys: ["bDeviceClass", "kUSBDeviceClass"])
        let locationID = intValue(in: properties, keys: ["locationID", "kUSBDevicePropertyLocationID"])
            .flatMap { UInt32(exactly: $0) }

        return RDPUSBDeviceInfo(
            vendorID: vendorID,
            productID: productID,
            productName: productName,
            category: category(deviceClass: deviceClass, interfaceClasses: interfaceClasses),
            locationID: locationID
        )
    }

    static func category(
        deviceClass: Int?,
        interfaceClasses: [Int]
    ) -> RDPUSBDeviceCategory {
        let classes = Set(interfaceClasses + [deviceClass].compactMap { $0 })
        if classes.contains(0x0B) { return .smartCard }
        if classes.contains(0x07) { return .printer }
        if classes.contains(0x08) { return .storage }
        if classes.contains(0x03) { return .hid }
        return .other
    }

    private static func properties(for entry: io_registry_entry_t) -> [String: Any]? {
        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            entry,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
            let properties = unmanagedProperties?.takeRetainedValue()
        else {
            return nil
        }
        return properties as NSDictionary as? [String: Any]
    }

    private static func interfaceClasses(
        for entry: io_registry_entry_t,
        remainingDepth: Int = 4
    ) -> [Int] {
        guard remainingDepth > 0 else { return [] }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var classes: [Int] = []
        var child = IOIteratorNext(iterator)
        while child != 0 {
            if let properties = properties(for: child),
               let interfaceClass = intValue(
                   in: properties,
                   keys: ["bInterfaceClass", "kUSBInterfaceClass"]
               ) {
                classes.append(interfaceClass)
            }
            classes.append(contentsOf: interfaceClasses(for: child, remainingDepth: remainingDepth - 1))
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return classes
    }

    private static func intValue(in properties: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let number = properties[key] as? NSNumber {
                return number.intValue
            }
            if let value = properties[key] as? Int {
                return value
            }
        }
        return nil
    }

    private static func stringValue(in properties: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = properties[key] as? String {
                return value
            }
        }
        return nil
    }
}
