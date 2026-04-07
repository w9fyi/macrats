import Foundation
import Testing
@testable import MacRatsCore

/// Tests for `ChatSession` + `SessionManager` — the application-level
/// messaging layer of MacRats. These use `TCPLoopbackTransport` to run
/// two fully independent `SessionManager` instances on the same Mac,
/// exchange chat / ping / status frames, and verify the delegate
/// callbacks fire with the right values.
///
/// This is the proof that two MacRats processes can talk to each other
/// with no radio, which is the v1.0 development and integration-test
/// story.
///
/// Marked `.serialized` because each test spins up a TCP server on a
/// random high port, and Swift Testing's default parallel execution can
/// cause two tests to pick the same port and fail to bind. Running
/// serially eliminates the race and is fast enough for this suite
/// (~4 seconds total for 11 tests).
@Suite(.serialized)
struct ChatSessionTests {

    // MARK: - Delegate capture

    /// Records every delegate callback so tests can assert on them.
    final class RecordingDelegate: ChatSession.Delegate, @unchecked Sendable {
        let lock = NSLock()

        struct Message: Equatable {
            let text: String
            let from: String
            let to: String
        }
        struct Ping: Equatable {
            let from: String
            let to: String
        }
        struct PingResponse: Equatable {
            let from: String
            let to: String
            let replyText: String
        }
        struct StatusUpdate: Equatable {
            let from: String
            let status: StationStatus
            let message: String
        }

        var messages: [Message] = []
        var pingRequests: [Ping] = []
        var pingResponses: [PingResponse] = []
        var statusUpdates: [StatusUpdate] = []

        private var messageContinuations: [CheckedContinuation<Message, Never>] = []

        func chatSession(_ session: ChatSession, didReceiveMessage text: String, from sStation: String, to dStation: String) {
            let msg = Message(text: text, from: sStation, to: dStation)
            lock.lock()
            messages.append(msg)
            let conts = messageContinuations
            messageContinuations.removeAll()
            lock.unlock()
            for cont in conts {
                cont.resume(returning: msg)
            }
        }

        func chatSession(_ session: ChatSession, didReceivePingRequest from: String, to dStation: String) {
            lock.lock()
            pingRequests.append(Ping(from: from, to: dStation))
            lock.unlock()
        }

        func chatSession(_ session: ChatSession, didReceivePingResponse from: String, to dStation: String, replyText: String) {
            lock.lock()
            pingResponses.append(PingResponse(from: from, to: dStation, replyText: replyText))
            lock.unlock()
        }

        func chatSession(_ session: ChatSession, didReceiveEchoRequest from: String, to dStation: String, payload: Data) {}
        func chatSession(_ session: ChatSession, didReceiveEchoResponse from: String, to dStation: String, payload: Data) {}

        func chatSession(_ session: ChatSession, didReceiveStationStatus from: String, status: StationStatus, message: String) {
            lock.lock()
            statusUpdates.append(StatusUpdate(from: from, status: status, message: message))
            lock.unlock()
        }

        func awaitMessage() async -> Message {
            await withCheckedContinuation { cont in
                lock.lock()
                if let first = messages.first {
                    lock.unlock()
                    cont.resume(returning: first)
                    return
                }
                messageContinuations.append(cont)
                lock.unlock()
            }
        }

        /// Snapshot struct returned atomically from `snapshot()`. Lets
        /// async test code read all fields without holding an NSLock
        /// across an await boundary.
        struct Snapshot: Sendable {
            var messages: [Message]
            var pingRequests: [Ping]
            var pingResponses: [PingResponse]
            var statusUpdates: [StatusUpdate]
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(messages: messages,
                            pingRequests: pingRequests,
                            pingResponses: pingResponses,
                            statusUpdates: statusUpdates)
        }
    }

    // MARK: - Test pair setup

