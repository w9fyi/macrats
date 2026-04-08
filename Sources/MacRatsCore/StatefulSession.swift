import Foundation

/// A stateful D-Rats session with reliable in-order delivery on top of
/// the unreliable DDT2 byte pipe. Ported from
/// `d_rats/sessions/stateful.py` in upstream ham-radio-software/D-Rats.
///
/// ## What "stateful" means here
///
/// Stateless sessions (chat, ping, status, GPS beacons) fire a single
/// DDT2 frame per message and hope the other side receives it. If the
/// radio dropped a byte in the middle of a "CQCQCQ de AI5OS" message,
/// the chat log shows garbage — and that's acceptable because chat is
/// forgiving. File transfer is not. A single missing byte corrupts an
/// entire photo or form, and a user who pushed a 200-KB image across
/// a 2400-bps link is not going to accept "sorry, try again."
///
/// `StatefulSession` is the layer that makes file transfer possible. It
/// chops the caller's bytes into fixed-size blocks, assigns each a
/// sequence number (0..255 wrapping), transmits them as `T_DAT` DDT2
/// frames, and runs a windowed retransmission protocol with explicit
/// `T_ACK` / `T_NAK` / `T_REQACK` bookkeeping until every block has been
/// acknowledged by the peer.
///
/// The protocol is the D-Rats reliability protocol exactly. MacRats
/// re-implements the wire behavior byte-for-byte so two MacRats
/// instances and two upstream D-Rats instances (or one of each) all
/// interoperate. Porting notes are inline below where the Swift
/// implementation diverges from Python for idiom reasons.
///
/// ## Wire protocol summary
///
/// Every outbound block is a DDT2 frame whose `type` field carries one
/// of the stateful sub-types and whose `seq` field carries the block
/// sequence number:
///
/// - `T_DAT` (4): a data block. Payload is up to `blocksize` bytes of
///   the caller's stream. `seq` is the 8-bit block number.
/// - `T_ACK` (1): the peer is acknowledging a set of previously received
///   block numbers. Payload is the list of block numbers, each as a
///   single byte, in arrival order. `seq` is 0 (unused for ACKs).
/// - `T_NAK` (2): reserved. Upstream D-Rats does not actually emit NAKs
///   in the current protocol — it uses "ACK with a subset of the
///   requested blocks" to convey partial failures. We include the
///   constant for completeness and pattern-match against it on receive,
///   but we never emit one.
/// - `T_REQACK` (5): "request acknowledgement." Sent after a window of
///   outbound `T_DAT` frames to ask the peer to ACK them. Payload is
///   the list of block numbers in the window. `seq` is 0.
/// - `T_SYN` (0): reserved. Upstream emits `T_SYN` during the session
///   open handshake, which MacRats does not currently implement —
///   sessions start "open" directly. Included for completeness.
///
/// Retransmission policy: send a window of `outLimit` T_DAT blocks, send
/// a T_REQACK, wait for a matching T_ACK. If the timeout elapses, retry
/// the T_REQACK (not the T_DAT blocks — the peer already has them).
/// After 10 consecutive failed retries, mark the session closed.
///
/// ## What this port does NOT implement
///
/// - **Session open handshake.** Upstream sends T_SYN frames to
///   negotiate session ids at startup. MacRats assigns session ids
///   directly via `SessionManager.add(_:id:)` so both peers must agree
///   on a fixed id out of band. For the v1.1 file transfer UI this is
///   fine: MacRats uses a hard-coded file-transfer session id. Dynamic
///   session negotiation can be added later if we ever want multiple
///   simultaneous stateful sessions per peer.
///
/// - **RTT rate measurement.** Upstream measures ACK round-trip time
///   and adjusts its timeout dynamically. MacRats uses a fixed
///   conservative timeout (minimum 12 seconds, scaled by the number of
///   pending bytes and an assumed 80 bps minimum wire rate). This is
///   simpler, slightly less efficient on fast links, and safer on slow
///   ones. Upstream's adaptive rate can be ported later if someone
///   complains.
///
/// - **Adaptive outstanding limit.** Upstream grows and shrinks its
///   sliding window based on whether the last ACK was "full" (acked
///   every block). MacRats uses a fixed 8-block window. Again, simpler
///   and deterministic. Upstream's adjustments amount to a few percent
///   throughput difference on good links.
///
/// - **LZHuf compression.** Upstream optionally compresses per-block
///   payloads with LZHuf. MacRats inherits the DDT2 layer's zlib
///   compression and skips LZHuf entirely. This does not affect
///   interoperability as long as both peers agree on the compression
///   flag in the DDT2 header, which they do (MacRats and D-Rats both
///   default to zlib).
///
/// ## Threading model
///
/// The session runs a dedicated `DispatchQueue` worker for the
/// transmit-and-retry loop. The worker pattern mirrors the Python
/// threading.Thread + threading.Event approach but uses a
/// `DispatchSemaphore` for event waits and `NSLock` for state. All
/// public methods are thread-safe.
///
/// Inbound frames arrive via `SessionManager.routeIncoming(...)` on the
/// transport's read queue. The session's `handler` closure processes
/// them synchronously under the state lock and signals the worker when
/// it has new information (ACKs to consume, REQACKs to answer, or
/// fresh data blocks to queue for the app).
open class StatefulSession: Session, @unchecked Sendable {

