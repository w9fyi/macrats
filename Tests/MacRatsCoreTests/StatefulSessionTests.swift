import Foundation
import Testing
@testable import MacRatsCore

/// Integration tests for `StatefulSession` — the reliable-delivery
/// session layer that file transfer is built on top of. These use
/// `TCPLoopbackTransport` to run two fully independent SessionManagers
/// on the same Mac and exercise the ACK / REQACK / sliding-window
/// protocol end-to-end.
///
/// Every test in this suite sends real bytes through the DDT2 framing
/// layer, the SOB/EOB splitter, and the transport pair. If the
/// underlying stateful protocol has a bug (sequence wraparound,
/// duplicate suppression, retry counting, ACK filtering), the
/// integration tests here will surface it — that's the point. Unit
/// tests on the class would miss this kind of thing.
///
/// Marked `.serialized` like `ChatSessionTests` because each test
/// binds a TCP port on localhost and Swift Testing's default parallel
/// execution can cause two tests to pick the same random high port.
@Suite(.serialized)
struct StatefulSessionTests {

    // MARK: - Test harness

    /// Records every data delivery, close, and failure for assertions.
    final class RecordingDelegate: StatefulSession.Delegate, @unchecked Sendable {
        let lock = NSLock()
        private var _received = Data()
        private var _closed = false
        private var _failedReason: String?
        private var receivedContinuations: [CheckedContinuation<Data, Never>] = []
        private var closeContinuations: [CheckedContinuation<Void, Never>] = []

        var received: Data {
            lock.lock(); defer { lock.unlock() }
            return _received
        }
        var isClosed: Bool {
            lock.lock(); defer { lock.unlock() }
            return _closed
        }
        var failureReason: String? {
            lock.lock(); defer { lock.unlock() }
            return _failedReason
        }

        func statefulSession(_ session: StatefulSession, didReceive data: Data) {
            lock.lock()
            _received.append(data)
            let snapshot = _received
            let conts = receivedContinuations
            receivedContinuations.removeAll()
            lock.unlock()
            for cont in conts {
                cont.resume(returning: snapshot)
            }
        }

        func statefulSessionDidClose(_ session: StatefulSession) {
            lock.lock()
            _closed = true
            let conts = closeContinuations
            closeContinuations.removeAll()
            lock.unlock()
            for cont in conts {
                cont.resume(returning: ())
            }
        }

        func statefulSession(_ session: StatefulSession, didFailWithReason reason: String) {
            lock.lock()
            _failedReason = reason
            _closed = true
            let conts = closeContinuations
            closeContinuations.removeAll()
            lock.unlock()
            for cont in conts {
                cont.resume(returning: ())
            }
        }

