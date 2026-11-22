import Foundation

/// Repairs JSON emitted by OpenAI-compatible relays that put raw control
/// characters inside string values.
///
/// Strict JSON forbids every unescaped code point below U+0020 inside a string.
/// Some relays forward the model output verbatim, so an otherwise usable answer
/// fails to decode. Rewriting only the characters that sit between quotes keeps
/// the surrounding structure untouched.
enum AIJSONControlCharacterRepair {
    static func repair(_ json: String) -> String {
        var output = ""
        output.reserveCapacity(json.count + 64)
        var isInsideString = false
        var isEscaped = false

        for scalar in json.unicodeScalars {
            if isEscaped {
                output.unicodeScalars.append(scalar)
                isEscaped = false
                continue
            }

            switch scalar {
                case "\\":
                    isEscaped = true
                    output.unicodeScalars.append(scalar)
                case "\"":
                    isInsideString.toggle()
                    output.unicodeScalars.append(scalar)
                default:
                    // Escape every control code point, not just the common three: the
                    // decoder rejects the rest just as firmly.
                    if isInsideString, scalar.value < 0x20 {
                        let hex = String(format: "\\u%04x", scalar.value)
                        output.append(hex)
                    } else {
                        output.unicodeScalars.append(scalar)
                    }
            }
        }

        return output
    }
}