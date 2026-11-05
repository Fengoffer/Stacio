import Foundation

package enum VNCFramebufferDecodingError: Error, Equatable, LocalizedError {
    case invalidDimensions(width: Int, height: Int)
    case truncatedData
    case trailingData(byteCount: Int)
    case invalidSubencoding(UInt8)
    case invalidPaletteSize(Int)
    case invalidPaletteIndex(Int)
    case invalidRunLength(Int)

    package var errorDescription: String? {
        switch self {
        case .invalidDimensions(let width, let height):
            return "invalid rectangle dimensions: \(width)x\(height)"
        case .truncatedData:
            return "encoded rectangle data is truncated"
        case .trailingData(let byteCount):
            return "encoded rectangle has \(byteCount) trailing bytes"
        case .invalidSubencoding(let value):
            return "unsupported rectangle subencoding: \(value)"
        case .invalidPaletteSize(let count):
            return "invalid palette size: \(count)"
        case .invalidPaletteIndex(let index):
            return "palette index is out of range: \(index)"
        case .invalidRunLength(let length):
            return "run length exceeds the tile: \(length)"
        }
    }
}

package enum VNCEncodingNegotiation {
    package static func encodings(forQuality quality: Int) -> [Int32] {
        let quality = max(1, min(10, quality))
        let jpegQualityPseudoEncoding = Int32(-32 + quality - 1)
        return [
            7,   // Tight
            16,  // ZRLE
            6,   // Zlib
            5,   // Hextile
            0,   // Raw fallback
            jpegQualityPseudoEncoding,
            -223, // DesktopSize
            -224, // LastRect
            -239, // Cursor
            -232, // CursorPosition
            -308, // ExtendedDesktopSize
            VNCExtendedClipboardCodec.pseudoEncoding,
            -312, // Fence
        ]
    }
}

