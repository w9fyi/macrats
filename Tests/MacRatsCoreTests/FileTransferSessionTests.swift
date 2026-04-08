import Foundation
import Testing
@testable import MacRatsCore

/// Integration tests for `FileTransferSession`. The happy path is a
/// two-side loopback transfer: one MacRats instance sends a file, the
/// other receives it, and we verify the reconstructed bytes match the
/// original. Runs in the real protocol stack — DDT2 frames, the
/// stateful reliability layer, and TCPLoopbackTransport.
///
/// Marked `.serialized` because each test allocates a random TCP port
/// and we don't want two tests to pick the same one.
@Suite(.serialized)
struct FileTransferSessionTests {

    // MARK: - zlib roundtrip (no network)

    @Test("zlib compress → decompress roundtrips arbitrary data")
    func zlibRoundtrip() throws {
        let inputs: [Data] = [
            Data("Hello, world!".utf8),
            Data(repeating: 0, count: 4096),
            Data((0..<8192).map { UInt8($0 & 0xFF) }),
            Data("The quick brown fox jumps over the lazy dog.".utf8),
        ]
        for input in inputs {
            let compressed = try FileTransferSession.zlibCompress(input, level: 9)
            let decompressed = try FileTransferSession.zlibDecompress(compressed)
            #expect(decompressed == input)
        }
    }

    @Test("zlib-compressed output starts with the standard zlib header")
    func zlibHeader() throws {
        // zlib.compress(b"hello", 9) in Python produces a blob that
        // starts with 0x78 0xDA (zlib header indicating deflate with
        // best-compression level). This is the byte D-Rats peers look
        // for. If we produced a raw-deflate or gzip frame instead, the
        // peer's zlib.decompress would fail.
        let compressed = try FileTransferSession.zlibCompress(Data("hello".utf8), level: 9)
        #expect(compressed.count >= 2)
        #expect(compressed[0] == 0x78)
        #expect(compressed[1] == 0xDA)
    }

    // MARK: - End-to-end loopback transfer

    /// Tiny paired harness — both sessions are registered on opposite
    /// ends of a TCP loopback. Uses distinct session ids for sender
    /// and receiver so we don't confuse MacRats's routing — both sides
    /// use id 3 on their own manager.
    private static func makeTransferPair(senderBlocksize: Int = 512,
                                          receiverBlocksize: Int = 512) async throws
        -> (serverMgr: SessionManager, clientMgr: SessionManager,
            senderSession: FileTransferSession, receiverSession: FileTransferSession,
            senderFileDelegate: RecordingFileDelegate,
            receiverFileDelegate: RecordingFileDelegate)
    {
        let port = UInt16.random(in: 49152...65535)

        let serverTransport = TCPLoopbackTransport(mode: .server(port: port))
        let serverMgr = SessionManager(callsign: "AI5OS",
                                        transport: serverTransport,
                                        wireTuning: .net)

        // Server hosts the RECEIVER.
        let receiver = FileTransferSession(remoteStation: "W9FYI",
                                            role: .receiver,
                                            blocksize: receiverBlocksize)
        let receiverDelegate = RecordingFileDelegate()
        receiver.fileDelegate = receiverDelegate
        serverMgr.add(receiver, id: 3)
        try serverMgr.connect()

        try await Task.sleep(nanoseconds: 60_000_000)

        let clientTransport = TCPLoopbackTransport(mode: .client(host: "127.0.0.1", port: port))
        let clientMgr = SessionManager(callsign: "W9FYI",
                                        transport: clientTransport,
                                        wireTuning: .net)

        // Client hosts the SENDER.
        let sender = FileTransferSession(remoteStation: "AI5OS",
                                          role: .sender,
                                          blocksize: senderBlocksize)
        let senderDelegate = RecordingFileDelegate()
        sender.fileDelegate = senderDelegate
        clientMgr.add(sender, id: 3)
        try clientMgr.connect()

        // Wait for both transports to be live.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if serverTransport.status == .connected && clientTransport.status == .connected {
                return (serverMgr, clientMgr, sender, receiver, senderDelegate, receiverDelegate)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw TestError.timeout
    }

    enum TestError: Error { case timeout }

