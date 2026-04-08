#if canImport(IOBluetooth)
import Foundation
import IOBluetooth

/// A `RadioTransport` that talks to a Bluetooth SPP device by holding an
/// `IOBluetoothRFCOMMChannel` directly. Bytes are written via
/// `channel.writeAsync(...)` and received via the `rfcommChannelData(...)`
/// delegate callback. The macOS-managed `/dev/cu.*` virtual serial port is
/// **not used** — bytes never traverse the kernel BT serial driver.
///
/// ## Why this exists (and why USBSerialTransport was wrong for Bluetooth)
///
/// MacRats v0.1 wired the Bluetooth code path to `USBSerialTransport`,
/// reading and writing through `/dev/cu.TH-D75`. That seemed to work in
/// the sense that `BluetoothCoordinator` could hand back a real path and
/// `USBSerialTransport.send()` would happily write bytes to it. But
/// **zero RX bytes ever came back from the radio**. The traces in
/// `~/Downloads/MacRats/wire.log` over multiple sessions confirmed it:
/// every line was `TX`, never `RX`.
///
/// The hard-won finding (validated by the sibling `th-programmer` project's
/// `RFCOMMTransport` and the d75link binary): on macOS the cu.* file is a
/// **stale shim** unless an in-process `IOBluetoothRFCOMMChannel` reference
/// keeps the channel session alive AND the data is consumed via the channel
/// delegate, not via POSIX read on cu.*. The kernel BT serial driver is a
/// separate consumer of the SDP-advertised SPP service that on the TH-D75
/// is wired to a different endpoint than the data TNC. The data TNC is
/// reachable only through RFCOMM channel 2 with our app holding the
/// channel directly.
///
/// ## What this class does
///
/// 1. Opens an ACL connection to the paired radio (idempotent — leaves it
///    alone if macOS already paired the device).
/// 2. Opens RFCOMM channel 2 via `openRFCOMMChannelAsync(...)` with `self`
///    as the delegate. Uses the modern async API because on macOS Tahoe
///    (26.x) the deprecated `openRFCOMMChannelSync(...)` blocks for ~3s and
///    returns generic `kIOReturnError` even when a channel object is
///    allocated.
/// 3. Waits for `rfcommChannelOpenComplete:status:` to confirm the channel
///    is actually live.
/// 4. Marks the transport `.connected` and starts servicing TX/RX.
///
/// ## TX path
///
/// `send(_:)` calls `channel.writeAsync(pointer, length:, refcon: nil)`.
/// `writeAsync` is fire-and-forget — write completion is reported via
/// `rfcommChannelWriteComplete(_:refcon:status:)`, which we currently use
/// only for error logging. DDT2 frames are small enough (<256 bytes) that
/// flow control hasn't been needed in practice; if it ever is, we can wire
/// in `rfcommChannelQueueSpaceAvailable` then.
///
/// ## RX path
///
/// `rfcommChannelData(_:data:length:)` fires for every inbound burst. We
/// copy the bytes into a fresh `Data` (the pointer is owned by IOBluetooth
/// and will be reused immediately after the callback returns) and forward
/// them to the `RadioTransportDelegate.transport(_:didReceive:)` method.
///
/// ## TH-D75 quirk: exclusive access on first connect
///
/// macOS auto-pair sometimes holds RFCOMM channel 2 itself when the radio
/// is paired through System Settings, in which case our first
/// `openRFCOMMChannelAsync` will get `kIOReturnExclusiveAccess` (0xE00002C5).
/// We retry up to 10 times with exponential backoff. Tearing down the ACL
/// connection between attempts makes things WORSE on the TH-D75 — it
/// causes the radio to fire a second "connection completed" event which
/// can corrupt terminal mode state — so we leave the ACL alone and just
/// poll the channel open.
public final class BluetoothRFCOMMTransport: NSObject, RadioTransport, @unchecked Sendable {

    /// Bluetooth address of the paired radio. Accepts either colon-
    /// separated (`AA:BB:CC:DD:EE:FF`) or dash-separated form.
    public let address: String

    /// RFCOMM channel ID. Hard-coded to 2 — the TH-D75 uses channel 2
    /// for its data TNC. Channel 1 (the SDP-advertised SPP service) is
    /// wired to a different endpoint that does not respond to MMDVM.
    public static let dataChannelID: BluetoothRFCOMMChannelID = 2

    public let displayName: String

    /// Maximum bring-up attempts before reporting failure.
    private static let maxConnectAttempts = 10

    /// Optional callback fired with each line of internal trace output.
    /// `MacRatsAppModel` forwards these into the app log so the user can
    /// see bring-up progress live in the debug pane. The same lines are
    /// also written directly to `~/Downloads/MacRats/bluetooth.log` by
    /// the transport itself — see `appendBluetoothLog(_:)` below.
    public var onDiagnosticLine: (@Sendable (String) -> Void)?

