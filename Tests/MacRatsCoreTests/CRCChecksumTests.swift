import Foundation
import Testing
@testable import MacRatsCore

/// Golden vectors captured from the upstream Python `d_rats/crc_checksum.py`
/// reference. These must match exactly, byte for byte, or the protocol layer
/// is wrong and nothing else will interoperate.
struct CRCChecksumTests {

    @Test("Empty input gives 0x0000")
    func emptyInput() {
        #expect(DRatsCRC.calcChecksum(Data()) == 0x0000)
    }

    @Test("Single byte 'a' matches Python reference")
    func singleByte() {
        #expect(DRatsCRC.calcChecksum(Data("a".utf8)) == 0x7C87)
    }

    @Test("'abc' matches Python reference")
    func threeBytes() {
        #expect(DRatsCRC.calcChecksum(Data("abc".utf8)) == 0x9DD6)
    }

    @Test("'123456789' matches Python reference")
    func standardCheckString() {
        // Note: this is NOT the canonical CRC-16/CCITT-FALSE check value
        // (0x29B1) — D-Rats uses a non-standard augmented variant. The value
        // here is what the Python reference produces and is what we must match.
        #expect(DRatsCRC.calcChecksum(Data("123456789".utf8)) == 0x31C3)
    }

    @Test("'The quick brown fox' matches Python reference")
    func sentence() {
        #expect(DRatsCRC.calcChecksum(Data("The quick brown fox".utf8)) == 0xADDD)
    }

    @Test("Six byte counting sequence matches")
    func smallBinary() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        #expect(DRatsCRC.calcChecksum(data) == 0x8208)
    }

    @Test("Full 0..255 byte sequence matches")
    func allBytes() {
        let data = Data((0..<256).map { UInt8($0) })
        #expect(DRatsCRC.calcChecksum(data) == 0x7E55)
    }
}
