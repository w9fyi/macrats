import Foundation
import Testing
@testable import MacRatsCore

struct MMDVMParserTests {

    // MARK: - Single frames

    @Test("Parses a single getStatus frame")
    func singleStatusFrame() {
        let parser = MMDVMParser()
        // getStatus response with a 2-byte status payload.
        let wire = Data([0xE0, 0x05, 0x01, 0x00, 0x42])
        let frames = parser.feed(wire)
        #expect(frames.count == 1)
        if case let .status(payload) = frames[0] {
            #expect(payload == Data([0x00, 0x42]))
        } else {
            Issue.record("Expected .status, got \(frames[0])")
        }
    }

    @Test("Parses a version response with ASCII payload")
    func versionResponse() {
        let parser = MMDVMParser()
        let versionBytes = Array("MMDVM TH-D75 1.0".utf8)
        var wire = Data([0xE0, UInt8(3 + versionBytes.count), MMDVMProtocol.getVersion])
        wire.append(contentsOf: versionBytes)
        let frames = parser.feed(wire)
        #expect(frames.count == 1)
        if case let .version(s) = frames[0] {
            #expect(s == "MMDVM TH-D75 1.0")
        } else {
            Issue.record("Expected .version, got \(frames[0])")
        }
    }

    @Test("Parses an ACK frame")
    func ack() {
        let parser = MMDVMParser()
        let frames = parser.feed(Data([0xE0, 0x03, MMDVMProtocol.ack]))
        #expect(frames.count == 1)
        #expect(frames[0] == .ack)
    }

    @Test("Parses a NAK with reason byte")
    func nakWithReason() {
        let parser = MMDVMParser()
        let frames = parser.feed(Data([0xE0, 0x04, MMDVMProtocol.nak, 0x07]))
        #expect(frames.count == 1)
        #expect(frames[0] == .nak(0x07))
    }

    @Test("Parses dstarLost")
    func dstarLost() {
        let parser = MMDVMParser()
        let frames = parser.feed(Data([0xE0, 0x03, MMDVMProtocol.dstarLost]))
        #expect(frames.count == 1)
        #expect(frames[0] == .dstarLost)
    }

    @Test("Parses dstarEOT")
    func dstarEOT() {
        let parser = MMDVMParser()
        let frames = parser.feed(Data([0xE0, 0x03, MMDVMProtocol.dstarEOT]))
        #expect(frames.count == 1)
        #expect(frames[0] == .dstarEOT)
    }

    @Test("Parses an unknown command")
    func unknownCommand() {
        let parser = MMDVMParser()
        let frames = parser.feed(Data([0xE0, 0x05, 0x99, 0xDE, 0xAD]))
        #expect(frames.count == 1)
        if case let .unknown(cmd, payload) = frames[0] {
            #expect(cmd == 0x99)
            #expect(payload == Data([0xDE, 0xAD]))
        } else {
            Issue.record("Expected .unknown, got \(frames[0])")
        }
    }

    // MARK: - D-STAR round-trips

    @Test("Round-trip: build dstarData + parse back yields identical voice payload")
    func dstarDataRoundTrip() {
        let ambe = MMDVMProtocol.silenceAMBE
        let slow = Data([0x5B, 0x53, 0x4F])  // first 3 bytes of "[SO" — what a real DDT2 envelope's leading bytes look like
        let wire = MMDVMProtocol.buildDStarData(ambe: ambe, slowData: slow)

        let parser = MMDVMParser()
        let frames = parser.feed(wire)
        #expect(frames.count == 1)
        guard case let .dstarVoice(payload) = frames[0] else {
            Issue.record("Expected .dstarVoice, got \(frames[0])")
            return
        }
        #expect(payload.count == 12)
        #expect(Data(payload[0..<9]) == ambe)
        #expect(Data(payload[9..<12]) == slow)
    }

    @Test("Round-trip: build dstarHeader + parse back yields the same 41 bytes")
    func dstarHeaderRoundTrip() {
        let wire = MMDVMProtocol.buildDStarHeader(myCallsign: "AI5OS", yourCallsign: "CQCQCQ")
        let parser = MMDVMParser()
        let frames = parser.feed(wire)
        #expect(frames.count == 1)
        guard case let .dstarHeader(payload) = frames[0] else {
            Issue.record("Expected .dstarHeader, got \(frames[0])")
            return
        }
        #expect(payload.count == 41)
        // Verify the CRC stored at offset 39..40 matches the recomputed value.
        let embedded = UInt16(payload[39]) | (UInt16(payload[40]) << 8)
        let recomputed = DSTARCRC.compute(payload, from: 0, count: 39)
        #expect(embedded == recomputed)
    }

    // MARK: - Partial and streaming

    @Test("Frame split across two feeds reassembles")
    func frameSplitAcrossFeeds() {
        let parser = MMDVMParser()
        let wire = MMDVMProtocol.buildDStarData(ambe: MMDVMProtocol.silenceAMBE,
                                                slowData: Data([0xAA, 0xBB, 0xCC]))
        let mid = wire.count / 2
        let part1 = wire.prefix(mid)
        let part2 = wire.suffix(from: mid)

        let r1 = parser.feed(Data(part1))
        #expect(r1.isEmpty)
        let r2 = parser.feed(Data(part2))
        #expect(r2.count == 1)
    }

