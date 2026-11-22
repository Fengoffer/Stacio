import Foundation

/// Structural checks for JSON bodies returned by OpenAI-compatible relays.
enum AIJSONStructure {
    /// Whether braces and brackets balance and nest correctly outside string
    /// literals. A payload cut off mid-stream still parses as far as it goes, so
    /// salvaging a field from it would present a partial answer as if it were the
    /// whole reply; only a structurally complete object may be salvaged.
    static func isCompleteObject(_ json: String) -> Bool {
        var stack: [Character] = []
        var isInsideString = false
        var isEscaped = false

        for character in json {
            if isEscaped {
                isEscaped = false
                continue
            }
            switch character {
                case "\\":
                    isEscaped = true
                case "\"":
                    isInsideString.toggle()
                case "{", "[":
                    if isInsideString == false { stack.append(character) }
                case "}":
                    if isInsideString == false {
                        guard stack.popLast() == "{" else { return false }
                    }
                case "]":
                    if isInsideString == false {
                        guard stack.popLast() == "[" else { return false }
                    }
                default:
                    break
            }
        }

        return stack.isEmpty && isInsideString == false
    }
}