    /// Spin up a pair of connected SessionManagers (server + client) plus
    /// their ChatSessions and delegates. Caller is responsible for
    /// disconnecting both managers when done.
    private static func makePair(
        serverCallsign: String = "AI5OS",
        clientCallsign: String = "W9FYI",
        port: UInt16? = nil
    ) async throws -> (serverManager: SessionManager,
                       serverChat: ChatSession,
                       serverDelegate: RecordingDelegate,
                       clientManager: SessionManager,
                       clientChat: ChatSession,
                       clientDelegate: RecordingDelegate) {
        let actualPort = port ?? UInt16.random(in: 49152...65535)

        let serverTransport = TCPLoopbackTransport(mode: .server(port: actualPort))
        let serverManager = SessionManager(callsign: serverCallsign, transport: serverTransport)
        let serverChat = ChatSession(pingReplyText: "Server here — \(serverCallsign)")
        let serverDelegate = RecordingDelegate()
        serverChat.delegate = serverDelegate
        serverManager.add(serverChat, id: 1)
        try serverManager.connect()

        // Give the listener a moment to bind.
        try await Task.sleep(nanoseconds: 60_000_000)

        let clientTransport = TCPLoopbackTransport(mode: .client(host: "127.0.0.1", port: actualPort))
        let clientManager = SessionManager(callsign: clientCallsign, transport: clientTransport)
        let clientChat = ChatSession(pingReplyText: "Client here — \(clientCallsign)")
        let clientDelegate = RecordingDelegate()
        clientChat.delegate = clientDelegate
        clientManager.add(clientChat, id: 1)
        try clientManager.connect()

        // Wait for both sides to reach .connected.
        try await waitUntil(timeout: 3.0) {
            serverTransport.status == .connected && clientTransport.status == .connected
        }

        return (serverManager, serverChat, serverDelegate,
                clientManager, clientChat, clientDelegate)
    }