    @Test("Multiple frames in one feed all extracted in order")
    func multipleFrames() {
        let parser = MMDVMParser()
        let f1 = MMDVMProtocol.buildGetVersion()
        let f2 = MMDVMProtocol.buildGetStatus()
        let f3 = MMDVMProtocol.buildDStarEOT()
        let combined = f1 + f2 + f3
        let frames = parser.feed(combined)
        #expect(frames.count == 3)
        // f1 has an empty payload so classify() returns .version("unknown")
        if case let .version(s) = frames[0] {
            #expect(s == "unknown")
        } else {
            Issue.record("Expected .version, got \(frames[0])")
        }
        if case .status = frames[1] { /* ok */ } else {
            Issue.record("Expected .status, got \(frames[1])")
        }
        #expect(frames[2] == .dstarEOT)
    }

    @Test("Garbage before 0xE0 marker is discarded")
    func garbagePrefix() {
        let parser = MMDVMParser()
        let wire = MMDVMProtocol.buildDStarEOT()
        let polluted = Data([0x11, 0x22, 0x33]) + wire
        let frames = parser.feed(polluted)
        #expect(frames.count == 1)
        #expect(frames[0] == .dstarEOT)
    }

    @Test("Bytes fed one at a time still reassemble into a frame")
    func byteAtATime() {
        let parser = MMDVMParser()
        let wire = MMDVMProtocol.buildSetConfig()
        var collected: [MMDVMParser.ParsedFrame] = []
        for byte in wire {
            collected.append(contentsOf: parser.feed(Data([byte])))
        }
        #expect(collected.count == 1)
        // setConfig is a host→modem command — when echoed back, classify()
        // sees command 0x02 which isn't in its switch, so it becomes
        // .unknown(0x02, <23 payload bytes>). That's expected; we just
        // care that a complete frame was extracted.
        if case let .unknown(cmd, payload) = collected[0] {
            #expect(cmd == MMDVMProtocol.setConfig)
            #expect(payload.count == 23)
        } else {
            Issue.record("Expected .unknown for setConfig, got \(collected[0])")
        }
    }

    // MARK: - Slow-data extraction

    @Test("slowData(from:) extracts the 3-byte slow-data trailer of a voice payload")
    func slowDataExtraction() {
        let voicePayload = MMDVMProtocol.silenceAMBE + Data([0x11, 0x22, 0x33])
        let slow = MMDVMParser.slowData(from: voicePayload)
        #expect(slow == Data([0x11, 0x22, 0x33]))
    }

    @Test("slowData(from:) returns empty Data on malformed (too-short) payload")
    func slowDataMalformed() {
        let slow = MMDVMParser.slowData(from: Data([0x01, 0x02, 0x03]))
        #expect(slow.isEmpty)
    }

    // MARK: - End-to-end: MMDVM voice stream carries a DDT2 frame

    @Test("End-to-end: DDT2 envelope chunked across dstarData slow fields, parsed back, decoded")
    func endToEndDDT2OverDStarVoice() throws {
        // Build a DDT2 encoded frame — what we'd actually transmit.
        let frame = DDT2Frame(seq: 5,
                              session: 0,
                              type: 1,
                              sStation: "AI5OS",
                              dStation: "W9FYI",
                              data: Data("MacRats over D-STAR!".utf8),
                              compress: true)
        let ddt2Wire = DDT2EncodedFrame.pack(frame)

        // Chunk the DDT2 wire bytes into 3-byte slow-data groups and build
        // a dstarData MMDVM frame for each one, exactly as the MacRats TX
        // state machine will do.
        var mmdvmStream = Data()
        var offset = 0
        while offset < ddt2Wire.count {
            let end = Swift.min(offset + 3, ddt2Wire.count)
            let chunk = ddt2Wire.subdata(in: offset..<end)
            mmdvmStream.append(MMDVMProtocol.buildDStarData(ambe: MMDVMProtocol.silenceAMBE, slowData: chunk))
            offset = end
        }

        // Parse the MMDVM stream back into voice frames, extract slow data,
        // feed to DDT2FrameSplitter, unpack.
        let parser = MMDVMParser()
        let parsed = parser.feed(mmdvmStream)
        let splitter = DDT2FrameSplitter()
        var reassembled = Data()
        for f in parsed {
            if case let .dstarVoice(payload) = f {
                reassembled.append(MMDVMParser.slowData(from: payload))
            }
        }
        // Strip the zero padding the last chunk added when ddt2Wire.count
        // wasn't a multiple of 3. We know the real DDT2 envelope ends with
        // [EOB] so the splitter will find the real boundary and ignore any
        // trailing nulls.
        let splitFrames = splitter.feed(reassembled)
        #expect(splitFrames.count == 1)

        let decoded = try DDT2EncodedFrame.unpack(splitFrames[0])
        #expect(decoded.seq == 5)
        #expect(decoded.sStation == "AI5OS")
        #expect(decoded.dStation == "W9FYI")
        #expect(decoded.data == Data("MacRats over D-STAR!".utf8))
    }
}
