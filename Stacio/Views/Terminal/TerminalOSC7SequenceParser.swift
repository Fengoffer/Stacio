import Foundation

enum TerminalOSC7SequenceParser {
    static func currentDirectories(from bytes: [UInt8]) -> [String] {
        guard bytes.isEmpty == false else {
            return []
        }
        let scalars = Array(String(decoding: bytes, as: UTF8.self).unicodeScalars)
        var directories: [String] = []
        var index = 0
        while index < scalars.count {
            guard scalars[index].value == 0x1B,
                  index + 3 < scalars.count,
                  scalars[index + 1].value == 0x5D,
                  scalars[index + 2].value == 0x37,
                  scalars[index + 3].value == 0x3B
            else {
                index += 1
                continue
            }

            index += 4
            var payload = String.UnicodeScalarView()
            var didTerminate = false
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar.value == 0x07 {
                    index += 1
                    didTerminate = true
                    break
                }
                if scalar.value == 0x1B,
                   index + 1 < scalars.count,
                   scalars[index + 1].value == 0x5C
                {
                    index += 2
                    didTerminate = true
                    break
                }
                payload.append(scalar)
                index += 1
            }

            if didTerminate,
               let directory = TerminalCurrentDirectoryNormalizer.normalize(String(payload))
            {
                directories.append(directory)
            }
        }
        return directories
    }
}
