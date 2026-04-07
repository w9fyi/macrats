import Foundation
import Testing
@testable import MacRatsCore

struct WireLoggerTests {

    private func makeTempLogger(rotateAtBytes: Int64 = 10 * 1024 * 1024,
                                 maxBytesPerLine: Int = 512) -> (logger: WireLogger, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrats-wirelog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("wire.log")
        let logger = WireLogger(url: url, rotateAtBytes: rotateAtBytes, maxBytesPerLine: maxBytesPerLine)
        return (logger, url)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Format

    @Test("Line format starts with HH:mm:ss.SSS timestamp")
    func formatStartsWithTimestamp() {
        let (logger, url) = makeTempLogger()
        defer { cleanup(url) }
        let line = logger.formatLine(direction: "TX", data: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        // Should match e.g. "12:34:56.789 TX 4 bytes ..."
        let pattern = "^\\d{2}:\\d{2}:\\d{2}\\.\\d{3} TX 4 bytes  de ad be ef  \\| \\.\\.\\.\\.\n$"
        let regex = try? NSRegularExpression(pattern: pattern)
        let match = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        #expect(match != nil, "expected format match, got: \(line)")
    }

    @Test("Direction is padded to 2 characters (TX / RX)")
    func directionPadded() {
        let (logger, url) = makeTempLogger()
        defer { cleanup(url) }
        let tx = logger.formatLine(direction: "TX", data: Data([0x01]))
        let rx = logger.formatLine(direction: "RX", data: Data([0x02]))
        #expect(tx.contains(" TX "))
        #expect(rx.contains(" RX "))
    }

    @Test("Hex and ASCII columns are both present")
    func hexAndAsciiColumns() {
        let (logger, url) = makeTempLogger()
        defer { cleanup(url) }
        let line = logger.formatLine(direction: "TX", data: Data("Hi!".utf8))
        #expect(line.contains("48 69 21"))  // hex of "Hi!"
        #expect(line.contains("| Hi!"))     // ASCII dump
    }

    @Test("Non-printable bytes render as '.' in ASCII column")
    func nonPrintableAsDots() {
        let (logger, url) = makeTempLogger()
        defer { cleanup(url) }
        let line = logger.formatLine(direction: "RX", data: Data([0x00, 0x01, 0xFF, 0x7F, 0x41]))
        // 0x41 = 'A' (printable); others should render as '.'
        #expect(line.contains("| ....A"))
    }

    @Test("Long chunks are truncated with 'N more bytes' suffix")
    func longChunksTruncated() {
        let (logger, url) = makeTempLogger(maxBytesPerLine: 4)
        defer { cleanup(url) }
        let data = Data(repeating: 0xAA, count: 10)
        let line = logger.formatLine(direction: "TX", data: data)
        #expect(line.contains("10 bytes"))
        #expect(line.contains("(6 more bytes)"))
    }

    // MARK: - File writes

    @Test("Single log call produces one line in the file")
    func singleLogProducesOneLine() throws {
        let (logger, url) = makeTempLogger()
        defer { cleanup(url) }

        try logger.logThrowing("TX", Data([0xDE, 0xAD]))

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.split(separator: "\n").count == 1)
        #expect(contents.contains("TX 2 bytes"))
    }

    @Test("Multiple log calls append in order")
    func multipleLogsAppend() throws {
        let (logger, url) = makeTempLogger()
        defer { cleanup(url) }

        try logger.logThrowing("TX", Data("first".utf8))
        try logger.logThrowing("RX", Data("second".utf8))
        try logger.logThrowing("TX", Data("third".utf8))

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains("TX") && lines[0].contains("| first"))
        #expect(lines[1].contains("RX") && lines[1].contains("| second"))
        #expect(lines[2].contains("TX") && lines[2].contains("| third"))
    }

    // MARK: - Rotation

    @Test("Manual rotate moves current log to .old")
    func manualRotate() throws {
        let (logger, url) = makeTempLogger()
        defer { cleanup(url) }

        try logger.logThrowing("TX", Data("alpha".utf8))
        try logger.rotate()

        let oldURL = url.appendingPathExtension("old")
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        let oldContents = try String(contentsOf: oldURL, encoding: .utf8)
        #expect(oldContents.contains("| alpha"))
        // Active file should be empty.
        let active = try String(contentsOf: url, encoding: .utf8)
        #expect(active.isEmpty)
    }

    @Test("Automatic rotation triggers when file exceeds rotateAtBytes")
    func automaticRotation() throws {
        // Low threshold so a handful of writes triggers it.
        let (logger, url) = makeTempLogger(rotateAtBytes: 200)
        defer { cleanup(url) }

        for i in 0..<10 {
            try logger.logThrowing("TX", Data("chunk \(i) with enough bytes to push past the threshold".utf8))
        }

        let oldURL = url.appendingPathExtension("old")
        #expect(FileManager.default.fileExists(atPath: oldURL.path),
                "rotation should have produced a .old file")
    }

    @Test("deleteAll removes both active and rotated files")
    func deleteAll() throws {
        let (logger, url) = makeTempLogger()
        defer { cleanup(url) }

        try logger.logThrowing("TX", Data([0x01]))
        try logger.rotate()
        try logger.logThrowing("TX", Data([0x02]))

        try logger.deleteAll()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("old").path))
    }

    // MARK: - SessionManager wiring (integration)

    @Test("SessionManager.wireLogHandler writes to a WireLogger")
    func sessionManagerIntegration() throws {
        // Stand up a minimal stub transport + manager + chat session,
        // wire the logger in, send one message, verify the log file
        // got TX entries.
        let (logger, url) = makeTempLogger()
        defer { cleanup(url) }

        // Minimal stub transport (same shape as WarmupFrameTests).
        final class Stub: RadioTransport, @unchecked Sendable {
            let displayName = "stub"
            var status: TransportStatus = .connected
            private var delegate: RadioTransportDelegate?
            func setDelegate(_ d: RadioTransportDelegate?) { delegate = d }
            func connect() throws {}
            func disconnect() {}
            func send(_ data: Data) throws {}
        }
        let transport = Stub()
        let manager = SessionManager(callsign: "AI5OS", transport: transport, wireTuning: .radio)
        let chat = ChatSession()
        manager.add(chat, id: 1)
        manager.wireLogHandler = { direction, data in
            logger.log(direction, data)
        }

        try chat.sendMessage("hello")

        // Give the best-effort async error path nothing to do, then
        // read the file. (All ops are synchronous in this test.)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        // Two TX lines: warmup + real frame.
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("TX") })
    }
}
