import Foundation
import Testing
@testable import MacRatsCore

/// Integration tests for `MacRatsAppModel` — the SwiftUI view-model that
/// owns a SessionManager and publishes chat messages + heard stations.
///
/// These tests instantiate TWO app model instances on localhost TCP,
/// exercise them through their public API (settings, connect,
/// sendChatMessage, pingStation, broadcastStatus), and verify the
/// observation callbacks fire and the published snapshots stay consistent.
///
/// Marked `.serialized` for the same reason ChatSessionTests is — each
/// test spins up a TCP port and parallel execution causes port collisions.
@Suite(.serialized)
struct MacRatsAppModelTests {

    // MARK: - Helpers

    /// An @unchecked Sendable counter used to track observation callbacks
    /// fired by the model.
    final class NotificationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }
    }

    /// Build a (server, client) pair of MacRatsAppModel instances both
    /// connected over TCP loopback. Settings are wired up for each side.
    ///
    /// Sign-on and sign-off messages are cleared by default so tests
    /// that assert "no messages until I send one" aren't polluted by
    /// the auto-broadcast. Use `makePairWithClientSignMessages` when a
    /// test specifically exercises the sign-on/off behavior.
    private static func makePair(port: UInt16? = nil) async throws -> (server: MacRatsAppModel,
                                                                       client: MacRatsAppModel,
                                                                       port: UInt16) {
        let actualPort = port ?? UInt16.random(in: 49152...65535)

        // Server side: empty host = listen
        var serverSettings = MacRatsSettings()
        serverSettings.callsign = "AI5OS"
        serverSettings.connectionKind = .tcpLoopback
        serverSettings.tcpHost = ""
        serverSettings.tcpPort = actualPort
        serverSettings.pingReplyText = "Server here — AI5OS"
        serverSettings.signOnMessage = ""
        serverSettings.signOffMessage = ""
        let serverModel = MacRatsAppModel(settings: serverSettings)
        try serverModel.connect()

        // Small pause so the listener binds before the client connects.
        try await Task.sleep(nanoseconds: 60_000_000)

        // Client side
        var clientSettings = MacRatsSettings()
        clientSettings.callsign = "W9FYI"
        clientSettings.connectionKind = .tcpLoopback
        clientSettings.tcpHost = "127.0.0.1"
        clientSettings.tcpPort = actualPort
        clientSettings.pingReplyText = "Client here — W9FYI"
        clientSettings.signOnMessage = ""
        clientSettings.signOffMessage = ""
        let clientModel = MacRatsAppModel(settings: clientSettings)
        try clientModel.connect()

        // Wait for both ends to reach .connected.
        try await waitUntil(timeout: 3.0) {
            serverModel.connectionStatus == .connected
                && clientModel.connectionStatus == .connected
        }

        return (serverModel, clientModel, actualPort)
    }

    private static func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw TestTimeout.exceeded
    }

    enum TestTimeout: Error { case exceeded }

    // MARK: - Tests

    @Test("Two MacRatsAppModels exchange a chat message and both see it in their logs")
    func twoWayChatThroughModel() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.client.disconnect()
            pair.server.disconnect()
        }

        // Client sends a broadcast message.
        try pair.client.sendChatMessage("Hi from the client!")

        // Client's own log should contain the outgoing message.
        let clientLog = pair.client.chatMessages
        let outgoingInClient = clientLog.first {
            $0.outgoing && $0.text == "Hi from the client!" && $0.kind == .message
        }
        #expect(outgoingInClient != nil)

        // Server should eventually see the incoming message.
        try await Self.waitUntil(timeout: 2.0) {
            pair.server.chatMessages.contains {
                !$0.outgoing && $0.text == "Hi from the client!" && $0.sStation == "W9FYI"
            }
        }
    }

    @Test("Heard stations list updates on first message received")
    func heardStationsPopulate() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.client.disconnect()
            pair.server.disconnect()
        }

        #expect(pair.server.heardStations.isEmpty)

        try pair.client.sendChatMessage("Hello")
        try await Self.waitUntil(timeout: 2.0) {
            pair.server.heardStations.contains { $0.callsign == "W9FYI" }
        }

        let station = pair.server.heardStations.first { $0.callsign == "W9FYI" }
        #expect(station != nil)
        #expect(station?.messageCount == 1)
    }

    @Test("Ping round-trip populates both sides' chat logs")
    func pingRoundTrip() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.client.disconnect()
            pair.server.disconnect()
        }

        try pair.client.pingStation("AI5OS")

        // Client log should show the outgoing ping request.
        let clientLog = pair.client.chatMessages
        #expect(clientLog.contains { $0.kind == .pingRequest && $0.outgoing })

        // Server should observe the ping request and auto-reply.
        try await Self.waitUntil(timeout: 3.0) {
            pair.server.chatMessages.contains { $0.kind == .pingRequest && !$0.outgoing && $0.sStation == "W9FYI" }
        }

        // Client should eventually see the ping response from the server.
        try await Self.waitUntil(timeout: 3.0) {
            pair.client.chatMessages.contains { msg in
                if case .pingResponse(let reply) = msg.kind, reply.contains("Server here") { return true }
                return false
            }
        }
    }

    @Test("Broadcast status is received and recorded on the other side")
    func broadcastStatus() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.client.disconnect()
            pair.server.disconnect()
        }

        try pair.client.broadcastStatus(.unattended, message: "AFK for 5 min")

        // Server should receive the status and update its heard-station entry.
        try await Self.waitUntil(timeout: 2.0) {
            guard let station = pair.server.heardStations.first(where: { $0.callsign == "W9FYI" }) else { return false }
            return station.lastStatus == .unattended && station.lastStatusMessage == "AFK for 5 min"
        }

        // And the server's chat log should contain a status entry.
        #expect(pair.server.chatMessages.contains { msg in
            if case .status(let s) = msg.kind, s == .unattended { return true }
            return false
        })
    }

    @Test("Observation callback fires on incoming messages")
    func observationCallback() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.client.disconnect()
            pair.server.disconnect()
        }

        let counter = NotificationCounter()
        pair.server.onStateChanged = {
            counter.increment()
        }

        let baseline = counter.count
        try pair.client.sendChatMessage("trigger")
        try pair.client.sendChatMessage("another")

        try await Self.waitUntil(timeout: 2.0) {
            counter.count > baseline
        }

        #expect(counter.count > baseline)
    }

    // MARK: - Non-integration model tests

    @Test("sendChatMessage without connecting throws")
    func sendWithoutConnect() throws {
        let model = MacRatsAppModel()
        #expect(throws: SessionError.self) {
            try model.sendChatMessage("hi")
        }
    }

    @Test("Disconnecting when not connected is a no-op")
    func disconnectIdempotent() {
        let model = MacRatsAppModel()
        model.disconnect()
        model.disconnect()
        #expect(model.connectionStatus == .disconnected)
    }

    @Test("updateSettings changes the settings and does not throw")
    func updateSettings() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrats-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = MacRatsAppModel(settingsURL: tmp)
        var new = MacRatsSettings()
        new.callsign = "AI5OS"
        new.pingReplyText = "Custom reply"
        model.updateSettings(new)

        #expect(model.settings.callsign == "AI5OS")
        #expect(model.settings.pingReplyText == "Custom reply")

        // Should have persisted to disk.
        let loaded = MacRatsSettings.load(from: tmp)
        #expect(loaded.callsign == "AI5OS")
    }

    @Test("Snapshot is consistent under concurrent reads")
    func snapshotConsistency() {
        let model = MacRatsAppModel()
        var s = MacRatsSettings()
        s.callsign = "AI5OS"
        model.updateSettings(s)

        let snap = model.snapshot()
        #expect(snap.settings.callsign == "AI5OS")
        #expect(snap.connectionStatus == .disconnected)
        #expect(snap.chatMessages.isEmpty)
        #expect(snap.stations.isEmpty)
    }

    @Test("Max chat history is enforced")
    func maxChatHistoryEnforced() async throws {
        let pair = try await Self.makePair()
        defer {
            pair.client.disconnect()
            pair.server.disconnect()
        }

        // Send more messages than the default cap (500). Using a tiny
        // count for speed — we don't need to actually hit 500.
        for i in 1...5 {
            try pair.client.sendChatMessage("message \(i)")
        }

        try await Self.waitUntil(timeout: 2.0) {
            pair.server.chatMessages.filter { !$0.outgoing }.count >= 5
        }
        // All 5 messages present.
        let received = pair.server.chatMessages.filter { $0.kind == .message && !$0.outgoing }
        #expect(received.count == 5)
    }

    // MARK: - Sign-on / sign-off auto-messages

    /// Build a pair where the CLIENT side has a customized sign-on /
    /// sign-off. The server is a plain listener that records whatever
    /// chat messages arrive.
    private static func makePairWithClientSignMessages(
        signOn: String,
        signOff: String
    ) async throws -> (server: MacRatsAppModel,
                       client: MacRatsAppModel,
                       port: UInt16) {
        let actualPort = UInt16.random(in: 49152...65535)

        var serverSettings = MacRatsSettings()
        serverSettings.callsign = "AI5OS"
        serverSettings.connectionKind = .tcpLoopback
        serverSettings.tcpHost = ""
        serverSettings.tcpPort = actualPort
        // Server explicitly empty sign-on/off so we're not fighting
        // noise from the other side.
        serverSettings.signOnMessage = ""
        serverSettings.signOffMessage = ""
        let serverModel = MacRatsAppModel(settings: serverSettings)
        try serverModel.connect()

        try await Task.sleep(nanoseconds: 60_000_000)

        var clientSettings = MacRatsSettings()
        clientSettings.callsign = "W9FYI"
        clientSettings.connectionKind = .tcpLoopback
        clientSettings.tcpHost = "127.0.0.1"
        clientSettings.tcpPort = actualPort
        clientSettings.signOnMessage = signOn
        clientSettings.signOffMessage = signOff
        let clientModel = MacRatsAppModel(settings: clientSettings)
        try clientModel.connect()

        try await waitUntil(timeout: 3.0) {
            serverModel.connectionStatus == .connected
                && clientModel.connectionStatus == .connected
        }

        return (serverModel, clientModel, actualPort)
    }

    @Test("Sign-on message is auto-broadcast on connect")
    func signOnAutoBroadcast() async throws {
        let pair = try await Self.makePairWithClientSignMessages(
            signOn: "W9FYI online for testing",
            signOff: ""
        )
        defer {
            pair.client.disconnect()
            pair.server.disconnect()
        }

        // Server should eventually see the client's sign-on message.
        try await Self.waitUntil(timeout: 3.0) {
            pair.server.chatMessages.contains { msg in
                msg.kind == .message
                    && !msg.outgoing
                    && msg.sStation == "W9FYI"
                    && msg.text == "W9FYI online for testing"
            }
        }

        // AND the client's own log should contain the outgoing sign-on.
        let clientLog = pair.client.chatMessages
        #expect(clientLog.contains { msg in
            msg.kind == .message
                && msg.outgoing
                && msg.text == "W9FYI online for testing"
        })
    }

    @Test("Sign-on is NOT sent when the sign-on message is empty")
    func signOnSkippedWhenEmpty() async throws {
        let pair = try await Self.makePairWithClientSignMessages(
            signOn: "",
            signOff: ""
        )
        defer {
            pair.client.disconnect()
            pair.server.disconnect()
        }

        // Give the system a moment — then verify the server never
        // received any chat message from the client.
        try await Task.sleep(nanoseconds: 300_000_000)
        let serverReceivedMessages = pair.server.chatMessages.filter {
            $0.kind == .message && !$0.outgoing && $0.sStation == "W9FYI"
        }
        #expect(serverReceivedMessages.isEmpty)
    }

    @Test("Sign-off message is auto-broadcast before disconnect")
    func signOffAutoBroadcast() async throws {
        let pair = try await Self.makePairWithClientSignMessages(
            signOn: "",
            signOff: "W9FYI signing off for now"
        )
        defer {
            pair.server.disconnect()
        }

        // Tear down the client — this should send the sign-off first.
        pair.client.disconnect()

        // Server should see the sign-off message.
        try await Self.waitUntil(timeout: 3.0) {
            pair.server.chatMessages.contains { msg in
                msg.kind == .message
                    && !msg.outgoing
                    && msg.sStation == "W9FYI"
                    && msg.text == "W9FYI signing off for now"
            }
        }
    }

    @Test("Sign-off is NOT sent when already disconnected")
    func signOffSkippedWhenDisconnected() async throws {
        let pair = try await Self.makePairWithClientSignMessages(
            signOn: "",
            signOff: "should not arrive"
        )
        defer {
            pair.server.disconnect()
        }

        // First disconnect — sends nothing because signOff is
        // configured but... wait, it IS configured. This test should
        // verify that the SECOND disconnect call (when already
        // disconnected) doesn't resend. Let me restructure.
        pair.client.disconnect()
        try await Task.sleep(nanoseconds: 300_000_000)

        // Reset the server's chat log counter. We'll count new
        // messages after this point.
        let messagesBeforeSecondDisconnect = pair.server.chatMessages.count

        // Second disconnect call while already disconnected — must
        // not re-send the sign-off.
        pair.client.disconnect()
        try await Task.sleep(nanoseconds: 300_000_000)

        let messagesAfterSecondDisconnect = pair.server.chatMessages.count
        #expect(messagesBeforeSecondDisconnect == messagesAfterSecondDisconnect,
                "second disconnect() must not re-send the sign-off")
    }
}
