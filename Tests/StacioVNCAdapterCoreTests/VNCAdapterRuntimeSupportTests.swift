import XCTest
@testable import StacioVNCAdapterCore

final class VNCAdapterRuntimeSupportTests: XCTestCase {
    func testEncodingPreferencesPrioritizeCompressedCodecsAndAdvertiseJPEGQuality() {
        XCTAssertEqual(
            VNCEncodingNegotiation.encodings(forQuality: 7),
            [
                7, 16, 6, 5, 0,
                -26,
                -223, -224, -239, -232, -308,
                -1_063_131_698,
                -312,
            ]
        )
        XCTAssertEqual(VNCEncodingNegotiation.encodings(forQuality: 1)[5], -32)
        XCTAssertEqual(VNCEncodingNegotiation.encodings(forQuality: 10)[5], -23)
    }

    func testZRLEDecodesRawAndSolidTilesInWireOrder() throws {
        var encoded: [UInt8] = [0]
        for index in 0..<64 {
            encoded += [UInt8(index), 0x20, 0x30]
        }
        encoded += [1, 0xAA, 0xBB, 0xCC]

        let pixels = try VNCZRLETileDecoder.decode(
            data: encoded,
            width: 65,
            height: 1
        )

        XCTAssertEqual(Array(pixels[0..<4]), [0x00, 0x20, 0x30, 0xFF])
        XCTAssertEqual(Array(pixels[(63 * 4)..<(64 * 4)]), [0x3F, 0x20, 0x30, 0xFF])
        XCTAssertEqual(Array(pixels[(64 * 4)..<(65 * 4)]), [0xAA, 0xBB, 0xCC, 0xFF])
    }

    func testZRLEDecodesPackedPaletteWithPerRowPadding() throws {
        let encoded: [UInt8] = [
            2,
            0x00, 0x00, 0xFF,
            0x00, 0xFF, 0x00,
            0b0100_0000,
            0b1010_0000,
        ]

        let pixels = try VNCZRLETileDecoder.decode(
            data: encoded,
            width: 3,
            height: 2
        )

        XCTAssertEqual(
            pixels,
            [
                0x00, 0x00, 0xFF, 0xFF,
                0x00, 0xFF, 0x00, 0xFF,
                0x00, 0x00, 0xFF, 0xFF,
                0x00, 0xFF, 0x00, 0xFF,
                0x00, 0x00, 0xFF, 0xFF,
                0x00, 0xFF, 0x00, 0xFF,
            ]
        )
    }

    func testZRLEDecodesPlainAndPaletteRLE() throws {
        let plain = try VNCZRLETileDecoder.decode(
            data: [128, 0x11, 0x22, 0x33, 255, 0],
            width: 64,
            height: 4
        )
        XCTAssertEqual(plain.count, 64 * 4 * 4)
        XCTAssertEqual(Array(plain.prefix(4)), [0x11, 0x22, 0x33, 0xFF])
        XCTAssertEqual(Array(plain.suffix(4)), [0x11, 0x22, 0x33, 0xFF])

        let palette = try VNCZRLETileDecoder.decode(
            data: [
                130,
                0x00, 0x00, 0xFF,
                0x00, 0xFF, 0x00,
                0x80, 2,
                0x01,
            ],
            width: 4,
            height: 1
        )
        XCTAssertEqual(
            palette,
            [
                0x00, 0x00, 0xFF, 0xFF,
                0x00, 0x00, 0xFF, 0xFF,
                0x00, 0x00, 0xFF, 0xFF,
                0x00, 0xFF, 0x00, 0xFF,
            ]
        )
    }

    func testZRLERejectsUnusedSubencodingAndTrailingData() {
        XCTAssertThrowsError(
            try VNCZRLETileDecoder.decode(data: [129], width: 1, height: 1)
        )
        XCTAssertThrowsError(
            try VNCZRLETileDecoder.decode(
                data: [1, 0x00, 0x00, 0x00, 0xFF],
                width: 1,
                height: 1
            )
        )
    }

