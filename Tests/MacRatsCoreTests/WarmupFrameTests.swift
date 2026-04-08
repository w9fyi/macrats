import Foundation
import Testing
@testable import MacRatsCore

/// Tests for the warmup frame behavior added in session 8A.
///
/// D-Rats transmits a warmup frame (type 254, sStation/dStation "!",
/// payload [0x01]*warmup_length, uncompressed) before the first real
/// DDT2 frame after a period of idle, to wake up the receiving radio's
/// DSP / power-save mode. MacRats must match this behavior exactly to
/// interoperate with real D-Rats peers over the radio.
///
/// These tests:
/// 1. Verify the warmup frame is emitted on first outbound send
/// 2. Verify back-to-back sends within the timeout DON'T re-warmup
/// 3. Verify sends AFTER the timeout trigger a fresh warmup
/// 4. Verify the warmup frame's wire contents exactly
/// 5. Verify disabling warmup (timeout = 0) actually disables it
/// 6. Verify inbound warmup frames are filtered before delegates fire
/// 7. Verify the warmup "!" station never hits the heard-stations list
/// 8. Verify force delay (positive value) actually sleeps
///
/// Marked .serialized because tests that exercise the real transport
/// use random TCP ports — same pattern as ChatSessionTests and
/// MacRatsAppModelTests.
@Suite(.serialized)
struct WarmupFrameTests {

    // MARK: - Helpers

    /// Intercept outbound bytes on the wire via the wireLogHandler hook.
    /// Returns the bytes written to transport in order, with direction.
    final class WireCapture: @unchecked Sendable {
        struct Entry: Sendable {
            let direction: String
            let data: Data
        }
        private let lock = NSLock()
        private var entries: [Entry] = []

        func handler() -> @Sendable (String, Data) -> Void {
            { [weak self] direction, data in
                self?.lock.lock()
                self?.entries.append(Entry(direction: direction, data: data))
                self?.lock.unlock()
            }
        }

        func tx() -> [Data] {
            lock.lock(); defer { lock.unlock() }
            return entries.filter { $0.direction == "TX" }.map { $0.data }
        }

