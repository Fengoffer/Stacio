import Foundation
import CoreFoundation

public enum SSHConnectionDefaults {
    public static let fastConnectTimeoutMs: UInt32 = 3_000
    public static let minimumConnectTimeoutMs: UInt32 = 1_000
    public static let maximumConnectTimeoutMs: UInt32 = 300_000

    public static func normalizedConnectTimeoutMs(_ value: UInt32?) -> UInt32? {
        guard let value else {
            return nil
        }
        return min(max(value, minimumConnectTimeoutMs), maximumConnectTimeoutMs)
    }

    public static var fastConnectTimeoutSecondsString: String {
        String(fastConnectTimeoutMs / 1_000)
    }

    public static func connectTimeoutMs(fromConfigJSON configJSON: String?) -> UInt32? {
        guard let configJSON,
              let data = configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawValue = object["connectTimeoutMs"]
        else {
            return nil
        }

        let value: UInt64?
        if let number = rawValue as? NSNumber {
            let numericValue = number.doubleValue
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  numericValue.isFinite,
                  numericValue >= 0,
                  numericValue <= Double(UInt32.max),
                  numericValue.rounded(.towardZero) == numericValue
            else {
                return nil
            }
            value = UInt64(numericValue)
        } else if let string = rawValue as? String {
            value = UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
        guard let value else {
            return nil
        }
        return normalizedConnectTimeoutMs(UInt32(clamping: value))
    }
}