    func testTightCopyPaletteAndGradientFiltersProduceBGRA() throws {
        XCTAssertEqual(
            try VNCTightPixelDecoder.decode(
                data: [0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00],
                width: 2,
                height: 1,
                filter: .copy
            ),
            [
                0x00, 0x00, 0xFF, 0xFF,
                0x00, 0xFF, 0x00, 0xFF,
            ]
        )

        XCTAssertEqual(
            try VNCTightPixelDecoder.decode(
                data: [0b0100_0000],
                width: 3,
                height: 1,
                filter: .palette(colors: [
                    VNCRGBColor(red: 0xFF, green: 0x00, blue: 0x00),
                    VNCRGBColor(red: 0x00, green: 0xFF, blue: 0x00),
                ])
            ),
            [
                0x00, 0x00, 0xFF, 0xFF,
                0x00, 0xFF, 0x00, 0xFF,
                0x00, 0x00, 0xFF, 0xFF,
            ]
        )

        XCTAssertEqual(
            try VNCTightPixelDecoder.decode(
                data: [
                    10, 20, 30,
                    5, 5, 5,
                    2, 2, 2,
                    3, 3, 3,
                ],
                width: 2,
                height: 2,
                filter: .gradient
            ),
            [
                30, 20, 10, 0xFF,
                35, 25, 15, 0xFF,
                32, 22, 12, 0xFF,
                40, 30, 20, 0xFF,
            ]
        )
    }

    func testTightPaletteRejectsOutOfRangeIndex() {
        XCTAssertThrowsError(
            try VNCTightPixelDecoder.decode(
                data: [3],
                width: 1,
                height: 1,
                filter: .palette(colors: [
                    VNCRGBColor(red: 0, green: 0, blue: 0),
                    VNCRGBColor(red: 255, green: 255, blue: 255),
                    VNCRGBColor(red: 255, green: 0, blue: 0),
                ])
            )
        )
    }

    func testTightCompactLengthSupportsOneTwoAndThreeByteValues() throws {
        XCTAssertEqual(
            try VNCTightCompactLength.decodePrefix([0x7F]),
            VNCTightCompactLength.Value(length: 127, consumedByteCount: 1)
        )
        XCTAssertEqual(
            try VNCTightCompactLength.decodePrefix([0x90, 0x4E]),
            VNCTightCompactLength.Value(length: 10_000, consumedByteCount: 2)
        )
        XCTAssertEqual(
            try VNCTightCompactLength.decodePrefix([0x80, 0x80, 0x01]),
            VNCTightCompactLength.Value(length: 16_384, consumedByteCount: 3)
        )
        XCTAssertThrowsError(try VNCTightCompactLength.decodePrefix([0x80]))
    }

    func testTargetParserRemovesIPv6Brackets() {
        XCTAssertEqual(
            VNCConnectionTargetParser.parse("[2001:db8::10]:5901"),
            VNCConnectionTarget(host: "2001:db8::10", port: 5901)
        )
    }

    func testFenceMonitorUsesElapsedMonotonicTimeInsteadOfLoopCount() {
        var now: TimeInterval = 100
        let monitor = VNCFenceRTTMonitor(interval: 10, clock: { now })
        monitor.start { _, _ in }

        for _ in 0..<1_000 {
            XCTAssertNil(monitor.tick())
        }
        now = 109.999
        XCTAssertNil(monitor.tick())
        now = 110
        XCTAssertNotNil(monitor.tick())
    }

    func testFenceMonitorUsesUniquePayloadsAndIgnoresLateResponse() throws {
        var now: TimeInterval = 0
        var samples: [(milliseconds: Int, mode: String)] = []
        let monitor = VNCFenceRTTMonitor(interval: 10, clock: { now })
        monitor.start { samples.append(($0, $1)) }

        now = 10
        let first = try XCTUnwrap(monitor.tick())
        now = 20
        let second = try XCTUnwrap(monitor.tick())

        XCTAssertNotEqual(first.payload, second.payload)

        now = 20.1
        monitor.onFenceResponse(payload: first.payload)
        XCTAssertTrue(samples.isEmpty)

        now = 20.3
        monitor.onFenceResponse(payload: second.payload)
        XCTAssertEqual(samples.map(\.milliseconds), [300])
        XCTAssertEqual(samples.map(\.mode), ["poor"])
    }

    func testFenceRTTModeIncludesThreeHundredMillisecondsInPoorRange() {
        XCTAssertEqual(VNCFenceRTTMonitor.networkMode(forRTTMilliseconds: 99), "normal")
        XCTAssertEqual(VNCFenceRTTMonitor.networkMode(forRTTMilliseconds: 100), "poor")
        XCTAssertEqual(VNCFenceRTTMonitor.networkMode(forRTTMilliseconds: 300), "poor")
        XCTAssertEqual(VNCFenceRTTMonitor.networkMode(forRTTMilliseconds: 301), "very_poor")
    }

    func testAdaptiveQualityRestoresUserTargetAfterNetworkRecovery() {
        var state = VNCAdaptiveQualityState(desiredQuality: 7, configuredMaxFPS: 30)

        XCTAssertTrue(state.applyNetworkMode("very_poor"))
        XCTAssertEqual(state.effectiveQuality, 2)
        XCTAssertEqual(state.effectiveMaxFPS, 8)

        XCTAssertFalse(state.setDesiredQuality(9))
        XCTAssertEqual(state.desiredQuality, 9)
        XCTAssertEqual(state.effectiveQuality, 2)

        XCTAssertTrue(state.applyNetworkMode("normal"))
        XCTAssertEqual(state.effectiveQuality, 9)
        XCTAssertEqual(state.effectiveMaxFPS, 30)
    }