        func all() -> [Entry] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll()
        }
    }

    /// A stub transport that records everything written to it and
    /// exposes a way to inject inbound bytes. No real network / serial
    /// device involved.
    final class StubTransport: RadioTransport, @unchecked Sendable {
        let displayName = "StubTransport"
        private let stateLock = NSLock()
        private var _status: TransportStatus = .disconnected
        public var status: TransportStatus {
            stateLock.lock(); defer { stateLock.unlock() }
            return _status
        }

        private var delegate: RadioTransportDelegate?

        private let outboundLock = NSLock()
        private var _outbound: [Data] = []
        var outbound: [Data] {
            outboundLock.lock(); defer { outboundLock.unlock() }
            return _outbound
        }

        func setDelegate(_ delegate: RadioTransportDelegate?) {
            stateLock.lock(); defer { stateLock.unlock() }
            self.delegate = delegate
        }

        func connect() throws {
            stateLock.lock(); _status = .connected; let d = delegate; stateLock.unlock()
            d?.transport(self, didChangeStatus: .connected)
        }

        func disconnect() {
            stateLock.lock(); _status = .disconnected; let d = delegate; stateLock.unlock()
            d?.transport(self, didChangeStatus: .disconnected)
        }

        func send(_ data: Data) throws {
            outboundLock.lock(); _outbound.append(data); outboundLock.unlock()
        }

        /// Inject bytes as if they arrived from the radio.
        func injectInbound(_ data: Data) {
            stateLock.lock(); let d = delegate; stateLock.unlock()
            d?.transport(self, didReceive: data)
        }
    }

    /// Build a manager with a stub transport in the requested tuning
    /// profile. Caller is responsible for calling `connect()` if
    /// they need the transport connected.
    private func makeManager(tuning: SessionManager.WireTuning) -> (manager: SessionManager,
                                                                     transport: StubTransport,
                                                                     chat: ChatSession,
                                                                     capture: WireCapture) {
        let transport = StubTransport()
        let manager = SessionManager(callsign: "AI5OS", transport: transport, wireTuning: tuning)
        let chat = ChatSession()
        manager.add(chat, id: 1)
        let capture = WireCapture()
        manager.wireLogHandler = capture.handler()
        try? transport.connect()
        return (manager, transport, chat, capture)
    }

    /// Extract the bytes inside the DDT2 envelope (between `[SOB]` and
    /// `[EOB]`) and yDecode them back into a raw DDT2 frame payload.
    /// Returns the decoded DDT2Frame. Used to assert on wire contents.
    private func decodeWireFrame(_ wire: Data) throws -> DDT2Frame {
        try DDT2EncodedFrame.unpack(wire)
    }

    // MARK: - 1. First-send emits a warmup frame

    @Test("First outbound send emits a warmup frame before the real frame")
    func firstSendEmitsWarmup() throws {
        let bundle = makeManager(tuning: .radio)
        try bundle.chat.sendMessage("hello")

        // Two frames should have hit the transport: [warmup, real].
        let outbound = bundle.transport.outbound
        #expect(outbound.count == 2, "expected 2 frames on wire (warmup + real), got \(outbound.count)")

        // First frame must decode as a warmup: type 254, s/d = "!".
        let warmup = try decodeWireFrame(outbound[0])
        #expect(warmup.type == SessionManager.warmupFrameType)
        #expect(warmup.sStation == "!")
        #expect(warmup.dStation == "!")
        #expect(warmup.compress == false)
        // Payload should be 16 bytes of 0x01 (default radio profile).
        #expect(warmup.data == Data(repeating: 0x01, count: 16))

        // Second frame must be the real chat message.
        let real = try decodeWireFrame(outbound[1])
        #expect(real.type == ChatSession.T_DEF)
        #expect(real.sStation == "AI5OS")
        #expect(String(decoding: real.data, as: UTF8.self) == "hello")
    }

    // MARK: - 2. Back-to-back sends within the timeout do NOT re-warmup

    @Test("Second send within warmup timeout does not emit another warmup")
    func secondSendWithinTimeoutSkipsWarmup() throws {
        let bundle = makeManager(tuning: .radio)
        try bundle.chat.sendMessage("first")
        // Immediately send another — much less than the 3-second
        // warmup timeout. Should NOT re-warmup.
        try bundle.chat.sendMessage("second")

        let outbound = bundle.transport.outbound
        // Expected: warmup, first, second. That's 3 frames total.
        #expect(outbound.count == 3, "expected 3 frames (warmup + 2 reals), got \(outbound.count)")

        let first = try decodeWireFrame(outbound[0])
        #expect(first.type == SessionManager.warmupFrameType)
        let second = try decodeWireFrame(outbound[1])
        #expect(second.type == ChatSession.T_DEF)
        #expect(String(decoding: second.data, as: UTF8.self) == "first")
        let third = try decodeWireFrame(outbound[2])
        #expect(third.type == ChatSession.T_DEF)
        #expect(String(decoding: third.data, as: UTF8.self) == "second")
    }

    // MARK: - 3. Send after the timeout triggers a fresh warmup

    @Test("Send after warmup timeout expires triggers a fresh warmup")
    func sendAfterTimeoutEmitsWarmup() throws {
        // Use a tiny 50ms timeout so the test stays fast.
        let tuning = SessionManager.WireTuning(warmupLength: 8,
                                                warmupTimeoutSeconds: 0.05,
                                                forceDelaySeconds: 0)
        let bundle = makeManager(tuning: tuning)

        try bundle.chat.sendMessage("alpha")
        // Wait past the timeout.
        Thread.sleep(forTimeInterval: 0.08)
        try bundle.chat.sendMessage("beta")

        let outbound = bundle.transport.outbound
        // Expected: warmup, alpha, warmup, beta = 4 frames.
        #expect(outbound.count == 4, "expected 4 frames (2 warmups + 2 reals), got \(outbound.count)")

        let frame0 = try decodeWireFrame(outbound[0])
        let frame2 = try decodeWireFrame(outbound[2])
        #expect(frame0.type == SessionManager.warmupFrameType)
        #expect(frame2.type == SessionManager.warmupFrameType)
    }

    // MARK: - 4. Warmup frame wire contents are exact

    @Test("Warmup frame payload is exactly [0x01] * warmupLength")
    func warmupFramePayloadIsExactBytes() throws {
        // Use a non-default length to verify we honor the config.
        let tuning = SessionManager.WireTuning(warmupLength: 24,
                                                warmupTimeoutSeconds: 3,
                                                forceDelaySeconds: 0)
        let bundle = makeManager(tuning: tuning)
        try bundle.chat.sendMessage("test")

        let warmup = try decodeWireFrame(bundle.transport.outbound[0])
        #expect(warmup.data.count == 24)
        #expect(warmup.data == Data(repeating: 0x01, count: 24))
    }

    // MARK: - 5. Setting timeout = 0 disables warmup entirely

    @Test("Setting warmupTimeoutSeconds to 0 disables warmup (NET profile)")
    func warmupDisabledWhenTimeoutZero() throws {
        let bundle = makeManager(tuning: .net)
        try bundle.chat.sendMessage("hi")
        try bundle.chat.sendMessage("there")

        let outbound = bundle.transport.outbound
        // Expected: just the 2 real frames, no warmup.
        #expect(outbound.count == 2)
        for wire in outbound {
            let frame = try decodeWireFrame(wire)
            #expect(frame.type != SessionManager.warmupFrameType,
                    "NET profile should not emit warmup frames, got type \(frame.type)")
        }
    }

    @Test("Setting warmupLength to 0 also disables warmup")
    func warmupDisabledWhenLengthZero() throws {
        let tuning = SessionManager.WireTuning(warmupLength: 0,
                                                warmupTimeoutSeconds: 3,
                                                forceDelaySeconds: 0)
        let bundle = makeManager(tuning: tuning)
        try bundle.chat.sendMessage("hi")

        let outbound = bundle.transport.outbound
        #expect(outbound.count == 1, "warmupLength=0 should suppress warmup")
        let frame = try decodeWireFrame(outbound[0])
        #expect(frame.type == ChatSession.T_DEF)
    }

    // MARK: - 6. Inbound warmup frames are filtered before delegates fire

    @Test("Inbound warmup frame is silently dropped (no delegate callbacks)")
    func inboundWarmupFrameFiltered() throws {
        let bundle = makeManager(tuning: .radio)

        // Track whether the chat delegate ever sees anything.
        final class Recorder: ChatSession.Delegate, @unchecked Sendable {
            let lock = NSLock()
            var calls: [String] = []
            func chatSession(_ session: ChatSession, didReceiveMessage text: String, from sStation: String, to dStation: String) {
                lock.lock(); calls.append("message"); lock.unlock()
            }
            func chatSession(_ session: ChatSession, didReceivePingRequest from: String, to dStation: String) {
                lock.lock(); calls.append("pingReq"); lock.unlock()
            }
            func chatSession(_ session: ChatSession, didReceivePingResponse from: String, to dStation: String, replyText: String) {
                lock.lock(); calls.append("pingRsp"); lock.unlock()
            }
            func chatSession(_ session: ChatSession, didReceiveEchoRequest from: String, to dStation: String, payload: Data) {
                lock.lock(); calls.append("echoReq"); lock.unlock()
            }
            func chatSession(_ session: ChatSession, didReceiveEchoResponse from: String, to dStation: String, payload: Data) {
                lock.lock(); calls.append("echoRsp"); lock.unlock()
            }
            func chatSession(_ session: ChatSession, didReceiveStationStatus from: String, status: StationStatus, message: String) {
                lock.lock(); calls.append("status"); lock.unlock()
            }
            func chatSession(_ session: ChatSession, didReceiveGPSFix fix: GPSBeacon.Fix) {
                lock.lock(); calls.append("gpsFix"); lock.unlock()
            }
            func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return calls }
        }
        let recorder = Recorder()
        bundle.chat.delegate = recorder

        // Build a warmup frame and inject its wire bytes as if the
        // radio sent it.
        var warmup = DDT2Frame()
        warmup.seq = 0
        warmup.session = 0
        warmup.type = SessionManager.warmupFrameType
        warmup.sStation = "!"
        warmup.dStation = "!"
        warmup.data = Data(repeating: 0x01, count: 16)
        warmup.compress = false
        let wire = DDT2EncodedFrame.pack(warmup)
        bundle.transport.injectInbound(wire)

        // Chat delegate should have received nothing.
        #expect(recorder.snapshot().isEmpty)
    }

    // MARK: - 7. Heard-stations tracker never sees "!" from warmup frames

    @Test("Inbound warmup frame does NOT add '!' to heard stations")
    func inboundWarmupDoesNotPopulateStations() throws {
        let bundle = makeManager(tuning: .radio)

        // Track onInboundFrame callbacks via a thread-safe reference
        // type so the Sendable closure doesn't need to mutate a var.
        final class StationSet: @unchecked Sendable {
            private let lock = NSLock()
            private var stations: Set<String> = []
            func insert(_ s: String) {
                lock.lock(); defer { lock.unlock() }
                stations.insert(s)
            }
            func snapshot() -> Set<String> {
                lock.lock(); defer { lock.unlock() }
                return stations
            }
        }
        let seen = StationSet()
        bundle.manager.onInboundFrame = { frame in
            seen.insert(frame.sStation)
        }

        // Inject a warmup frame.
        var warmup = DDT2Frame()
        warmup.type = SessionManager.warmupFrameType
        warmup.sStation = "!"
        warmup.dStation = "!"
        warmup.data = Data(repeating: 0x01, count: 16)
        warmup.compress = false
        bundle.transport.injectInbound(DDT2EncodedFrame.pack(warmup))

        #expect(seen.snapshot().isEmpty, "warmup frame should never trigger onInboundFrame")
    }

    // MARK: - 8. Force delay (positive value) actually sleeps

    @Test("Positive forceDelaySeconds sleeps before sending")
    func forceDelayPositiveSleeps() throws {
        let tuning = SessionManager.WireTuning(warmupLength: 0,      // no warmup
                                                warmupTimeoutSeconds: 0,
                                                forceDelaySeconds: 0.1)
        let bundle = makeManager(tuning: tuning)

        let start = Date()
        try bundle.chat.sendMessage("delayed")
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed >= 0.09, "force delay 0.1s should take at least 0.09s (got \(elapsed))")
        #expect(elapsed < 0.5, "force delay 0.1s should NOT take longer than 0.5s (got \(elapsed))")
    }

    // MARK: - Wire-log hook coverage

    @Test("wireLogHandler fires TX for outbound warmup and real frames")
    func wireLogFiresForOutbound() throws {
        let bundle = makeManager(tuning: .radio)
        try bundle.chat.sendMessage("hi")

        let entries = bundle.capture.all()
        // Expected: two TX entries (warmup + real).
        let txEntries = entries.filter { $0.direction == "TX" }
        #expect(txEntries.count == 2)
    }

    @Test("wireLogHandler fires RX for inbound raw bytes")
    func wireLogFiresForInbound() throws {
        let bundle = makeManager(tuning: .radio)

        // Inject arbitrary bytes directly — doesn't have to be a
        // valid frame. The RX log hook should fire regardless of
        // decoding success.
        bundle.transport.injectInbound(Data("raw bytes".utf8))

        let entries = bundle.capture.all()
        let rxEntries = entries.filter { $0.direction == "RX" }
        #expect(rxEntries.count == 1)
        #expect(rxEntries[0].data == Data("raw bytes".utf8))
    }
}
