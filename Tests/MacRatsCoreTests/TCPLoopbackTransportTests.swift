import Foundation
import Testing
@testable import MacRatsCore

/// End-to-end test of the TCP loopback transport: spin up a server, connect a
/// client, send a real DDT2 encoded frame across, decode it on the other side,
/// and verify the payload survived.
///
/// This is the test that proves "two MacRats instances on the same Mac can
/// talk to each other without keying the radio."
struct TCPLoopbackTransportTests {

    /// A delegate that captures inbound bytes through a frame splitter and
    /// fulfills a continuation as soon as we have one complete frame.
    final class CollectingDelegate: RadioTransportDelegate, @unchecked Sendable {
        let splitter = DDT2FrameSplitter()
        let lock = NSLock()
        var frames: [Data] = []
        var statusHistory: [TransportStatus] = []
        var errors: [String] = []

        // Optional one-shot continuation for the first frame.
        var firstFrameContinuation: CheckedContinuation<Data, Never>?

        func transport(_ transport: RadioTransport, didReceive data: Data) {
            let newFrames = splitter.feed(data)
            lock.lock()
            frames.append(contentsOf: newFrames)
            let cont = firstFrameContinuation
            if !newFrames.isEmpty {
                firstFrameContinuation = nil
            }
            lock.unlock()
            if let first = newFrames.first {
                cont?.resume(returning: first)
            }
        }

        func transport(_ transport: RadioTransport, didChangeStatus status: TransportStatus) {
            lock.lock()
            statusHistory.append(status)
            lock.unlock()
        }

        func transport(_ transport: RadioTransport, didEncounterError error: Error) {
            lock.lock()
            errors.append(error.localizedDescription)
            lock.unlock()
        }

        func awaitFirstFrame() async -> Data {
            await withCheckedContinuation { cont in
                lock.lock()
                if let frame = frames.first {
                    lock.unlock()
                    cont.resume(returning: frame)
                } else {
                    firstFrameContinuation = cont
                    lock.unlock()
                }
            }
        }
    }

    /// Pick a TCP port unlikely to collide with anything else on the test
    /// machine. We use a high port; if this collides we can swap to listening
    /// on `0` and reading the assigned port back, but that path is more
    /// fiddly with NWListener.
    private static func ephemeralPort() -> UInt16 {
        UInt16.random(in: 49152...65535)
    }

    @Test("Two MacRats instances exchange one DDT2 frame end-to-end")
    func endToEndOneFrame() async throws {
        let port = Self.ephemeralPort()

        let server = TCPLoopbackTransport(mode: .server(port: port))
        let serverDelegate = CollectingDelegate()
        server.setDelegate(serverDelegate)
        try server.connect()

        // Give the listener a moment to bind before connecting.
        try await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        let client = TCPLoopbackTransport(mode: .client(host: "127.0.0.1", port: port))
        let clientDelegate = CollectingDelegate()
        client.setDelegate(clientDelegate)
        try client.connect()

        // Wait for the client to reach .connected.
        try await waitUntilConnected(client, timeout: 2.0)

        // Build a real frame.
        let outgoing = DDT2Frame(seq: 42,
                                 session: 1,
                                 type: 1,
                                 sStation: "AI5OS",
                                 dStation: "W9FYI",
                                 data: Data("MacRats live!".utf8),
                                 compress: true)
        let wire = DDT2EncodedFrame.pack(outgoing)
        try client.send(wire)

        // Wait for the server side to surface a complete frame.
        let received: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                await serverDelegate.awaitFirstFrame()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3s timeout
                throw TestTimeout.exceeded
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let parsed = try DDT2EncodedFrame.unpack(received)
        #expect(parsed.seq == 42)
        #expect(parsed.session == 1)
        #expect(parsed.type == 1)
        #expect(parsed.sStation == "AI5OS")
        #expect(parsed.dStation == "W9FYI")
        #expect(parsed.data == Data("MacRats live!".utf8))

        client.disconnect()
        server.disconnect()
    }

    private func waitUntilConnected(_ transport: TCPLoopbackTransport, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if transport.status == .connected {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000) // 25 ms
        }
        throw TestTimeout.exceeded
    }
}

enum TestTimeout: Error { case exceeded }