    // MARK: - Internal state

    private let stateLock = NSLock()
    private weak var delegate: RadioTransportDelegate?
    private var _status: TransportStatus = .disconnected
    public var status: TransportStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return _status
    }

    /// Worker queue for the IOBluetooth bring-up dance. The IOBluetooth
    /// API is documented as main-run-loop-driven but in practice it
    /// dispatches delegate callbacks from internal threads, so we serialize
    /// our own state here and hop to main only when we need to.
    private let workQueue = DispatchQueue(label: "MacRatsCore.BluetoothRFCOMMTransport",
                                          qos: .userInitiated)

    /// Current device + channel. Both are nil until `connect()` resolves.
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?

    /// Total RX bytes since the last `connect()`. Useful for diagnostics
    /// — we trace `RFCOMM RX +N (total M)` on every burst, which is the
    /// most direct evidence that the air link is actually carrying data.
    private var rxBytesTotal: Int = 0

    /// Total TX bytes since the last `connect()`. Traced on every
    /// `send()` so the user can confirm in bluetooth.log that MacRats
    /// actually saw and dispatched each outbound chat message.
    private var txBytesTotal: Int = 0

    // MARK: - Init

    public init(address: String) {
        self.address = address
        self.displayName = "Bluetooth RFCOMM ch\(Self.dataChannelID): \(address)"
        super.init()
    }

    // MARK: - RadioTransport

    public func setDelegate(_ delegate: RadioTransportDelegate?) {
        stateLock.lock(); defer { stateLock.unlock() }
        self.delegate = delegate
    }

    public func connect() throws {
        // Bring-up is async (ACL handshake, channel open, callback wait).
        // We move to .connecting immediately and dispatch the actual work.
        // The delegate is informed of the eventual .connected or .failed.
        setStatus(.connecting)
        workQueue.async { [weak self] in
            self?.bringUpLink()
        }
    }

    public func disconnect() {
        workQueue.async { [weak self] in
            self?.tearDown(reason: nil)
        }
    }

    public func send(_ data: Data) throws {
        let liveChannel: IOBluetoothRFCOMMChannel?
        let isConnected: Bool
        stateLock.lock()
        liveChannel = channel
        isConnected = (_status == .connected)
        txBytesTotal += data.count
        let totalTx = txBytesTotal
        stateLock.unlock()

        guard isConnected, let channel = liveChannel else {
            throw TransportError.notConnected
        }

        // writeAsync needs a mutable pointer. Copy the data so the caller's
        // buffer is untouched (Data is value-type so this is cheap, but be
        // explicit about ownership).
        var mutableData = data
        let result: IOReturn = mutableData.withUnsafeMutableBytes { rawBuffer -> IOReturn in
            guard let baseAddress = rawBuffer.baseAddress else {
                return IOReturn(kIOReturnBadArgument)
            }
            return channel.writeAsync(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                length: UInt16(data.count),
                refcon: nil
            )
        }

        // Trace the TX immediately — this is the evidence in bluetooth.log
        // that the transport layer actually saw the send() call and handed
        // bytes to IOBluetooth. Combined with rfcommChannelWriteComplete
        // (traced only on error) and rfcommChannelData (traced for every
        // RX burst), the Bluetooth log now shows the full TX/RX story for
        // any session. Useful when debugging "I sent a message but nothing
        // happened" — if TX isn't in the log, MacRats never called send();
        // if TX is in the log but no RX, the radio isn't routing DV data
        // to Bluetooth (see Menu 984 in the README).
        if result == kIOReturnSuccess {
            trace("RFCOMM TX +\(data.count) bytes (total \(totalTx))")
        } else {
            let hex = String(format: "0x%08X", UInt32(bitPattern: result))
            trace("RFCOMM TX FAIL \(data.count) bytes: writeAsync → \(hex)")
            throw TransportError.writeFailed("RFCOMM writeAsync failed (\(hex))")
        }
    }

    // MARK: - Bring-up

    /// Run the actual IOBluetooth bring-up. Always called on `workQueue`.
    /// Mutates `device` + `channel` on success and posts status changes.
    private func bringUpLink() {
        trace("bringUpLink start: address=\(address)")
        trace("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        guard let btDevice = IOBluetoothDevice(addressString: address) else {
            fail("Invalid Bluetooth address: \(address)")
            return
        }
        trace("device: name=\(btDevice.name ?? "(nil)") paired=\(btDevice.isPaired())")

        stateLock.lock()
        device = btDevice
        stateLock.unlock()

        // Open ACL if needed. Don't tear it down between retries — that
        // makes the TH-D75 angry.
        if !btDevice.isConnected() {
            trace("ACL not connected — calling openConnection()")
            let aclResult = btDevice.openConnection()
            trace("openConnection() → \(formatIOReturn(aclResult))")
            if aclResult != kIOReturnSuccess {
                fail("ACL connection failed (\(formatIOReturn(aclResult)))")
                return
            }
            trace("sleeping 2s for baseband handshake")
            Thread.sleep(forTimeInterval: 2.0)
            trace("post-sleep ACL connected = \(btDevice.isConnected())")
        } else {
            trace("ACL already connected — skipping openConnection()")
        }

        // Open RFCOMM channel 2 with retries on exclusive-access.
        var lastError: IOReturn = kIOReturnError
        for attempt in 1...Self.maxConnectAttempts {
            if attempt > 1 {
                let backoff = min(Double(1 << (attempt - 2)), 8.0)
                trace("retry \(attempt)/\(Self.maxConnectAttempts) after \(backoff)s")
                Thread.sleep(forTimeInterval: backoff)
            }

            trace("attempt \(attempt): openRFCOMMChannelAsync channel=\(Self.dataChannelID)")
            var rfcomm: IOBluetoothRFCOMMChannel?
            let kickoff = btDevice.openRFCOMMChannelAsync(
                &rfcomm,
                withChannelID: Self.dataChannelID,
                delegate: self
            )
            trace("  kickoff → \(formatIOReturn(kickoff)) channel=\(rfcomm == nil ? "nil" : "non-nil")")

            // The async kickoff is supposed to return success and then
            // fire `rfcommChannelOpenComplete:status:` later. If it
            // returns anything else, treat it like a failed open and try
            // again. Exclusive-access is the most common transient
            // failure on Tahoe — macOS auto-pair grabs the channel
            // before we get a chance.
            if kickoff != kIOReturnSuccess {
                lastError = kickoff
                if kickoff == IOReturn(kIOReturnExclusiveAccess) {
                    trace("  exclusive access — macOS auto-pair holding ch2; will retry")
                } else if kickoff == IOReturn(kIOReturnNotPermitted) {
                    trace("  not permitted — TCC Bluetooth permission may need granting")
                }
                continue
            }

            // Wait for the open-complete callback. We use a semaphore
            // populated by `rfcommChannelOpenComplete(...)`.
            let status = waitForOpenComplete(timeoutSeconds: 5.0)
            switch status {
            case .success:
                trace("  open complete: SUCCESS")
                stateLock.lock()
                channel = rfcomm
                stateLock.unlock()
                setStatus(.connected)
                return
            case .failed(let code):
                trace("  open complete: FAILED \(formatIOReturn(code))")
                lastError = code
                if let ch = rfcomm { _ = ch.close() }
            case .timeout:
                trace("  open complete: TIMED OUT after 5s")
                lastError = IOReturn(kIOReturnTimeout)
                if let ch = rfcomm { _ = ch.close() }
            }
        }

        fail("RFCOMM ch\(Self.dataChannelID) open failed after \(Self.maxConnectAttempts) attempts (last: \(formatIOReturn(lastError)))")
    }

    /// Block the current thread (which is always `workQueue`) until the
    /// open-complete callback fires or the timeout elapses, whichever
    /// comes first. Resolved by `rfcommChannelOpenComplete:status:`.
    private func waitForOpenComplete(timeoutSeconds: TimeInterval) -> OpenStatus {
        let sem = DispatchSemaphore(value: 0)
        openCompleteLock.lock()
        openCompleteSemaphore = sem
        openCompleteResult = nil
        openCompleteLock.unlock()

        let waitResult = sem.wait(timeout: .now() + timeoutSeconds)

        openCompleteLock.lock()
        let result = openCompleteResult
        openCompleteSemaphore = nil
        openCompleteResult = nil
        openCompleteLock.unlock()

        if waitResult == .timedOut { return .timeout }
        return result ?? .timeout
    }

    /// Tear down the channel and ACL state. Called from `disconnect()` and
    /// from internal failure paths.
    private func tearDown(reason: String?) {
        stateLock.lock()
        let oldChannel = channel
        channel = nil
        device = nil
        stateLock.unlock()

        if let ch = oldChannel {
            _ = ch.close()
            ch.setDelegate(nil)
        }

        if let reason {
            setStatus(.failed(reason))
        } else {
            setStatus(.disconnected)
        }
    }

    private func fail(_ reason: String) {
        trace("FAIL: \(reason)")
        tearDown(reason: reason)
    }

    // MARK: - Open-complete handshake

    private enum OpenStatus {
        case success
        case failed(IOReturn)
        case timeout
    }

    private let openCompleteLock = NSLock()
    private var openCompleteSemaphore: DispatchSemaphore?
    private var openCompleteResult: OpenStatus?

    // MARK: - IOBluetoothRFCOMMChannelDelegate (informal protocol)

    @objc func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                          status error: IOReturn) {
        let result: OpenStatus = (error == kIOReturnSuccess) ? .success : .failed(error)
        openCompleteLock.lock()
        openCompleteResult = result
        openCompleteSemaphore?.signal()
        openCompleteLock.unlock()
    }

    @objc func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                  data dataPointer: UnsafeMutableRawPointer!,
                                  length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = Data(bytes: dataPointer, count: dataLength)

        stateLock.lock()
        rxBytesTotal += dataLength
        let total = rxBytesTotal
        let delegate = self.delegate
        stateLock.unlock()

        trace("RFCOMM RX +\(dataLength) bytes (total \(total))")
        delegate?.transport(self, didReceive: bytes)
    }

    @objc func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        trace("RFCOMM channel closed by remote or system")
        // If close arrives before open complete, unblock the waiter.
        openCompleteLock.lock()
        if openCompleteResult == nil {
            openCompleteResult = .failed(kIOReturnAborted)
            openCompleteSemaphore?.signal()
        }
        openCompleteLock.unlock()
        // Don't tear down here directly — bringUpLink may already be in
        // its retry loop, and disconnect() / fail() drives state change.
        let wasConnected: Bool
        stateLock.lock()
        wasConnected = (_status == .connected)
        stateLock.unlock()
        if wasConnected {
            workQueue.async { [weak self] in
                self?.tearDown(reason: "RFCOMM channel closed unexpectedly")
            }
        }
    }

    @objc func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                           refcon: UnsafeMutableRawPointer!,
                                           status error: IOReturn) {
        if error != kIOReturnSuccess {
            trace("RFCOMM write complete: error \(formatIOReturn(error))")
        }
    }

    @objc func rfcommChannelControlSignalsChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
    @objc func rfcommChannelFlowControlChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
    @objc func rfcommChannelQueueSpaceAvailable(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}

    // MARK: - Status / delegate plumbing

    private func setStatus(_ newStatus: TransportStatus) {
        let observer: RadioTransportDelegate?
        stateLock.lock()
        if _status == newStatus {
            stateLock.unlock()
            return
        }
        _status = newStatus
        observer = self.delegate
        stateLock.unlock()
        observer?.transport(self, didChangeStatus: newStatus)
    }

    // MARK: - Trace logging

    private func trace(_ line: String) {
        let stamped = "[\(Self.timestamp())] \(line)"
        onDiagnosticLine?(stamped)
        Self.appendBluetoothLog(stamped)
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df.string(from: Date())
    }

    /// Append a trace line to `~/Downloads/MacRats/bluetooth.log`. Each
    /// line is preceded by an ISO8601 session marker on the first call
    /// of a session. Best-effort — failures to write are silent.
    private static let logWriteLock = NSLock()
    private static func appendBluetoothLog(_ line: String) {
        logWriteLock.lock()
        defer { logWriteLock.unlock() }

        let fm = FileManager.default
        guard let downloads = try? fm.url(for: .downloadsDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true) else {
            return
        }
        let dir = downloads.appendingPathComponent("MacRats", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let logURL = dir.appendingPathComponent("bluetooth.log")

        var payload = ""
        // Each `bringUpLink start` line begins a new session — write a
        // header above it. Subsequent lines just append.
        if line.contains("bringUpLink start") {
            payload += "\n=== \(ISO8601DateFormatter().string(from: Date())) === BluetoothRFCOMMTransport\n"
        }
        payload += line + "\n"

        guard let data = payload.data(using: .utf8) else { return }
        if fm.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func formatIOReturn(_ code: IOReturn) -> String {
        let hex = String(format: "0x%08X", UInt32(bitPattern: code))
        switch code {
        case kIOReturnSuccess:         return "success \(hex)"
        case kIOReturnError:           return "kIOReturnError (generic) \(hex)"
        case kIOReturnBusy:            return "kIOReturnBusy \(hex)"
        case kIOReturnNotPermitted:    return "kIOReturnNotPermitted \(hex)"
        case kIOReturnNoDevice:        return "kIOReturnNoDevice \(hex)"
        case kIOReturnNotOpen:         return "kIOReturnNotOpen \(hex)"
        case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess \(hex)"
        case kIOReturnTimeout:         return "kIOReturnTimeout \(hex)"
        case kIOReturnAborted:         return "kIOReturnAborted \(hex)"
        case kIOReturnNotFound:        return "kIOReturnNotFound \(hex)"
        default:                       return "IOReturn(\(code)) \(hex)"
        }
    }
}
#endif