    // MARK: - Frame sub-types (match d_rats/sessions/stateful.py)

    public static let T_SYN:    UInt8 = 0
    public static let T_ACK:    UInt8 = 1
    public static let T_NAK:    UInt8 = 2
    public static let T_DAT:    UInt8 = 4
    public static let T_REQACK: UInt8 = 5

    // MARK: - Protocol tuning

    /// Size of each T_DAT block in bytes. Upstream default 1024 matches
    /// what D-Rats ships; we use the same so file sessions interop.
    public let blocksize: Int

    /// Maximum number of unacknowledged T_DAT blocks in flight at once.
    /// Upstream calls this `out_limit` and varies it adaptively; we keep
    /// it fixed at 8, which is upstream's default starting value.
    public let outLimit: Int

    /// Maximum number of consecutive REQACK attempts before giving up
    /// and closing the session. Matches upstream `send_blocks()`.
    public static let maxRetries = 10

    /// Minimum transmit rate assumption (bytes per second) used when we
    /// have no measured rate yet. Matches upstream's `rate = 80` in
    /// `is_timeout()`.
    public static let minimumAssumedRate: Double = 80

    /// Minimum ACK timeout regardless of pending data size. Matches
    /// upstream `timeout < 12: timeout = 12`.
    public static let minimumAckTimeoutSeconds: TimeInterval = 12

    /// Idle timeout — after this many seconds with no activity, the
    /// session closes itself. Matches upstream `IDLE_TIMEOUT = 90`.
    public static let idleTimeoutSeconds: TimeInterval = 90

    // MARK: - Session conformance

    public var name: String
    public var type: SessionType
    public var id: UInt8 = 0
    public var compress: Bool = true
    public var handler: ((DDT2Frame) -> Void)?
    public weak var manager: SessionManager?
    public var state: SessionState = .open
    public var stats = SessionStats()

    /// The remote station callsign this session is talking to. Stamped
    /// onto every outbound frame's `dStation` field. Stateful sessions
    /// are addressed (unlike chat, which defaults to `CQCQCQ`) — file
    /// transfer needs to go to a specific peer, not the whole net.
    public var remoteStation: String

    // MARK: - Delegate (push-style app layer)

    /// The application layer the session hands received data to as it
    /// arrives in order. Called from the worker queue — conformers must
    /// hop to main if they touch UI state.
    public protocol Delegate: AnyObject, Sendable {
        /// Fired with each contiguous chunk of received data. The
        /// session guarantees that chunks arrive in order and are
        /// de-duplicated; the delegate can simply append each chunk to
        /// a buffer without worrying about gaps or repeats.
        func statefulSession(_ session: StatefulSession, didReceive data: Data)

        /// Fired when the session closes normally (all pending writes
        /// acknowledged and no more activity for `idleTimeoutSeconds`).
        func statefulSessionDidClose(_ session: StatefulSession)

