import Foundation
import Testing
@testable import MacRatsCore

/// Golden vectors for `DSTARCRC`, captured by running the reference
/// algorithm from the sibling `th-programmer` project against known inputs.
/// These must match byte-for-byte — the D-STAR header CRC is what the
/// radio and reflectors use to decide whether a header is valid.
struct DSTARCRCTests {

    @Test("Empty input inverts to 0x0000 (CRC starts at 0xFFFF, final XOR = ~0xFFFF)")
    func empty() {
        // 0xFFFF inverted = 0x0000. That's exactly what the Python/Swift
        // reference produces for empty input.
        #expect(DSTARCRC.compute(Data(), from: 0, count: 0) == 0x0000)
    }

    @Test("'A' (0x41) matches reference")
    func singleByteA() {
        #expect(DSTARCRC.compute([0x41]) == 0xA3F5)
    }

    @Test("'123456789' matches reference")
    func checkString() {
        #expect(DSTARCRC.compute(Array("123456789".utf8)) == 0x906E)
    }

    @Test("39 zero bytes matches reference")
    func thirtyNineZeros() {
        #expect(DSTARCRC.compute([UInt8](repeating: 0, count: 39)) == 0xAF90)
    }

    @Test("Realistic CQ D-STAR header from AI5OS matches reference")
    func realisticHeader() {
        // Flags (3) + RPT2 8sp + RPT1 8sp + YOUR "CQCQCQ  " + MY "AI5OS   " + suffix "    "
        // = 39 bytes. This is a complete D-STAR header ready for CRC.
        var header = [UInt8](repeating: 0, count: 39)
        // flags already zero
        for i in 3..<11 { header[i] = 0x20 }  // RPT2
        for i in 11..<19 { header[i] = 0x20 } // RPT1
        let your = Array("CQCQCQ  ".utf8)
        for (i, b) in your.enumerated() { header[19 + i] = b }
        let mine = Array("AI5OS   ".utf8)
        for (i, b) in mine.enumerated() { header[27 + i] = b }
        for i in 35..<39 { header[i] = 0x20 } // suffix

        #expect(DSTARCRC.compute(header) == 0x6893)
    }

    @Test("compute(from:count:) honors start offset")
    func startOffset() {
        // Build a buffer with junk bytes before and after the real header
        // and verify that computing from offset 5 over 39 bytes gives the
        // same result as computing over just those 39 bytes alone.
        let header = [UInt8](repeating: 0, count: 39)
        let padded = [UInt8](repeating: 0xFF, count: 5) + header + [UInt8](repeating: 0xAA, count: 3)
        #expect(DSTARCRC.compute(Data(padded), from: 5, count: 39) == 0xAF90)
    }
}
