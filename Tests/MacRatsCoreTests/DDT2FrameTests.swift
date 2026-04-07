import Foundation
import Testing
@testable import MacRatsCore

/// DDT2 frame tests against golden vectors captured from upstream Python.
struct DDT2FrameTests {

    // MARK: - Uncompressed frame golden vector

    /// Golden hex from upstream Python:
    /// `2200030201b557000e464f4f7e7e7e7e7e4241527e7e7e7e7e5468697320697320612074657374`
    /// Built with: seq=3, session=2, type=1, sStation="FOO", dStation="BAR",
    /// data=b"This is a test", compress=False.
    @Test("Uncompressed frame matches Python golden bytes exactly")
    func uncompressedGolden() {
        let frame = DDT2Frame(seq: 3,
                              session: 2,
                              type: 1,
                              sStation: "FOO",
                              dStation: "BAR",
                              data: Data("This is a test".utf8),
                              compress: false)
        let packed = frame.pack()
        let expectedHex = "2200030201b557000e464f4f7e7e7e7e7e4241527e7e7e7e7e5468697320697320612074657374"
        #expect(packed.hexString == expectedHex)
    }

    @Test("Uncompressed frame round-trips through unpack")
    func uncompressedRoundTrip() throws {
        let original = DDT2Frame(seq: 3,
                                 session: 2,
                                 type: 1,
                                 sStation: "FOO",
                                 dStation: "BAR",
                                 data: Data("This is a test".utf8),
                                 compress: false)
        let parsed = try DDT2Frame.unpack(original.pack())
        #expect(parsed.seq == original.seq)
        #expect(parsed.session == original.session)
        #expect(parsed.type == original.type)
        #expect(parsed.sStation == original.sStation)
        #expect(parsed.dStation == original.dStation)
        #expect(parsed.data == original.data)
        #expect(parsed.compress == original.compress)
    }

    // MARK: - Compressed frame round-trip

    /// We can't byte-match the compressed golden vector because the system
    /// `Compression` framework's deflate output is not bit-identical to
    /// Python's `zlib.compress(data, 9)` (it picks different match strategies).
    /// What MUST be true is that we can decode our own compressed output AND
    /// we can decode upstream Python's compressed output. The second check is
    /// the actual interoperability requirement.
    @Test("Compressed frame round-trips through unpack")
    func compressedRoundTrip() throws {
        let original = DDT2Frame(seq: 3,
                                 session: 2,
                                 type: 1,
                                 sStation: "FOO",
                                 dStation: "BAR",
                                 data: Data("This is a test".utf8),
                                 compress: true)
        let parsed = try DDT2Frame.unpack(original.pack())
        #expect(parsed.seq == 3)
        #expect(parsed.session == 2)
        #expect(parsed.type == 1)
        #expect(parsed.sStation == "FOO")
        #expect(parsed.dStation == "BAR")
        #expect(parsed.data == Data("This is a test".utf8))
        #expect(parsed.compress == true)
    }

    @Test("Compressed frame produced by upstream Python decodes correctly")
    func compressedFromPython() throws {
        // Captured from Python:
        // dd00030201c3ab0014464f4f7e7e7e7e7e4241527e7e7e7e7e78da0bc9c82c5600a2448592d4e21200247304f6
        let hex = "dd00030201c3ab0014464f4f7e7e7e7e7e4241527e7e7e7e7e78da0bc9c82c5600a2448592d4e21200247304f6"
        let bytes = Data(hex: hex)!
        let parsed = try DDT2Frame.unpack(bytes)
        #expect(parsed.seq == 3)
        #expect(parsed.session == 2)
        #expect(parsed.type == 1)
        #expect(parsed.sStation == "FOO")
        #expect(parsed.dStation == "BAR")
        #expect(parsed.data == Data("This is a test".utf8))
        #expect(parsed.compress == true)
    }

    // MARK: - Encoded frame envelope