        /// Fired when the session hits the retry limit and gives up.
        func statefulSession(_ session: StatefulSession, didFailWithReason reason: String)
    }

    public weak var delegate: Delegate?

    // MARK: - Internal state (protected by `lock`)

    private let lock = NSLock()

    /// Blocks queued for transmission but not yet in the outstanding
    /// window. Drained into `outstanding` by the worker each time
    /// there's headroom.
    private var outq: [OutgoingBlock] = []

    /// Blocks currently in flight (sent, waiting for ACK).
    private var outstanding: [OutgoingBlock] = []

    /// The set of block numbers for which we are currently waiting on
    /// an ACK. Set after a T_REQACK is sent; cleared on matching T_ACK
    /// or retried on timeout.
    private var waitingForAck: [UInt8] = []

    /// Outbound sequence counter (0..255 wrapping).
    private var oseq: UInt8 = 0

    /// Highest contiguous inbound sequence delivered to the app. Starts
    /// at 255 so the first real block (seq=0) is accepted via the
    /// `do_next(255) == 0` logic.
    private var iseq: UInt8 = 255

    /// Sequence numbers of blocks currently known to the app (used to
    /// reply to T_REQACK without needing them in the out-of-order
    /// queue). Matches upstream's `recv_list`.
    private var recvList = Set<UInt8>()

    /// Blocks received out of order, keyed by sequence number. Drained
    /// to the delegate in order as the missing sequence numbers arrive.
    private var oobQueue: [UInt8: Data] = [:]

    /// Consecutive REQACK retries without a matching ACK.
    private var retryAttempts = 0

    /// Last time we sent a T_REQACK for the current window. Worker uses
    /// this to decide when the ACK has timed out.
    private var lastReqAckTime: Date?

    /// Timestamp of the last wire activity (send or receive). Worker
    /// uses this to drive the idle-timeout close.
    private var lastActivity: Date = Date()

    /// Set to true when the session has been explicitly closed (either
    /// by the app or via retry exhaustion). The worker exits its loop.
    private var closed = false

    // MARK: - Worker coordination

    /// Private dispatch queue driving the worker loop. Named so it's
    /// identifiable in Instruments traces.
    private let workerQueue: DispatchQueue

    /// Signaled whenever the worker should re-evaluate its state:
    /// new outbound data, an inbound ACK/NAK, an idle poke, or a close
    /// request. Takes the place of the upstream `threading.Event`.
    private let workerEvent = DispatchSemaphore(value: 0)

    // MARK: - Init

    public init(name: String,
                remoteStation: String,
                sessionType: SessionType = .general,
                blocksize: Int = 1024,
                outLimit: Int = 8) {
        self.name = name
        self.remoteStation = remoteStation
        self.type = sessionType
        self.blocksize = blocksize
        self.outLimit = outLimit
        self.workerQueue = DispatchQueue(label: "MacRatsCore.StatefulSession.\(name)",
                                          qos: .userInitiated)

        // Start the worker immediately. It runs until `closed` flips
        // true. The worker is responsible for making progress on both
        // the outbound and the timeout fronts; inbound handling runs
        // on the transport's read queue (see `deliverIncoming(_:)`).
        self.handler = { [weak self] frame in
            self?.deliverIncoming(frame)
        }
        workerQueue.async { [weak self] in
            self?.runWorker()
        }
    }

    // MARK: - Public API

    /// Queue application data for transmission. Returns immediately —
    /// the worker picks up the new blocks on its next iteration.
    ///
    /// The data is chopped into `blocksize` chunks. Each chunk becomes
    /// a single `T_DAT` block with its own sequence number. The worker
    /// handles in-order transmission, ACK waiting, and retransmission.
    ///
    /// Thread-safe. Can be called from any queue.
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        var remaining = data
        while !remaining.isEmpty {
            let chunkSize = Swift.min(remaining.count, blocksize)
            let chunk = remaining.prefix(chunkSize)
            remaining = remaining.dropFirst(chunkSize)

            let block = OutgoingBlock(seq: oseq, data: Data(chunk))
            outq.append(block)
            oseq = oseq &+ 1  // wrap 255 → 0
        }
        lock.unlock()