    private static func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw TestTimeoutError.exceeded
    }

    enum TestTimeoutError: Error { case exceeded }

    // MARK: - Tests

    @Test("Two SessionManagers exchange a chat message end-to-end")
    func twoWayChat() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.clientManager.disconnect()
            pair.serverManager.disconnect()
        }

        // Client sends a broadcast chat message.
        try pair.clientChat.sendMessage("Hello from W9FYI!")

        // Server's delegate should receive it.
        let msg = try await withThrowingTaskGroup(of: RecordingDelegate.Message.self) { group in
            group.addTask {
                await pair.serverDelegate.awaitMessage()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw TestTimeoutError.exceeded
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        #expect(msg.text == "Hello from W9FYI!")
        #expect(msg.from == "W9FYI")
        #expect(msg.to == "CQCQCQ")
    }

    @Test("Direct message to a specific station is delivered")
    func directMessage() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.clientManager.disconnect()
            pair.serverManager.disconnect()
        }

        try pair.clientChat.sendMessage("Private hello", to: "AI5OS")
        let msg = await pair.serverDelegate.awaitMessage()

        #expect(msg.text == "Private hello")
        #expect(msg.from == "W9FYI")
        #expect(msg.to == "AI5OS")
    }

    @Test("Ping request gets an automatic response")
    func pingRoundTrip() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.clientManager.disconnect()
            pair.serverManager.disconnect()
        }

        // Client pings the server directly (no broadcast delay).
        try pair.clientChat.pingStation("AI5OS")

        // Wait for the client to see a ping response from the server.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            let responses = pair.clientDelegate.snapshot().pingResponses
            if let first = responses.first {
                #expect(first.from == "AI5OS")
                #expect(first.to == "W9FYI")
                #expect(first.replyText.contains("Server here"))
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        Issue.record("No ping response received within 3 seconds")
    }

    @Test("Ping to a station that isn't us is NOT auto-responded to")
    func directedPingToOtherStation() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.clientManager.disconnect()
            pair.serverManager.disconnect()
        }

        // Client pings "W3ABC" — not the server and not the client.
        try pair.clientChat.pingStation("W3ABC")

        // Wait briefly and assert that no ping response ever came back.
        try await Task.sleep(nanoseconds: 500_000_000)
        let responses = pair.clientDelegate.snapshot().pingResponses
        #expect(responses.isEmpty, "server should not have replied to a ping directed at W3ABC")

        // BUT the server SHOULD have seen the ping request as an observer,
        // because upstream fires the event regardless of destination.
        let requests = pair.serverDelegate.snapshot().pingRequests
        #expect(requests.count == 1)
        #expect(requests[0].from == "W9FYI")
        #expect(requests[0].to == "W3ABC")
    }

    @Test("Station status broadcast is received and decoded")
    func stationStatus() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.clientManager.disconnect()
            pair.serverManager.disconnect()
        }

        try pair.clientChat.advertise(status: .online, message: "K in Austin")

        // Poll until the server receives it.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            let updates = pair.serverDelegate.snapshot().statusUpdates
            if let first = updates.first {
                #expect(first.from == "W9FYI")
                #expect(first.status == .online)
                #expect(first.message == "K in Austin")
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        Issue.record("No status update received within 3 seconds")
    }

    @Test("Invalid status digit is ignored (not decoded)")
    func invalidStatusFrame() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.clientManager.disconnect()
            pair.serverManager.disconnect()
        }

        // Manually build a T_STATUS frame with a non-digit first byte.
        try pair.clientChat.send(frameType: ChatSession.T_STATUS,
                                  data: Data([UInt8(ascii: "X"), UInt8(ascii: "Y")]),
                                  dest: "CQCQCQ")

        try await Task.sleep(nanoseconds: 500_000_000)
        let updates = pair.serverDelegate.snapshot().statusUpdates
        #expect(updates.isEmpty, "a T_STATUS frame with non-digit first byte must be silently ignored")
    }

    // MARK: - SessionManager unit tests (no transport)

    @Test("Sessions get auto-assigned ids starting at 1")
    func sessionIdAssignment() {
        let transport = TCPLoopbackTransport(mode: .server(port: 0))
        let manager = SessionManager(callsign: "AI5OS", transport: transport)

        let s1 = StatelessSession(name: "a")
        let s2 = StatelessSession(name: "b")
        let s3 = StatelessSession(name: "c")
        manager.add(s1)
        manager.add(s2)
        manager.add(s3)

        #expect(s1.id == 1)
        #expect(s2.id == 2)
        #expect(s3.id == 3)
        #expect(s1.state == .open)
        #expect(manager.session(id: 2) === s2)
    }

    @Test("Explicit session id overrides auto-assignment")
    func explicitSessionId() {
        let transport = TCPLoopbackTransport(mode: .server(port: 0))
        let manager = SessionManager(callsign: "AI5OS", transport: transport)

        let s = StatelessSession(name: "chat")
        manager.add(s, id: 42)
        #expect(s.id == 42)
        #expect(manager.session(id: 42) === s)
    }

    @Test("Removed session is closed and no longer routable")
    func removeSession() {
        let transport = TCPLoopbackTransport(mode: .server(port: 0))
        let manager = SessionManager(callsign: "AI5OS", transport: transport)

        let s = StatelessSession(name: "chat")
        manager.add(s)
        let assignedId = s.id
        manager.remove(s)
        #expect(s.state == .closed)
        #expect(manager.session(id: assignedId) == nil)
        #expect(s.manager == nil)
    }

    @Test("onInboundFrame fires for every decoded inbound frame")
    func inboundFrameCallback() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.clientManager.disconnect()
            pair.serverManager.disconnect()
        }

        let framesSeen = FrameCounter()
        pair.serverManager.onInboundFrame = { frame in
            framesSeen.increment(for: frame.sStation)
        }

        try pair.clientChat.sendMessage("First")
        try pair.clientChat.sendMessage("Second")
        try pair.clientChat.sendMessage("Third")

        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(framesSeen.count(for: "W9FYI") == 3)
    }

    @Test("onUnroutedFrame fires when a frame targets an unregistered session")
    func unroutedFrameCallback() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.clientManager.disconnect()
            pair.serverManager.disconnect()
        }

        let unroutedCounter = FrameCounter()
        pair.serverManager.onUnroutedFrame = { frame in
            unroutedCounter.increment(for: "\(frame.session)")
        }

        // Client uses a session id that the server never registered (99).
        let rogueSession = StatelessSession(name: "rogue")
        pair.clientManager.add(rogueSession, id: 99)
        try rogueSession.write("unrouted payload")

        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(unroutedCounter.count(for: "99") == 1)
    }
}

// MARK: - Supporting helpers

/// Thread-safe counter used in the inbound-frame callback tests.
final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var byKey: [String: Int] = [:]
    func increment(for key: String) {
        lock.lock(); defer { lock.unlock() }
        byKey[key, default: 0] += 1
    }
    func count(for key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return byKey[key] ?? 0
    }
}