package struct VNCRGBColor: Equatable {
    package let red: UInt8
    package let green: UInt8
    package let blue: UInt8

    package init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

package enum VNCTightCompactLength {
    package struct Value: Equatable {
        package let length: Int
        package let consumedByteCount: Int

        package init(length: Int, consumedByteCount: Int) {
            self.length = length
            self.consumedByteCount = consumedByteCount
        }
    }

    package static func decodePrefix(_ bytes: [UInt8]) throws -> Value {
        guard let first = bytes.first else {
            throw VNCFramebufferDecodingError.truncatedData
        }

        var length = Int(first & 0x7F)
        guard first & 0x80 != 0 else {
            return Value(length: length, consumedByteCount: 1)
        }
        guard bytes.count >= 2 else {
            throw VNCFramebufferDecodingError.truncatedData
        }

        let second = bytes[1]
        length |= Int(second & 0x7F) << 7
        guard second & 0x80 != 0 else {
            return Value(length: length, consumedByteCount: 2)
        }
        guard bytes.count >= 3 else {
            throw VNCFramebufferDecodingError.truncatedData
        }

        length |= Int(bytes[2]) << 14
        return Value(length: length, consumedByteCount: 3)
    }
}

package enum VNCTightPixelFilter: Equatable {
    case copy
    case palette(colors: [VNCRGBColor])
    case gradient
}

package enum VNCTightPixelDecoder {
    package static func decode(
        data: [UInt8],
        width: Int,
        height: Int,
        filter: VNCTightPixelFilter
    ) throws -> [UInt8] {
        let pixelCount = try validatedPixelCount(width: width, height: height)
        var output = [UInt8](repeating: 0, count: pixelCount * 4)

        switch filter {
        case .copy:
            guard data.count == pixelCount * 3 else {
                throw VNCFramebufferDecodingError.truncatedData
            }
            for index in 0..<pixelCount {
                write(
                    VNCRGBColor(
                        red: data[index * 3],
                        green: data[index * 3 + 1],
                        blue: data[index * 3 + 2]
                    ),
                    to: &output,
                    pixelIndex: index
                )
            }

        case .palette(let colors):
            guard (2...256).contains(colors.count) else {
                throw VNCFramebufferDecodingError.invalidPaletteSize(colors.count)
            }
            if colors.count == 2 {
                let bytesPerRow = (width + 7) / 8
                guard data.count == bytesPerRow * height else {
                    throw VNCFramebufferDecodingError.truncatedData
                }
                for row in 0..<height {
                    for column in 0..<width {
                        let byte = data[row * bytesPerRow + column / 8]
                        let index = Int((byte >> UInt8(7 - column % 8)) & 0x01)
                        write(colors[index], to: &output, pixelIndex: row * width + column)
                    }
                }
            } else {
                guard data.count == pixelCount else {
                    throw VNCFramebufferDecodingError.truncatedData
                }
                for pixelIndex in 0..<pixelCount {
                    let paletteIndex = Int(data[pixelIndex])
                    guard colors.indices.contains(paletteIndex) else {
                        throw VNCFramebufferDecodingError.invalidPaletteIndex(paletteIndex)
                    }
                    write(colors[paletteIndex], to: &output, pixelIndex: pixelIndex)
                }
            }

        case .gradient:
            guard data.count == pixelCount * 3 else {
                throw VNCFramebufferDecodingError.truncatedData
            }
            var previousRow = [VNCRGBColor](
                repeating: VNCRGBColor(red: 0, green: 0, blue: 0),
                count: width
            )
            var currentRow = previousRow
            for row in 0..<height {
                var left = VNCRGBColor(red: 0, green: 0, blue: 0)
                for column in 0..<width {
                    let upper = previousRow[column]
                    let upperLeft = column == 0
                        ? VNCRGBColor(red: 0, green: 0, blue: 0)
                        : previousRow[column - 1]
                    let sourceOffset = (row * width + column) * 3
                    let decoded = VNCRGBColor(
                        red: reconstruct(
                            difference: data[sourceOffset],
                            left: left.red,
                            upper: upper.red,
                            upperLeft: upperLeft.red
                        ),
                        green: reconstruct(
                            difference: data[sourceOffset + 1],
                            left: left.green,
                            upper: upper.green,
                            upperLeft: upperLeft.green
                        ),
                        blue: reconstruct(
                            difference: data[sourceOffset + 2],
                            left: left.blue,
                            upper: upper.blue,
                            upperLeft: upperLeft.blue
                        )
                    )
                    currentRow[column] = decoded
                    left = decoded
                    write(decoded, to: &output, pixelIndex: row * width + column)
                }
                swap(&previousRow, &currentRow)
            }
        }

        return output
    }

    private static func reconstruct(
        difference: UInt8,
        left: UInt8,
        upper: UInt8,
        upperLeft: UInt8
    ) -> UInt8 {
        let prediction = max(
            0,
            min(255, Int(left) + Int(upper) - Int(upperLeft))
        )
        return UInt8(truncatingIfNeeded: prediction + Int(difference))
    }
}

package enum VNCZRLETileDecoder {
    package static func decode(data: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        let pixelCount = try validatedPixelCount(width: width, height: height)
        var output = [UInt8](repeating: 0, count: pixelCount * 4)
        var cursor = VNCByteCursor(data: data)

        var tileY = 0
        while tileY < height {
            let tileHeight = min(64, height - tileY)
            var tileX = 0
            while tileX < width {
                let tileWidth = min(64, width - tileX)
                let subencoding = try cursor.readByte()
                try decodeTile(
                    subencoding: subencoding,
                    cursor: &cursor,
                    output: &output,
                    outputWidth: width,
                    tileX: tileX,
                    tileY: tileY,
                    tileWidth: tileWidth,
                    tileHeight: tileHeight
                )
                tileX += 64
            }
            tileY += 64
        }

        guard cursor.remainingByteCount == 0 else {
            throw VNCFramebufferDecodingError.trailingData(
                byteCount: cursor.remainingByteCount
            )
        }
        return output
    }

    private static func decodeTile(
        subencoding: UInt8,
        cursor: inout VNCByteCursor,
        output: inout [UInt8],
        outputWidth: Int,
        tileX: Int,
        tileY: Int,
        tileWidth: Int,
        tileHeight: Int
    ) throws {
        let tilePixelCount = tileWidth * tileHeight
        switch subencoding {
        case 0:
            for tilePixelIndex in 0..<tilePixelCount {
                let color = try cursor.readZRLEColor()
                writeTilePixel(
                    color,
                    tilePixelIndex: tilePixelIndex,
                    output: &output,
                    outputWidth: outputWidth,
                    tileX: tileX,
                    tileY: tileY,
                    tileWidth: tileWidth
                )
            }

        case 1:
            let color = try cursor.readZRLEColor()
            for tilePixelIndex in 0..<tilePixelCount {
                writeTilePixel(
                    color,
                    tilePixelIndex: tilePixelIndex,
                    output: &output,
                    outputWidth: outputWidth,
                    tileX: tileX,
                    tileY: tileY,
                    tileWidth: tileWidth
                )
            }

        case 2...16:
            let palette = try cursor.readZRLEPalette(count: Int(subencoding))
            let bitsPerIndex: Int
            switch palette.count {
            case 2: bitsPerIndex = 1
            case 3...4: bitsPerIndex = 2
            default: bitsPerIndex = 4
            }
            let rowByteCount = (tileWidth * bitsPerIndex + 7) / 8
            let mask = UInt8((1 << bitsPerIndex) - 1)
            for row in 0..<tileHeight {
                let packed = try cursor.read(rowByteCount)
                for column in 0..<tileWidth {
                    let bitOffset = column * bitsPerIndex
                    let shift = 8 - bitsPerIndex - (bitOffset % 8)
                    let packedIndex = packed.index(
                        packed.startIndex,
                        offsetBy: bitOffset / 8
                    )
                    let paletteIndex = Int(
                        (packed[packedIndex] >> UInt8(shift)) & mask
                    )
                    guard palette.indices.contains(paletteIndex) else {
                        throw VNCFramebufferDecodingError.invalidPaletteIndex(paletteIndex)
                    }
                    let tilePixelIndex = row * tileWidth + column
                    writeTilePixel(
                        palette[paletteIndex],
                        tilePixelIndex: tilePixelIndex,
                        output: &output,
                        outputWidth: outputWidth,
                        tileX: tileX,
                        tileY: tileY,
                        tileWidth: tileWidth
                    )
                }
            }

        case 17...127, 129:
            throw VNCFramebufferDecodingError.invalidSubencoding(subencoding)

        case 128:
            var tilePixelIndex = 0
            while tilePixelIndex < tilePixelCount {
                let color = try cursor.readZRLEColor()
                let runLength = try cursor.readRunLength()
                guard runLength <= tilePixelCount - tilePixelIndex else {
                    throw VNCFramebufferDecodingError.invalidRunLength(runLength)
                }
                for _ in 0..<runLength {
                    writeTilePixel(
                        color,
                        tilePixelIndex: tilePixelIndex,
                        output: &output,
                        outputWidth: outputWidth,
                        tileX: tileX,
                        tileY: tileY,
                        tileWidth: tileWidth
                    )
                    tilePixelIndex += 1
                }
            }

        case 130...255:
            let palette = try cursor.readZRLEPalette(count: Int(subencoding) - 128)
            var tilePixelIndex = 0
            while tilePixelIndex < tilePixelCount {
                let encodedIndex = try cursor.readByte()
                let paletteIndex = Int(encodedIndex & 0x7F)
                guard palette.indices.contains(paletteIndex) else {
                    throw VNCFramebufferDecodingError.invalidPaletteIndex(paletteIndex)
                }
                let runLength = encodedIndex & 0x80 == 0
                    ? 1
                    : try cursor.readRunLength()
                guard runLength <= tilePixelCount - tilePixelIndex else {
                    throw VNCFramebufferDecodingError.invalidRunLength(runLength)
                }
                for _ in 0..<runLength {
                    writeTilePixel(
                        palette[paletteIndex],
                        tilePixelIndex: tilePixelIndex,
                        output: &output,
                        outputWidth: outputWidth,
                        tileX: tileX,
                        tileY: tileY,
                        tileWidth: tileWidth
                    )
                    tilePixelIndex += 1
                }
            }

        default:
            throw VNCFramebufferDecodingError.invalidSubencoding(subencoding)
        }
    }

    private static func writeTilePixel(
        _ color: VNCRGBColor,
        tilePixelIndex: Int,
        output: inout [UInt8],
        outputWidth: Int,
        tileX: Int,
        tileY: Int,
        tileWidth: Int
    ) {
        let row = tilePixelIndex / tileWidth
        let column = tilePixelIndex % tileWidth
        let outputPixelIndex = (tileY + row) * outputWidth + tileX + column
        write(color, to: &output, pixelIndex: outputPixelIndex)
    }
}

private struct VNCByteCursor {
    let data: [UInt8]
    var offset = 0

    var remainingByteCount: Int {
        data.count - offset
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw VNCFramebufferDecodingError.truncatedData
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func read(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remainingByteCount else {
            throw VNCFramebufferDecodingError.truncatedData
        }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    mutating func readZRLEColor() throws -> VNCRGBColor {
        let bytes = try read(3)
        let start = bytes.startIndex
        return VNCRGBColor(
            red: bytes[start + 2],
            green: bytes[start + 1],
            blue: bytes[start]
        )
    }

    mutating func readZRLEPalette(count: Int) throws -> [VNCRGBColor] {
        guard (1...127).contains(count) else {
            throw VNCFramebufferDecodingError.invalidPaletteSize(count)
        }
        return try (0..<count).map { _ in try readZRLEColor() }
    }

    mutating func readRunLength() throws -> Int {
        var length = 1
        while true {
            let value = Int(try readByte())
            let (nextLength, overflow) = length.addingReportingOverflow(value)
            guard overflow == false else {
                throw VNCFramebufferDecodingError.invalidRunLength(Int.max)
            }
            length = nextLength
            if value != 255 {
                return length
            }
        }
    }
}

private func validatedPixelCount(width: Int, height: Int) throws -> Int {
    guard width > 0, height > 0 else {
        throw VNCFramebufferDecodingError.invalidDimensions(width: width, height: height)
    }
    let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
    let (_, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
    guard pixelOverflow == false, byteOverflow == false else {
        throw VNCFramebufferDecodingError.invalidDimensions(width: width, height: height)
    }
    return pixelCount
}

private func write(_ color: VNCRGBColor, to output: inout [UInt8], pixelIndex: Int) {
    let offset = pixelIndex * 4
    output[offset] = color.blue
    output[offset + 1] = color.green
    output[offset + 2] = color.red
    output[offset + 3] = 0xFF
}