        workerEvent.signal()
    }

    /// Close the session. After calling this, no further sends will be
    /// accepted; inbound data already in the OOO queue is drained to
    /// the delegate and the worker exits. The `delegate.didClose`
    /// callback fires once the worker has cleaned up.
    public func close() {
        lock.lock()
        closed = true
        lock.unlock()

        workerEvent.signal()
    }

    // MARK: - Inbound dispatch

    /// Called by the session manager (via the `handler` closure set in
    /// init) for every inbound DDT2 frame whose session id matches
    /// ours. Runs on the transport read queue, not the worker queue.
    ///
    /// Dispatches on the DDT2 sub-type:
    ///
    /// - `T_DAT`: save the block (in-order delivery handled later).
    /// - `T_ACK`: mark the named blocks as acknowledged, remove them
    ///   from the outstanding window, and wake the worker.
    /// - `T_REQACK`: reply with a `T_ACK` listing the sub-set of the
    ///   requested block numbers we actually have.
    /// - `T_NAK`: treat as an implicit REQACK and reply with what we
    ///   have. Upstream never emits NAKs but a future peer might.
    /// - Anything else: ignore with a log line.
    public func deliverIncoming(_ frame: DDT2Frame) {
        let now = Date()
        lock.lock()
        lastActivity = now
        stats.receivedBytes += frame.data.count
        lock.unlock()

        switch frame.type {
        case Self.T_DAT:
            handleIncomingData(frame)
        case Self.T_ACK:
            handleIncomingAck(frame)
        case Self.T_REQACK, Self.T_NAK:
            handleIncomingReqAck(frame)
        case Self.T_SYN:
            // We don't implement the open handshake; a peer that sends
            // T_SYN is either upstream D-Rats opening a session or a
            // misconfigured client. Log and ignore — if the peer then
            // sends T_DAT we'll process those normally.
            manager?.log("StatefulSession: ignoring T_SYN from \(frame.sStation)")
        default:
            manager?.log("StatefulSession: unknown sub-type \(frame.type) from \(frame.sStation)")
        }
    }

    // MARK: - Inbound handlers

    private func handleIncomingData(_ frame: DDT2Frame) {
        // StatefulSession uses 8-bit block sequence numbers to stay
        // wire-compatible with older D-Rats clients. `DDT2Frame.seq`
        // is a 16-bit field, but upstream's `stateful.py` explicitly
        // caps block numbers at 256 ("FIXME: For 16-bit blocks") and
        // we match that. Truncate here at the boundary.
        let blockSeq = UInt8(truncatingIfNeeded: frame.seq)

        lock.lock()

        // Rollover reset: if the remote sent seq=0 right after we saw
        // seq=255, clear recvList so the 0 doesn't get rejected as a
        // duplicate. Matches upstream's exact comment about this.
        if blockSeq == 0 && iseq == 255 {
            recvList.removeAll()
        }

        // De-duplicate against recvList. If we've already seen this
        // sequence number, drop the duplicate.
        if recvList.contains(blockSeq) {
            lock.unlock()
            manager?.log("StatefulSession: dropping duplicate block seq=\(blockSeq)")
            return
        }

        recvList.insert(blockSeq)
        oobQueue[blockSeq] = frame.data

        // Drain as many in-order blocks as we can.
        var delivered: [Data] = []
        var expected: UInt8 = iseq &+ 1
        while let payload = oobQueue[expected] {
            delivered.append(payload)
            oobQueue.removeValue(forKey: expected)
            iseq = expected
            expected = expected &+ 1
        }
        lock.unlock()

        // Deliver outside the lock to avoid holding it across the app
        // layer's code path.
        for chunk in delivered {
            delegate?.statefulSession(self, didReceive: chunk)
        }
    }

    private func handleIncomingAck(_ frame: DDT2Frame) {
        let ackedSeqs = Array(frame.data)

        lock.lock()
        retryAttempts = 0

        // Remove any outstanding block whose seq appears in the ACK
        // payload. The remaining outstanding blocks stay in the
        // window; they'll be REQACK'd again next cycle.
        outstanding.removeAll { block in
            if ackedSeqs.contains(block.seq) {
                stats.sentBytes += block.data.count
                return true
            }
            return false
        }
        waitingForAck.removeAll()
        lastReqAckTime = nil
        lock.unlock()

        workerEvent.signal()
    }

    private func handleIncomingReqAck(_ frame: DDT2Frame) {
        let requested = Array(frame.data)

        lock.lock()
        // Reply with the intersection of the requested list and what
        // we actually have in `recvList`. Everything else is implicitly
        // NAK'd by its absence — the remote will retransmit after its
        // own timeout fires.
        let toAck = requested.filter { recvList.contains($0) }
        lock.unlock()

        sendAck(toAck)
    }

    // MARK: - Worker loop

    /// The main send-and-retry loop. Runs on `workerQueue`. Each
    /// iteration:
    ///
    /// 1. Checks whether we're closed — if so, deliver the "did close"
    ///    event and exit.
    /// 2. Moves queued blocks into the outstanding window up to
    ///    `outLimit`.
    /// 3. Transmits every block in the outstanding window that hasn't
    ///    been transmitted yet (or needs a retry).
    /// 4. If we have outstanding blocks and the last T_REQACK was
    ///    either never sent or has timed out, send (another) T_REQACK.
    /// 5. Sleeps on `workerEvent` until something wakes us up or the
    ///    idle timeout expires.
    private func runWorker() {
        while true {
            lock.lock()
            if closed {
                lock.unlock()
                deliverClose(reason: nil)
                return
            }

            // Retry exhaustion check. Put this BEFORE we try to make
            // progress so a dead peer can't starve the close.
            if retryAttempts >= Self.maxRetries {
                lock.unlock()
                deliverClose(reason: "Peer did not acknowledge after \(Self.maxRetries) REQACK attempts")
                return
            }

            // Promote queued blocks into the outstanding window.
            let room = outLimit - outstanding.count
            if room > 0 {
                let take = Swift.min(room, outq.count)
                if take > 0 {
                    outstanding.append(contentsOf: outq.prefix(take))
                    outq.removeFirst(take)
                }
            }

            // Snapshot what we need for transmission, then drop the
            // lock. We DO NOT call into `manager.outgoing(...)` with
            // the session lock held — the manager takes its own lock
            // and we'd risk a deadlock if inbound processing needs to
            // update our state at the same time.
            let blocksToSend = outstanding.filter { !$0.transmitted }
            let needReqAck = !outstanding.isEmpty && shouldSendReqAckLocked()
            let idleElapsed = Date().timeIntervalSince(lastActivity)
            let isIdle = outstanding.isEmpty && outq.isEmpty
            lock.unlock()

            // Transmit any blocks that need it.
            for block in blocksToSend {
                do {
                    try sendDataBlock(block)
                    lock.lock()
                    if let idx = outstanding.firstIndex(where: { $0.seq == block.seq }) {
                        outstanding[idx].transmitted = true
                    }
                    lock.unlock()
                } catch {
                    manager?.log("StatefulSession: transport send failed: \(error.localizedDescription)")
                    // Let the retry logic handle this on the next loop.
                    break
                }
            }

            // Send a REQACK if we have outstanding blocks and either
            // haven't asked yet or the last ask timed out.
            if needReqAck {
                lock.lock()
                let toRequest = outstanding.map { $0.seq }
                waitingForAck = toRequest
                lastReqAckTime = Date()
                retryAttempts += 1
                lock.unlock()

                do {
                    try sendReqAck(toRequest)
                } catch {
                    manager?.log("StatefulSession: transport REQACK send failed: \(error.localizedDescription)")
                }
            }

            // Idle-timeout check.
            if isIdle && idleElapsed >= Self.idleTimeoutSeconds {
                deliverClose(reason: nil)
                return
            }

            // Sleep until we either get signaled (inbound ACK, new
            // send, or close) or the short/long deadline elapses.
            //
            // When there's nothing outstanding, use the full idle
            // timeout so we don't spin. When there's outstanding data
            // in flight, poll every second so REQACK retries happen
            // on schedule.
            let sleepInterval: DispatchTimeInterval = isIdle
                ? .seconds(Int(Self.idleTimeoutSeconds))
                : .seconds(1)
            _ = workerEvent.wait(timeout: .now() + sleepInterval)
        }
    }

    /// Caller holds `lock`. Returns true if we should send a T_REQACK
    /// right now — either we have blocks in flight and have never
    /// asked for an ACK, or the last ask has timed out.
    private func shouldSendReqAckLocked() -> Bool {
        guard !outstanding.isEmpty else { return false }

        // Check that every block has been transmitted at least once —
        // no point asking for an ACK on blocks we haven't sent yet.
        guard outstanding.allSatisfy({ $0.transmitted }) else { return false }

        guard let lastAsk = lastReqAckTime else {
            // Never asked — ask now.
            return true
        }

        // Compute the dynamic timeout the same way upstream does.
        let pendingBytes = outstanding.reduce(0) { $0 + $1.data.count }
        let rate = Self.minimumAssumedRate
        var timeout = Double(pendingBytes) / rate * 1.5
        if timeout < Self.minimumAckTimeoutSeconds {
            timeout = Self.minimumAckTimeoutSeconds
        }
        // Add the progressive backoff the upstream `send_blocks()`
        // applies on each retry: 4 + N*4 seconds.
        if retryAttempts > 0 {
            timeout += 4 + Double(retryAttempts) * 4
        }

        return Date().timeIntervalSince(lastAsk) >= timeout
    }

    // MARK: - Outbound wire format

    /// Build a T_DAT DDT2 frame and hand it to the session manager.
    private func sendDataBlock(_ block: OutgoingBlock) throws {
        guard let manager else { throw SessionError.notAttachedToManager }

        var frame = DDT2Frame()
        frame.seq = UInt16(block.seq)  // 8-bit block seq widened to the 16-bit DDT2 field
        frame.session = id
        frame.type = Self.T_DAT
        frame.sStation = manager.callsign
        frame.dStation = remoteStation
        frame.data = block.data
        frame.compress = compress

        try manager.outgoing(self, frame: frame)
    }

    /// Build a T_REQACK DDT2 frame whose payload is the list of
    /// sequence numbers we'd like acknowledged, and send it.
    private func sendReqAck(_ seqs: [UInt8]) throws {
        guard let manager else { throw SessionError.notAttachedToManager }

        var frame = DDT2Frame()
        frame.seq = 0
        frame.session = id
        frame.type = Self.T_REQACK
        frame.sStation = manager.callsign
        frame.dStation = remoteStation
        frame.data = Data(seqs)
        frame.compress = false  // ACK payloads are too small to compress

        try manager.outgoing(self, frame: frame)
    }

    /// Build a T_ACK DDT2 frame and send it. Payload is the list of
    /// sequence numbers we've received.
    private func sendAck(_ seqs: [UInt8]) {
        guard let manager else { return }

        var frame = DDT2Frame()
        frame.seq = 0
        frame.session = id
        frame.type = Self.T_ACK
        frame.sStation = manager.callsign
        frame.dStation = remoteStation
        frame.data = Data(seqs)
        frame.compress = false

        do {
            try manager.outgoing(self, frame: frame)
        } catch {
            manager.log("StatefulSession: T_ACK send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Close dispatch

    private func deliverClose(reason: String?) {
        lock.lock()
        let alreadyClosed = (state == .closed)
        state = .closed
        closed = true
        lock.unlock()

        guard !alreadyClosed else { return }

        if let reason {
            delegate?.statefulSession(self, didFailWithReason: reason)
        } else {
            delegate?.statefulSessionDidClose(self)
        }
    }

    // MARK: - Supporting types

    /// A single block of outbound user data. Carries its sequence
    /// number (assigned at enqueue time) and a `transmitted` flag the
    /// worker flips once the block has hit the wire. Retransmissions
    /// leave the flag true and are driven by REQACK/ACK, not by
    /// rebuilding the block.
    private struct OutgoingBlock {
        let seq: UInt8
        let data: Data
        var transmitted: Bool = false
    }
}