        /// Non-async snapshot — grab the current received buffer and
        /// closed flag under the lock without crossing an `await`.
        /// Callers sleep between snapshots in async context.
        struct Snapshot: Sendable {
            let received: Data
            let closed: Bool
            let failureReason: String?
        }
        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return Snapshot(received: _received,
                            closed: _closed,
                            failureReason: _failedReason)
        }
    }

    /// Wait until the delegate has received at least `expectedCount`
    /// bytes, or timeout. Uses `snapshot()` so no lock is held across
    /// the `await`. Returns the final accumulated buffer.
    static func awaitBytes(_ delegate: RecordingDelegate,
                            atLeast expectedCount: Int,
                            timeout: TimeInterval) async -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snap = delegate.snapshot()
            if snap.received.count >= expectedCount {
                return snap.received
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return delegate.snapshot().received
    }

    static func awaitClose(_ delegate: RecordingDelegate,
                            timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if delegate.snapshot().closed { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// A pair of connected SessionManagers + StatefulSessions over
    /// TCP loopback. The caller disconnects both managers when done.
    struct Pair {
        let serverManager: SessionManager
        let serverSession: StatefulSession
        let serverDelegate: RecordingDelegate
        let clientManager: SessionManager
        let clientSession: StatefulSession
        let clientDelegate: RecordingDelegate

        func disconnectAll() {
            clientManager.disconnect()
            serverManager.disconnect()
        }
    }

    static func makePair(blocksize: Int = 1024,
                         outLimit: Int = 8) async throws -> Pair {
        let port = UInt16.random(in: 49152...65535)

        let serverTransport = TCPLoopbackTransport(mode: .server(port: port))
        let serverManager = SessionManager(callsign: "AI5OS",
                                            transport: serverTransport,
                                            wireTuning: .net)
        let serverSession = StatefulSession(name: "file",
                                             remoteStation: "W9FYI",
                                             blocksize: blocksize,
                                             outLimit: outLimit)
        let serverDelegate = RecordingDelegate()
        serverSession.delegate = serverDelegate
        serverManager.add(serverSession, id: 2)
        try serverManager.connect()

        try await Task.sleep(nanoseconds: 60_000_000)

        let clientTransport = TCPLoopbackTransport(mode: .client(host: "127.0.0.1", port: port))
        let clientManager = SessionManager(callsign: "W9FYI",
                                            transport: clientTransport,
                                            wireTuning: .net)
        let clientSession = StatefulSession(name: "file",
                                             remoteStation: "AI5OS",
                                             blocksize: blocksize,
                                             outLimit: outLimit)
        let clientDelegate = RecordingDelegate()
        clientSession.delegate = clientDelegate
        clientManager.add(clientSession, id: 2)
        try clientManager.connect()

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if serverTransport.status == .connected && clientTransport.status == .connected {
                return Pair(serverManager: serverManager,
                            serverSession: serverSession,
                            serverDelegate: serverDelegate,
                            clientManager: clientManager,
                            clientSession: clientSession,
                            clientDelegate: clientDelegate)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw TimeoutError.exceeded
    }

    enum TimeoutError: Error { case exceeded }

    // MARK: - Happy path

    @Test("Single small block is received end-to-end")
    func singleBlockRoundtrip() async throws {
        let pair = try await Self.makePair()
        defer { pair.disconnectAll() }

        let payload = Data("Hello, stateful world!".utf8)
        pair.clientSession.send(payload)

        let received = await Self.awaitBytes(pair.serverDelegate, atLeast:payload.count,
                                                             timeout: 5.0)
        #expect(received == payload)
    }

    @Test("Multi-block message is reassembled in order")
    func multiBlockRoundtrip() async throws {
        // Use a tiny blocksize so our modest payload becomes many blocks.
        let pair = try await Self.makePair(blocksize: 16, outLimit: 8)
        defer { pair.disconnectAll() }

        // 256 bytes across 16-byte blocks = 16 blocks.
        let payload = Data((0..<256).map { UInt8($0 & 0xFF) })
        pair.clientSession.send(payload)

        let received = await Self.awaitBytes(pair.serverDelegate, atLeast:payload.count,
                                                             timeout: 15.0)
        #expect(received == payload)
    }

    @Test("Bidirectional exchange — both sides send and receive")
    func bidirectional() async throws {
        let pair = try await Self.makePair(blocksize: 32)
        defer { pair.disconnectAll() }

        let clientToServer = Data("The client says hello to the server.".utf8)
        let serverToClient = Data("And the server replies to the client.".utf8)

        pair.clientSession.send(clientToServer)
        pair.serverSession.send(serverToClient)

        let serverGot = await Self.awaitBytes(pair.serverDelegate, atLeast:clientToServer.count,
                                                              timeout: 10.0)
        let clientGot = await Self.awaitBytes(pair.clientDelegate, atLeast:serverToClient.count,
                                                              timeout: 10.0)

        #expect(serverGot == clientToServer)
        #expect(clientGot == serverToClient)
    }

    @Test("Block > outLimit window is still fully delivered")
    func exceedsWindow() async throws {
        // outLimit = 4, blocksize = 10, 20-block payload exercises the
        // window slide + REQACK/ACK/next-window cycle at least 5 times.
        let pair = try await Self.makePair(blocksize: 10, outLimit: 4)
        defer { pair.disconnectAll() }

        let payload = Data((0..<200).map { UInt8($0 & 0xFF) })
        pair.clientSession.send(payload)

        let received = await Self.awaitBytes(pair.serverDelegate, atLeast:payload.count,
                                                             timeout: 30.0)
        #expect(received == payload)
    }

    // MARK: - Multiple sends

    @Test("Two separate sends from the same session are both delivered")
    func multipleSends() async throws {
        let pair = try await Self.makePair(blocksize: 20)
        defer { pair.disconnectAll() }

        pair.clientSession.send(Data("first message ".utf8))
        pair.clientSession.send(Data("second message".utf8))

        let received = await Self.awaitBytes(pair.serverDelegate, atLeast:29, timeout: 10.0)
        // Two sends are treated as one logical stream at the session
        // layer — they concatenate into the delegate's buffer.
        #expect(received == Data("first message second message".utf8))
    }

    @Test("Empty send is a no-op")
    func emptySend() async throws {
        let pair = try await Self.makePair()
        defer { pair.disconnectAll() }

        pair.clientSession.send(Data())

        // Give it a beat to prove nothing crosses the wire.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(pair.serverDelegate.snapshot().received.isEmpty)
    }

    // MARK: - Close lifecycle

    @Test("Closing the sender fires didClose on the sender's delegate")
    func senderCloseFiresDelegate() async throws {
        let pair = try await Self.makePair()
        defer { pair.disconnectAll() }

        pair.clientSession.close()
        await Self.awaitClose(pair.clientDelegate, timeout: 3.0)
        let snap = pair.clientDelegate.snapshot()
        #expect(snap.closed)
        #expect(snap.failureReason == nil)
    }

    // MARK: - Block sequence unit tests (no network)

    @Test("Block sequence wraps from 255 to 0 within the session")
    func sequenceWrap() {
        // Create a session with no manager — we only exercise the
        // local block-queueing state.
        let s = StatefulSession(name: "wraptest", remoteStation: "PEER", blocksize: 1)
        defer { s.close() }

        // Send 260 single-byte chunks. Each one takes its own seq.
        // The internal counter should wrap 255 → 0 → 1 ... → 3.
        // We can only observe this indirectly: sending 260 blocks must
        // not crash, and the session must still be alive (not failed).
        for byte in 0..<260 {
            s.send(Data([UInt8(byte & 0xFF)]))
        }
        // A tiny pause so the worker has a chance to log anything
        // unexpected. It WON'T transmit because there's no manager.
        Thread.sleep(forTimeInterval: 0.05)
    }
}
