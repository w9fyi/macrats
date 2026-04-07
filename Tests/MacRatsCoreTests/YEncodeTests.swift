import Foundation
import Testing
@testable import MacRatsCore

/// Golden vectors and roundtrip tests for yEncode. The exact byte sequences
/// were captured from the upstream Python `d_rats/yencode.py` reference.
struct YEncodeTests {

    @Test("Plain ASCII passes through unchanged")
    func plainASCII() {
        let input = Data("hello".utf8)
        let encoded = YEncode.encode(input)
        #expect(encoded == input)
    }

    @Test("Empty buffer encodes to empty buffer")
    func emptyBuffer() {
        let encoded = YEncode.encode(Data())
        #expect(encoded.isEmpty)
    }

    @Test("DEFAULT_BANNED bytes encode exactly as Python")
    func defaultBannedBytes() {
        // Python's DEFAULT_BANNED = b"\x11\x13\x1A\x00\x84\xE7\xFD\xFE\xFF\xC0\xDB"
        // (11 bytes, no '=' — Python adds '=' inside yencode_buffer).
        let banned = Data([0x11, 0x13, 0x1A, 0x00, 0x84, 0xE7, 0xFD, 0xFE, 0xFF, 0xC0, 0xDB])
        let encoded = YEncode.encode(banned)
        // From Python: hex 3d513d533d5a3d403dc43d273d3d3d3e3d3f3d003d1b
        let expected = Data([
            0x3D, 0x51, // = Q  ← 0x11 + 0x40
            0x3D, 0x53, // = S  ← 0x13 + 0x40
            0x3D, 0x5A, // = Z  ← 0x1A + 0x40
            0x3D, 0x40, // = @  ← 0x00 + 0x40
            0x3D, 0xC4, //      ← 0x84 + 0x40
            0x3D, 0x27, //      ← 0xE7 + 0x40 (mod 256)
            0x3D, 0x3D, //      ← 0xFD + 0x40 (mod 256) — note this is the literal escape byte produced as a payload
            0x3D, 0x3E, //      ← 0xFE + 0x40 (mod 256)
            0x3D, 0x3F, //      ← 0xFF + 0x40 (mod 256)
            0x3D, 0x00, //      ← 0xC0 + 0x40 (mod 256)
            0x3D, 0x1B  //      ← 0xDB + 0x40 (mod 256)
        ])
        #expect(encoded == expected)
    }

    @Test("Equals sign is always escaped")
    func equalsSignEscaped() {
        let input = Data([0x3D]) // just '='
        let encoded = YEncode.encode(input)
        // = -> = followed by (0x3D + 0x40) % 256 = 0x7D = '}'
        #expect(encoded == Data([0x3D, 0x7D]))
    }

    @Test("All 0..255 bytes roundtrip cleanly")
    func fullByteRangeRoundtrip() throws {
        let input = Data((0..<256).map { UInt8($0) })
        let encoded = YEncode.encode(input)
        let decoded = try YEncode.decode(encoded)
        #expect(decoded == input)
    }

    @Test("Banned-set roundtrip cleanly")
    func bannedSetRoundtrip() throws {
        let input = Data([0x11, 0x13, 0x1A, 0x00, 0x84, 0xE7, 0xFD, 0xFE, 0xFF, 0xC0, 0xDB, 0x3D])
        let encoded = YEncode.encode(input)
        let decoded = try YEncode.decode(encoded)
        #expect(decoded == input)
    }

    @Test("Truncated escape throws")
    func truncatedEscape() {
        let bad = Data([0x3D]) // dangling '=' with nothing after
        #expect(throws: YEncode.DecodeError.self) {
            try YEncode.decode(bad)
        }
    }

    @Test("12-byte banned-plus-equals matches Python golden hex exactly")
    func twelveByteGolden() {
        // Python input:  \x00\x11\x13\x1A\x84\xE7\xFD\xFE\xFF\xC0\xDB=
        // Python output: 3d403d513d533d5a3dc43d273d3d3d3e3d3f3d003d1b3d7d
        let input = Data([0x00, 0x11, 0x13, 0x1A, 0x84, 0xE7, 0xFD, 0xFE, 0xFF, 0xC0, 0xDB, 0x3D])
        let encoded = YEncode.encode(input)
        let expected = Data([
            0x3D, 0x40,
            0x3D, 0x51,
            0x3D, 0x53,
            0x3D, 0x5A,
            0x3D, 0xC4,
            0x3D, 0x27,
            0x3D, 0x3D,
            0x3D, 0x3E,
            0x3D, 0x3F,
            0x3D, 0x00,
            0x3D, 0x1B,
            0x3D, 0x7D
        ])
        #expect(encoded == expected)
    }
}