    func testAdaptiveQualityNeverRaisesALowUserTarget() {
        var state = VNCAdaptiveQualityState(desiredQuality: 3, configuredMaxFPS: 24)

        XCTAssertFalse(state.applyNetworkMode("poor"))
        XCTAssertEqual(state.effectiveQuality, 3)
        XCTAssertEqual(state.effectiveMaxFPS, 15)
        XCTAssertFalse(state.applyNetworkMode("normal"))
        XCTAssertEqual(state.effectiveQuality, 3)
        XCTAssertEqual(state.effectiveMaxFPS, 24)
    }

    func testExtendedClipboardCapabilitiesAndUTF8ProvideRoundTrip() throws {
        let caps = VNCExtendedClipboardCodec.capabilitiesPayload(maximumTextBytes: 1_048_576)
        let decodedCaps = try VNCExtendedClipboardCodec.decode(
            payload: caps,
            maximumTextBytes: 1_048_576
        )
        XCTAssertEqual(decodedCaps.action, .capabilities)
        XCTAssertEqual(decodedCaps.maximumTextBytes, 1_048_576)
        XCTAssertNotEqual(decodedCaps.flags & VNCExtendedClipboardCodec.provideFlag, 0)

        let provide = try VNCExtendedClipboardCodec.providePayload(
            text: "Mac → 远端 🖥️",
            maximumTextBytes: 1_048_576
        )
        let decodedProvide = try VNCExtendedClipboardCodec.decode(
            payload: provide,
            maximumTextBytes: 1_048_576
        )
        XCTAssertEqual(decodedProvide.action, .provide)
        XCTAssertEqual(decodedProvide.text, "Mac → 远端 🖥️")

        let wire = try VNCExtendedClipboardCodec.clientCutTextMessage(
            extendedPayload: provide
        )
        XCTAssertEqual(Array(wire.prefix(4)), [6, 0, 0, 0])
        let encodedLength = UInt32(wire[4]) << 24
            | UInt32(wire[5]) << 16
            | UInt32(wire[6]) << 8
            | UInt32(wire[7])
        XCTAssertEqual(Int((~encodedLength) &+ 1), provide.count)
    }

    func testExtendedClipboardDecodesTigerVNCSyncFlushStream() throws {
        let payload: [UInt8] = [
            0x10, 0x00, 0x00, 0x01,
            0x78, 0x9C, 0x62, 0x60, 0x60, 0x60, 0xCB, 0x48,
            0xCD, 0xC9, 0xC9, 0x67, 0x00, 0x00, 0x00, 0x00,
            0xFF, 0xFF,
        ]
        let decoded = try VNCExtendedClipboardCodec.decode(
            payload: payload,
            maximumTextBytes: 1_048_576
        )
        XCTAssertEqual(decoded.action, .provide)
        XCTAssertEqual(decoded.text, "hello")
    }

    func testStandardClipboardUsesLatin1InsteadOfGuessingUTF8() {
        XCTAssertEqual(VNCExtendedClipboardCodec.latin1Bytes(for: "café"), [0x63, 0x61, 0x66, 0xE9])
        XCTAssertEqual(VNCExtendedClipboardCodec.latin1String(from: [0xC3, 0xA9]), "Ã©")
    }

    func testFrameLoopPollTimingWakesAtNextFrameDeadline() {
        XCTAssertEqual(
            VNCFrameLoopTiming.pollTimeoutMicroseconds(
                framebufferRequestOutstanding: false,
                lastFramebufferRequestTime: 10,
                now: 10.010,
                maxFPS: 30
            ),
            23_333
        )
    }

    func testFrameLoopPollTimingUsesIdleCapWhileRequestIsOutstanding() {
        XCTAssertEqual(
            VNCFrameLoopTiming.pollTimeoutMicroseconds(
                framebufferRequestOutstanding: true,
                lastFramebufferRequestTime: 10,
                now: 10.010,
                maxFPS: 30
            ),
            50_000
        )
    }

    func testFrameLoopPollTimingDoesNotSleepPastOverdueFrame() {
        XCTAssertEqual(
            VNCFrameLoopTiming.pollTimeoutMicroseconds(
                framebufferRequestOutstanding: false,
                lastFramebufferRequestTime: 10,
                now: 10.040,
                maxFPS: 30
            ),
            0
        )
    }
}
