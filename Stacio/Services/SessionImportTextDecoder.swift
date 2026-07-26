import CoreFoundation
import Foundation

enum SessionImportTextDecoder {
    static func decode(_ data: Data) throws -> String {
        guard data.isEmpty == false else { return "" }

        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]),
           let text = String(data: data.dropFirst(4), encoding: .utf32LittleEndian) {
            return text
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]),
           let text = String(data: data.dropFirst(4), encoding: .utf32BigEndian) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return text
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return text
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        if let text = String(data: data, encoding: gb18030) {
            return text
        }
        if let text = String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}