    @Test("End-to-end file transfer roundtrips bytes exactly")
    func endToEnd() async throws {
        // Build a payload with enough structure that a single-byte
        // error would change the decompressed output in a visible
        // way — a counter through every 8-bit value.
        let originalBytes = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrats-filexfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let inputURL = tmpDir.appendingPathComponent("input.bin")
        try originalBytes.write(to: inputURL)

        let downloadDir = tmpDir.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        let pair = try await Self.makeTransferPair()
        defer {
            pair.clientMgr.disconnect()
            pair.serverMgr.disconnect()
        }

        // Receiver arms first.
        try pair.receiverSession.startReceiving(saveTo: downloadDir)

        // Sender kicks off.
        try pair.senderSession.sendFile(url: inputURL)

        // Wait up to 30 seconds for the receiver to report completion.
        let deadline = Date().addingTimeInterval(30.0)
        while Date() < deadline {
            if case .complete = pair.receiverSession.currentPhase { break }
            if case .failed(let r) = pair.receiverSession.currentPhase {
                Issue.record("Receiver failed: \(r)")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Verify the final state of the receiver.
        guard case .complete(let outURL) = pair.receiverSession.currentPhase else {
            Issue.record("Receiver never reached .complete; phase = \(pair.receiverSession.currentPhase)")
            return
        }

        let reconstructed = try Data(contentsOf: outURL)
        #expect(reconstructed == originalBytes,
                "Reconstructed file must match original byte-for-byte")

        // Delegate events: begin + complete should have fired on the
        // receiver side.
        let rxSnapshot = pair.receiverFileDelegate.snapshot()
        #expect(rxSnapshot.didBegin)
        #expect(rxSnapshot.didComplete)
        #expect(rxSnapshot.failureReason == nil)
        #expect(rxSnapshot.beginFilename == "input.bin")
    }

    @Test("Wrong role is rejected with a descriptive error")
    func wrongRoleRejected() {
        let receiver = FileTransferSession(remoteStation: "W9FYI", role: .receiver)
        defer { receiver.close() }
        let url = URL(fileURLWithPath: "/tmp/nope.bin")
        #expect(throws: FileTransferError.self) {
            try receiver.sendFile(url: url)
        }

        let sender = FileTransferSession(remoteStation: "W9FYI", role: .sender)
        defer { sender.close() }
        #expect(throws: FileTransferError.self) {
            try sender.startReceiving(saveTo: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test("Missing file produces fileNotReadable error")
    func missingFile() {
        let sender = FileTransferSession(remoteStation: "W9FYI", role: .sender)
        defer { sender.close() }
        let bogus = URL(fileURLWithPath: "/nope/definitely-not/a/real/file.bin")
        do {
            try sender.sendFile(url: bogus)
            Issue.record("Expected sendFile to throw for a missing file")
        } catch FileTransferError.fileNotReadable {
            // expected
        } catch {
            Issue.record("Expected fileNotReadable, got \(error)")
        }
    }
}

/// Records delegate events from FileTransferSession for assertions.
final class RecordingFileDelegate: FileTransferSession.FileTransferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _didBegin = false
    private var _beginFilename = ""
    private var _beginTotal = 0
    private var _progressUpdates: [(Int, Int)] = []
    private var _didComplete = false
    private var _completedURL: URL?
    private var _failureReason: String?

    struct Snapshot: Sendable {
        let didBegin: Bool
        let beginFilename: String
        let beginTotal: Int
        let progressCount: Int
        let didComplete: Bool
        let completedURL: URL?
        let failureReason: String?
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(didBegin: _didBegin,
                        beginFilename: _beginFilename,
                        beginTotal: _beginTotal,
                        progressCount: _progressUpdates.count,
                        didComplete: _didComplete,
                        completedURL: _completedURL,
                        failureReason: _failureReason)
    }

    func fileTransferDidBegin(_ session: FileTransferSession,
                               filename: String,
                               totalBytes: Int) {
        lock.lock()
        _didBegin = true
        _beginFilename = filename
        _beginTotal = totalBytes
        lock.unlock()
    }

    func fileTransfer(_ session: FileTransferSession,
                       didProgressTo bytesReceived: Int,
                       of totalBytes: Int) {
        lock.lock()
        _progressUpdates.append((bytesReceived, totalBytes))
        lock.unlock()
    }

    func fileTransferDidComplete(_ session: FileTransferSession,
                                  fileURL: URL) {
        lock.lock()
        _didComplete = true
        _completedURL = fileURL
        lock.unlock()
    }

    func fileTransfer(_ session: FileTransferSession, didFailWith reason: String) {
        lock.lock()
        _failureReason = reason
        lock.unlock()
    }
}
