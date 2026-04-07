import Foundation
import Testing
@testable import MacRatsCore

/// Tests for the MMDVM host ↔ modem serial protocol — both frame building
/// and the round-trip through `MMDVMParser`.
struct MMDVMProtocolTests {

    // MARK: - Frame builders

    @Test("buildGetVersion produces E0 03 00")
    func getVersion() {
        let frame = MMDVMProtocol.buildGetVersion()
        #expect(frame == Data([0xE0, 0x03, 0x00]))
    }

    @Test("buildGetStatus produces E0 03 01")
    func getStatus() {
        let frame = MMDVMProtocol.buildGetStatus()
        #expect(frame == Data([0xE0, 0x03, 0x01]))
    }

    @Test("buildSetMode defaults to D-STAR (0x01) and produces E0 04 03 01")
    func setMode() {
        let frame = MMDVMProtocol.buildSetMode()
        #expect(frame == Data([0xE0, 0x04, 0x03, 0x01]))
    }

    @Test("buildSetConfig produces a 26-byte frame with the expected header")
    func setConfig() {
        let frame = MMDVMProtocol.buildSetConfig()
        // 0xE0 + length(0x1A = 26) + command(0x02) + 23 payload bytes = 26 bytes.
        #expect(frame.count == 26)
        #expect(frame[0] == 0xE0)
        #expect(frame[1] == 0x1A)
        #expect(frame[2] == MMDVMProtocol.setConfig)
        // Verify the two key payload bytes that enable D-STAR mode.
        #expect(frame[3 + 1] == 0x01)  // modes: D-STAR enabled (bit 0)
        #expect(frame[3 + 2] == 0x08)  // TX delay: 80 ms
    }

    @Test("buildDStarData produces a 15-byte frame with correct AMBE + slow data")
    func dstarData() {
        let ambe = MMDVMProtocol.silenceAMBE
        let slow = Data([0xAA, 0xBB, 0xCC])
        let frame = MMDVMProtocol.buildDStarData(ambe: ambe, slowData: slow)
        // 0xE0 + length(0x0F = 15) + command(0x11) + 9 AMBE + 3 slow = 15
        #expect(frame.count == 15)
        #expect(frame[0] == 0xE0)
        #expect(frame[1] == 0x0F)
        #expect(frame[2] == MMDVMProtocol.dstarData)
        // AMBE bytes 3..12
        #expect(Data(frame[3..<12]) == ambe)
        // Slow data bytes 12..15
        #expect(Data(frame[12..<15]) == slow)
    }

    @Test("buildDStarData pads short AMBE and short slow data with zeros")
    func dstarDataPadding() {
        let frame = MMDVMProtocol.buildDStarData(ambe: Data([0x01, 0x02]), slowData: Data([0xFF]))
        #expect(frame.count == 15)
        // AMBE: 0x01 0x02 then 7 zeros
        #expect(frame[3] == 0x01)
        #expect(frame[4] == 0x02)
        for i in 5..<12 { #expect(frame[i] == 0x00) }
        // Slow data: 0xFF then 2 zeros
        #expect(frame[12] == 0xFF)
        #expect(frame[13] == 0x00)
        #expect(frame[14] == 0x00)
    }

    @Test("buildDStarData truncates oversized inputs")
    func dstarDataTruncation() {
        let bigAMBE = Data([UInt8](repeating: 0xAA, count: 20))
        let bigSlow = Data([UInt8](repeating: 0xBB, count: 10))
        let frame = MMDVMProtocol.buildDStarData(ambe: bigAMBE, slowData: bigSlow)
        #expect(frame.count == 15)
        #expect(frame[3..<12].allSatisfy { $0 == 0xAA })
        #expect(frame[12..<15].allSatisfy { $0 == 0xBB })
    }

    @Test("buildDStarEOT produces E0 03 13")
    func dstarEOT() {
        let frame = MMDVMProtocol.buildDStarEOT()
        #expect(frame == Data([0xE0, 0x03, 0x13]))
    }

    @Test("buildDStarHeader produces a 44-byte frame with valid CRC")
    func dstarHeader() {
        let frame = MMDVMProtocol.buildDStarHeader(
            myCallsign: "AI5OS",
            yourCallsign: "CQCQCQ",
            rpt1Callsign: "",
            rpt2Callsign: ""
        )
        // 0xE0 + length(0x2C = 44) + command(0x10) + 41 header = 44 bytes
        #expect(frame.count == 44)
        #expect(frame[0] == 0xE0)
        #expect(frame[1] == 0x2C)
        #expect(frame[2] == MMDVMProtocol.dstarHeader)

        // Extract the 41-byte header payload and verify the CRC round-trips.
        let headerPayload = Data(frame[3..<44])
        let embedded = UInt16(headerPayload[39]) | (UInt16(headerPayload[40]) << 8)
        let recomputed = DSTARCRC.compute(headerPayload, from: 0, count: 39)
        #expect(embedded == recomputed)
    }

    @Test("buildDStarHeader callsigns land at the correct offsets")
    func dstarHeaderCallsignLayout() {
        let frame = MMDVMProtocol.buildDStarHeader(
            myCallsign: "AI5OS",
            yourCallsign: "CQCQCQ",
            rpt1Callsign: "REF001 C",
            rpt2Callsign: "REF001 G"
        )
        let payload = Data(frame[3..<44])

        // Offset 3..10: RPT2 = "REF001 G" (8 bytes, space-padded)
        #expect(String(bytes: payload[3..<11], encoding: .ascii) == "REF001 G")
        // Offset 11..18: RPT1 = "REF001 C"
        #expect(String(bytes: payload[11..<19], encoding: .ascii) == "REF001 C")
        // Offset 19..26: YOUR = "CQCQCQ  " (padded)
        #expect(String(bytes: payload[19..<27], encoding: .ascii) == "CQCQCQ  ")
        // Offset 27..34: MY = "AI5OS   " (padded)
        #expect(String(bytes: payload[27..<35], encoding: .ascii) == "AI5OS   ")
        // Offset 35..38: suffix = "    "
        #expect(String(bytes: payload[35..<39], encoding: .ascii) == "    ")
    }

    // MARK: - Silence AMBE + filler slow data constants

    @Test("silenceAMBE is the documented 9-byte D-STAR silence pattern")
    func silenceAMBEConstant() {
        #expect(MMDVMProtocol.silenceAMBE == Data([0x9E, 0x8D, 0x32, 0x88, 0x26, 0x1A, 0x3F, 0x61, 0xE8]))
        #expect(MMDVMProtocol.silenceAMBE.count == 9)
    }

    @Test("fillerSlowData is the documented 3-byte filler pattern")
    func fillerSlowDataConstant() {
        #expect(MMDVMProtocol.fillerSlowData == Data([0x16, 0x29, 0xF5]))
        #expect(MMDVMProtocol.fillerSlowData.count == 3)
    }
}
