import Foundation
import Testing
@testable import MacRatsCore

/// Tests for `DDT2FrameSplitter` — the stateful byte-stream-to-frame splitter
/// that sits between `RadioTransport` and `DDT2EncodedFrame.unpack(_:)`.
struct FrameSplitterTests {

    // Build a real encoded frame as a fixture.
    private func makeFrame(_ message: String) -> Data {
        let f = DDT2Frame(seq: 1, session: 0, type: 1,
                          sStation: "AI5OS", dStation: "W9FYI",
                          data: Data(message.utf8),
                          compress: false)
        return DDT2EncodedFrame.pack(f)
    }

    @Test("Single complete frame in one feed produces one frame")
    func singleCompleteFrame() throws {
        let splitter = DDT2FrameSplitter()
        let frame = makeFrame("hello")
        let frames = splitter.feed(frame)
        #expect(frames.count == 1)
        let parsed = try DDT2EncodedFrame.unpack(frames[0])
        #expect(parsed.data == Data("hello".utf8))
    }

    @Test("Frame split across two feeds reassembles")
    func frameSplitAcrossFeeds() throws {
        let splitter = DDT2FrameSplitter()
        let frame = makeFrame("split me")
        let mid = frame.count / 2
        let part1 = frame.subdata(in: 0..<mid)
        let part2 = frame.subdata(in: mid..<frame.count)

        let r1 = splitter.feed(part1)
        #expect(r1.isEmpty)
        let r2 = splitter.feed(part2)
        #expect(r2.count == 1)
        let parsed = try DDT2EncodedFrame.unpack(r2[0])
        #expect(parsed.data == Data("split me".utf8))
    }

    @Test("Multiple frames in one feed all extracted")
    func multipleFrames() throws {
        let splitter = DDT2FrameSplitter()
        let f1 = makeFrame("one")
        let f2 = makeFrame("two")
        let f3 = makeFrame("three")
        let combined = f1 + f2 + f3
        let frames = splitter.feed(combined)
        #expect(frames.count == 3)
        #expect(try DDT2EncodedFrame.unpack(frames[0]).data == Data("one".utf8))
        #expect(try DDT2EncodedFrame.unpack(frames[1]).data == Data("two".utf8))
        #expect(try DDT2EncodedFrame.unpack(frames[2]).data == Data("three".utf8))
    }

    @Test("Garbage before SOB is discarded, frame still extracted")
    func garbagePrefix() throws {
        let splitter = DDT2FrameSplitter()
        let frame = makeFrame("payload")
        let polluted = Data("xxxx random noise yyyy ".utf8) + frame
        let frames = splitter.feed(polluted)
        #expect(frames.count == 1)
        #expect(try DDT2EncodedFrame.unpack(frames[0]).data == Data("payload".utf8))
    }

    @Test("Garbage between two frames is discarded")
    func garbageBetweenFrames() throws {
        let splitter = DDT2FrameSplitter()
        let f1 = makeFrame("first")
        let f2 = makeFrame("second")
        let combined = f1 + Data("zzzzz noise zzzzz".utf8) + f2
        let frames = splitter.feed(combined)
        #expect(frames.count == 2)
        #expect(try DDT2EncodedFrame.unpack(frames[0]).data == Data("first".utf8))
        #expect(try DDT2EncodedFrame.unpack(frames[1]).data == Data("second".utf8))
    }

    @Test("Bytes fed one at a time still produce a frame")
    func byteAtATime() throws {
        let splitter = DDT2FrameSplitter()
        let frame = makeFrame("dripfeed")
        var collected: [Data] = []
        for byte in frame {
            collected.append(contentsOf: splitter.feed(Data([byte])))
        }
        #expect(collected.count == 1)
        #expect(try DDT2EncodedFrame.unpack(collected[0]).data == Data("dripfeed".utf8))
    }
}