    @Test("Uncompressed encoded frame round-trips through SOB/EOB envelope")
    func encodedRoundTripUncompressed() throws {
        let original = DDT2Frame(seq: 3,
                                 session: 2,
                                 type: 1,
                                 sStation: "FOO",
                                 dStation: "BAR",
                                 data: Data("This is a test".utf8),
                                 compress: false)
        let wire = DDT2EncodedFrame.pack(original)
        // Should start with [SOB] and end with [EOB]
        #expect(wire.starts(with: DDT2Frame.envelopeStart))
        #expect(wire.suffix(5) == DDT2Frame.envelopeEnd)

        let parsed = try DDT2EncodedFrame.unpack(wire)
        #expect(parsed.seq == original.seq)
        #expect(parsed.data == original.data)
        #expect(parsed.sStation == "FOO")
        #expect(parsed.dStation == "BAR")
    }

    @Test("Compressed encoded frame round-trips through SOB/EOB envelope")
    func encodedRoundTripCompressed() throws {
        let original = DDT2Frame(seq: 7,
                                 session: 1,
                                 type: 5,
                                 sStation: "AI5OS",
                                 dStation: "W9FYI",
                                 data: Data("Hello from MacRats over D-STAR!".utf8),
                                 compress: true)
        let wire = DDT2EncodedFrame.pack(original)
        let parsed = try DDT2EncodedFrame.unpack(wire)
        #expect(parsed.seq == 7)
        #expect(parsed.session == 1)
        #expect(parsed.type == 5)
        #expect(parsed.sStation == "AI5OS")
        #expect(parsed.dStation == "W9FYI")
        #expect(parsed.data == Data("Hello from MacRats over D-STAR!".utf8))
    }

    @Test("Encoded frame from upstream Python decodes correctly")
    func encodedFromPython() throws {
        // Captured from Python DDT2EncodedFrame for the same FOO->BAR test:
        // 5b534f425ddd3d40030201c3ab3d4014464f4f7e7e7e7e7e4241527e7e7e7e7e78da0bc9c82c563d40a2448592d4e2123d40247304f65b454f425d
        let hex = "5b534f425ddd3d40030201c3ab3d4014464f4f7e7e7e7e7e4241527e7e7e7e7e78da0bc9c82c563d40a2448592d4e2123d40247304f65b454f425d"
        let bytes = Data(hex: hex)!
        let parsed = try DDT2EncodedFrame.unpack(bytes)
        #expect(parsed.seq == 3)
        #expect(parsed.session == 2)
        #expect(parsed.type == 1)
        #expect(parsed.sStation == "FOO")
        #expect(parsed.dStation == "BAR")
        #expect(parsed.data == Data("This is a test".utf8))
        #expect(parsed.compress == true)
    }

    @Test("Bad magic byte is rejected")
    func badMagic() {
        var bytes = [UInt8](repeating: 0, count: 25)
        bytes[0] = 0xAB
        #expect(throws: DDT2Frame.FrameError.self) {
            try DDT2Frame.unpack(Data(bytes))
        }
    }

    @Test("Truncated frame is rejected")
    func truncated() {
        #expect(throws: DDT2Frame.FrameError.self) {
            try DDT2Frame.unpack(Data([0xDD, 0x00]))
        }
    }

    @Test("Encoded frame missing envelope is rejected")
    func missingEnvelope() {
        #expect(throws: DDT2Frame.FrameError.self) {
            try DDT2EncodedFrame.unpack(Data("not a frame".utf8))
        }
    }

    @Test("Long callsign is truncated to 8 bytes")
    func longCallsignTruncated() throws {
        // Upstream behavior: ljust(8, '~') leaves a >8-char string at its
        // original length, so the format would actually fail to pack. We
        // truncate cleanly. Document the behavior with a test so it can't
        // regress silently.
        let frame = DDT2Frame(seq: 0, session: 0, type: 0,
                              sStation: "AI5OSAI5OS",
                              dStation: "BAR",
                              data: Data(),
                              compress: false)
        let packed = frame.pack()
        let parsed = try DDT2Frame.unpack(packed)
        #expect(parsed.sStation == "AI5OSAI5") // first 8 bytes
    }
}

// MARK: - Test helpers

extension Data {
    init?(hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
