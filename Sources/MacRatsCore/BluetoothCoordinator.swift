#if canImport(IOBluetooth)
import Foundation
import IOBluetooth

/// Coordinates the macOS `IOBluetooth` dance required to bring up a usable
/// serial byte pipe to a TH-D75 (or TH-D74) over Bluetooth SPP. Hands the
/// resolved `/dev/cu.*` device file path to the caller, which then plugs
/// it into an existing `USBSerialTransport`.
///
/// ## Why this class exists
///
/// macOS creates and persists a `/dev/cu.TH-D75` (or similarly named) device
/// file for any paired Bluetooth SPP device whether or not the radio is
/// currently linked. `open()` on that file succeeds against a local node
/// even with the radio's Bluetooth OFF. Bytes written vanish.
///
/// For Bluetooth SPP to actually carry data on macOS you need:
///
/// 1. An `IOBluetooth` ACL connection open to the radio (`openConnection()`)
/// 2. An `IOBluetoothRFCOMMChannel` opened to the radio's SPP service
///    (`openRFCOMMChannelSync(...)`)
/// 3. **A reference to that RFCOMM channel held alive in memory for the
///    lifetime of the transport** — releasing it tears down the cu.* device
///    file on the next GC tick. `BluetoothCoordinator` holds that reference.
/// 4. For the TH-D75 specifically, the data channel is **RFCOMM channel 2**
///    (NOT the SDP-advertised SPP channel, which is usually 1). This is
///    hard-won knowledge from the sibling `th-programmer` project's
///    `BluetoothManager.swift`, confirmed via the `d75link` binary.
/// 5. macOS may show a TCC Bluetooth permission prompt on first open.
///    `kIOReturnNotPermitted` is handled with a 1-second sleep + one retry.
///
/// ## Lifecycle expectations
///
/// A single `BluetoothCoordinator` instance is meant to outlive the
/// `USBSerialTransport` it feeds. Typical flow:
///
/// ```swift
/// let coordinator = BluetoothCoordinator()
/// let radios = coordinator.pairedRadios()
/// let path = try await coordinator.bringUpLink(addressString: radios[0].address)
/// let transport = USBSerialTransport(devicePath: path, baudRate: 9600)
/// // ... use transport ...
/// transport.disconnect()
/// coordinator.tearDownLink()  // releases the RFCOMM channel, cu.* goes away
/// ```
///
/// ## Threading
///
/// IOBluetooth is historically NSNotificationCenter-driven and most of its
/// API is documented to run on the main run loop. This class is declared
/// `@MainActor` so all IOBluetooth calls are main-thread by construction.
/// Pure-function helpers are `nonisolated` for testing.
@MainActor
public final class BluetoothCoordinator {

    /// A paired Bluetooth radio suitable for MacRats (TH-D74 or TH-D75).
    public struct PairedRadio: Equatable, Sendable {
        public let name: String
        public let address: String       // "XX-XX-XX-XX-XX-XX" or "XX:XX:XX:XX:XX:XX"
        public let isCurrentlyConnected: Bool
        public let existingPortPath: String?   // if a cu.* file already exists

        public init(name: String,
                    address: String,
                    isCurrentlyConnected: Bool,
                    existingPortPath: String?) {
            self.name = name
            self.address = address
            self.isCurrentlyConnected = isCurrentlyConnected
            self.existingPortPath = existingPortPath
        }
    }

    public enum CoordinatorError: LocalizedError, CustomStringConvertible {
        case deviceNotFound(address: String)
        case aclConnectionFailed(code: Int32)
        case rfcommChannelFailed(code: Int32, channelID: Int, reason: String)
        case portDidNotAppear
        case permissionDenied

        public var errorDescription: String? { description }

        public var description: String {
            switch self {
            case .deviceNotFound(let address):
                return "Bluetooth device \(address) is not paired. Pair the radio in System Settings → Bluetooth first."
            case .aclConnectionFailed(let code):
                return "Bluetooth ACL connection failed (IOReturn \(Self.formatIOReturn(code))). Make sure the radio is powered on and in range."
            case .rfcommChannelFailed(let code, let channelID, let reason):
                return "Could not open RFCOMM channel \(channelID) on the radio: \(reason) (IOReturn \(Self.formatIOReturn(code))). \(Self.suggestedFix(for: code))"
            case .portDidNotAppear:
                return "The Bluetooth serial port did not appear within the timeout. Try turning the radio off and on."
            case .permissionDenied:
                return "macOS denied Bluetooth permission for MacRats. Check System Settings → Privacy & Security → Bluetooth."
            }
        }

        /// Produce a human-friendly representation of an IOReturn value.
        /// Recognizes the codes we actually hit on macOS and prints the
        /// raw hex for anything else so the user can paste it into a bug
        /// report.
        private static func formatIOReturn(_ code: Int32) -> String {
            let hex = String(format: "0x%08X", UInt32(bitPattern: code))
            switch code {
            case kIOReturnSuccess:          return "success (\(hex))"
            case kIOReturnBusy:             return "kIOReturnBusy (\(hex)) — another app or process has the radio open"
            case kIOReturnNotPermitted:     return "kIOReturnNotPermitted (\(hex)) — macOS TCC blocked the operation"
            case kIOReturnNoDevice:         return "kIOReturnNoDevice (\(hex)) — device not reachable"
            case kIOReturnNotOpen:          return "kIOReturnNotOpen (\(hex)) — no baseband connection"
            case kIOReturnExclusiveAccess:  return "kIOReturnExclusiveAccess (\(hex)) — channel already held by another client"
            case kIOReturnTimeout:          return "kIOReturnTimeout (\(hex)) — the radio did not respond in time"
            case kIOReturnAborted:          return "kIOReturnAborted (\(hex)) — the operation was cancelled"
            case kIOReturnCannotWire:       return "kIOReturnCannotWire (\(hex))"
            case kIOReturnNotFound:         return "kIOReturnNotFound (\(hex)) — the requested RFCOMM channel ID is not served by this radio"
            default:                        return "\(code) (\(hex))"
            }
        }

        private static func suggestedFix(for code: Int32) -> String {
            switch code {
            case kIOReturnBusy, kIOReturnExclusiveAccess:
                return "Another application is holding this channel. Quit D-Rats, Serial, CoolTerm, or any other terminal app that might be connected to the radio and try again."
            case kIOReturnNotPermitted:
                return "Open System Settings → Privacy & Security → Bluetooth and make sure MacRats is allowed."
            case kIOReturnNoDevice, kIOReturnNotOpen, kIOReturnTimeout:
                return "Toggle Bluetooth off and back on at the radio's front panel, then try again."
            case kIOReturnNotFound:
                return "The radio did not advertise the expected SPP service. Unpair and re-pair the radio in System Settings → Bluetooth, then try again."
            default:
                return "Try power-cycling the radio's Bluetooth."
            }
        }
    }

    /// The kept-alive RFCOMM channel reference. Must stay in memory for the
    /// lifetime of the serial transport or macOS tears down the cu.* file.
    private var rfcommChannel: IOBluetoothRFCOMMChannel?

    /// The kept-alive RFCOMM channel delegate. IOBluetooth holds the delegate
    /// only weakly via the channel's internal pointer, so we have to retain it
    /// ourselves for the lifetime of the channel. Cleared on teardown.
    private var rfcommDelegate: RFCOMMChannelDelegate?

    /// Total bytes received via the IOBluetooth RFCOMM delegate since the
    /// last `bringUpLink` call. Updated from the delegate's data callback,
    /// which is the most direct evidence we have that bytes are actually
    /// crossing the air link (the `/dev/cu.*` file is unreliable on Tahoe —
    /// it can succeed reads against an empty kernel buffer even when no
    /// bytes have flowed). Read by the diagnostic UI.
    public private(set) var rfcommRxBytes: Int = 0

    /// The device we're currently linked to. Cleared on teardown.
    private var currentDevice: IOBluetoothDevice?

    /// Human-readable trace of what happened during the most recent
    /// `bringUpLink` call. Populated step-by-step as the coordinator
    /// walks through ACL open, SDP query, service enumeration, and
    /// RFCOMM channel attempts. The trace is embedded in any thrown
    /// `CoordinatorError` so the caller can show it in a debug log
    /// and the user can paste it into a bug report.
    public private(set) var lastDiagnosticTrace: [String] = []

    /// Observer callback fired for every trace line the moment it is
    /// appended. Lets the UI tail the bring-up live in the debug log
    /// instead of waiting for a success or failure before seeing the
    /// whole sequence. Called on whatever thread the coordinator
    /// happens to be on.
    public var onDiagnosticLine: (@Sendable (String) -> Void)?

    public init() {}

    private func trace(_ line: String) {
        let ts = Self.traceTimestamp()
        let full = "[\(ts)] \(line)"
        lastDiagnosticTrace.append(full)
        onDiagnosticLine?(full)
    }

    private nonisolated static func traceTimestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df.string(from: Date())
    }

    // MARK: - Enumeration

    /// Returns the list of paired TH-D74/D75 radios currently known to
    /// `IOBluetooth`. If TCC has blocked `pairedDevices()` (common after
    /// ad-hoc re-signing), falls back to parsing `system_profiler
    /// SPBluetoothDataType` for the device addresses. If that also fails,
    /// returns an empty array.
    public func pairedRadios() -> [PairedRadio] {
        let allPaired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let supported = allPaired.filter { Self.isSupportedRadio($0) }

        if !supported.isEmpty {
            return supported.map { device in
                PairedRadio(
                    name: device.name ?? "TH-D75",
                    address: device.addressString ?? "",
                    isCurrentlyConnected: device.isConnected(),
                    existingPortPath: Self.findPortPath(forDeviceName: device.name ?? "",
                                                        addressString: device.addressString ?? "")
                )
            }
        }

        // Fallback: scrape system_profiler for a paired TH-D75 / TH-D74.
        // This is the case when macOS TCC has revoked our access to the
        // IOBluetooth paired-device list but the pairing itself is intact.
        if let profile = Self.scrapePairedRadioFromSystemProfiler() {
            return [profile]
        }

        // Last resort: see if a cu.TH-D75* device file exists on disk and
        // assume a radio is paired even though we can't see it via any API.
        if let port = Self.findPortPath(forDeviceName: "TH-D75", addressString: "") {
            return [PairedRadio(name: "TH-D75",
                                address: "unknown",
                                isCurrentlyConnected: true,
                                existingPortPath: port)]
        }
        if let port = Self.findPortPath(forDeviceName: "TH-D74", addressString: "") {
            return [PairedRadio(name: "TH-D74",
                                address: "unknown",
                                isCurrentlyConnected: true,
                                existingPortPath: port)]
        }
        return []
    }

    // MARK: - Bring-up

    /// Open an ACL connection + RFCOMM channel 2 to the paired radio with
    /// the given address, then poll for the matching `/dev/cu.*` device file
    /// to appear. Returns the resolved path, or throws.
    ///
    /// Safe to call multiple times — if a link is already up, tears it down
    /// and reopens.
    public func bringUpLink(addressString: String) async throws -> String {
        tearDownLink()
        lastDiagnosticTrace.removeAll()
        rfcommRxBytes = 0

        trace("bringUpLink start: address=\(addressString)")
        trace("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        guard let device = IOBluetoothDevice(addressString: addressString) else {
            trace("ERROR: IOBluetoothDevice(addressString:) returned nil")
            throw CoordinatorError.deviceNotFound(address: addressString)
        }
        trace("device: name=\(device.name ?? "(nil)") classOfDevice=\(String(format: "0x%08X", device.classOfDevice))")
        trace("device.isConnected() = \(device.isConnected())")

        // Step 1: open the ACL connection. If the device reports "connected"
        // but no cu.* file exists, the baseband connection is stale (e.g.
        // radio power-cycled) — close and reopen.
        let existingPort = Self.findPortPath(forDeviceName: device.name ?? "",
                                             addressString: addressString)
        trace("existing cu.* file: \(existingPort ?? "(none)")")

        if device.isConnected() && existingPort == nil {
            trace("ACL is up but no cu.* file — closing stale baseband link")
            device.closeConnection()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            trace("post-close device.isConnected() = \(device.isConnected())")
        }

        if !device.isConnected() {
            trace("calling device.openConnection()")
            let aclResult = device.openConnection()
            trace("openConnection() returned \(Self.describeIOReturn(aclResult))")
            if aclResult != kIOReturnSuccess {
                throw CoordinatorError.aclConnectionFailed(code: aclResult)
            }
            // Let macOS finish the baseband handshake.
            trace("sleeping 2s for baseband handshake")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            trace("post-sleep device.isConnected() = \(device.isConnected())")
        } else {
            trace("skipping ACL open — device already connected")
        }

        // Step 2: figure out which RFCOMM channel(s) to try and open one.
        //
        // The TH-D75 historically uses channel 2 for its data path (this
        // is documented in the sibling th-programmer project via the
        // d75link binary), but firmware and pairing variations can shift
        // that number. We therefore:
        //
        //   1. Perform an SDP query so the device's service records are
        //      populated (cached records after ad-hoc resigning can be
        //      stale or empty)
        //   2. Enumerate advertised RFCOMM channels from the SDP records
        //   3. Prepend channel 2 if it's not already in the list (so we
        //      still catch the d75link path)
        //   4. Try each candidate in order and stop on the first success
        let candidates = await discoverRFCOMMCandidates(for: device)

        // Step 3: try the modern async open with a real delegate first.
        //
        // On macOS Tahoe (26.x), `openRFCOMMChannelSync` is broken — it
        // blocks for ~3 seconds waiting for a delegate callback that
        // never fires and returns generic `kIOReturnError` even though
        // a channel object is allocated. The fix Apple ships is the
        // async variant, `openRFCOMMChannelAsync(_:withChannelID:delegate:)`,
        // which returns immediately with a status code and then fires
        // `rfcommChannelOpenComplete:status:` on the delegate when the
        // open is actually complete. This is the supported path on
        // current macOS and we should prefer it everywhere.
        //
        // The delegate also gives us a reliable `rfcommChannelData:data:length:`
        // hook so we can count RX bytes for diagnostics. The hard
        // question on Tahoe is whether bytes actually flow at all
        // through any of the IOBluetooth APIs — the RX byte counter
        // is how we'll find out.
        if let asyncPath = try await tryAsyncRFCOMMOpen(device: device,
                                                        candidates: candidates,
                                                        addressString: addressString) {
            return asyncPath
        }

        // Step 4: legacy sync open. Kept as a fallback for older macOS
        // (Sonoma and earlier) where the sync API still works and the
        // async variant might have its own quirks. Will fail-fast on
        // Tahoe with the same generic error we've been seeing.
        trace("async path exhausted — falling back to legacy sync open")
        if let syncPath = try await tryLegacyRFCOMMOpen(device: device,
                                                        candidates: candidates,
                                                        addressString: addressString) {
            return syncPath
        }

        // Step 5: last-ditch — if macOS itself has already paired the
        // radio and created a `/dev/cu.*` file (managed by the system
        // Bluetooth daemon, NOT by us holding an RFCOMM channel), use
        // that. This is the path we used in commit 3dcf65a as the
        // Tahoe workaround. We now know it's a "stale shim" — bytes
        // written go nowhere because nothing is keeping the kernel
        // RFCOMM session alive — but it's still our best fallback if
        // both the async and sync APIs have rejected us.
        if let managedPath = Self.findPortPath(forDeviceName: device.name ?? "",
                                               addressString: addressString) {
            trace("WARNING: all RFCOMM open attempts failed; trusting pre-existing cu.* file")
            trace("  this path is unreliable — bytes may not actually flow over the air link")
            trace("  resolved path: \(managedPath)")
            self.currentDevice = device
            return managedPath
        }

        // Nothing worked.
        let tried = candidates.map { "\($0.channelID)" }.joined(separator: ", ")
        throw CoordinatorError.rfcommChannelFailed(
            code: kIOReturnError,
            channelID: candidates.last?.channelID ?? 2,
            reason: "tried channel(s) \(tried) via async + sync APIs; no cu.* file present"
        )
    }

    // MARK: - Async RFCOMM open (modern path, primary)

    /// Attempt to open an RFCOMM channel using the modern async API with
    /// a real delegate. Returns the resolved cu.* path on success, nil on
    /// failure (caller falls back to the legacy sync path). Throws only
    /// on TCC permission denial.
    private func tryAsyncRFCOMMOpen(device: IOBluetoothDevice,
                                    candidates: [RFCOMMCandidate],
                                    addressString: String) async throws -> String? {
        for candidate in candidates {
            trace("attempt async RFCOMM open: channel=\(candidate.channelID) source=\(candidate.source)")

            let delegate = RFCOMMChannelDelegate()
            // Trace RX bytes the moment they arrive. This is the most
            // direct evidence that the link is actually carrying data.
            // The callback fires on whatever thread IOBluetooth is using
            // for delegate dispatch (historically the main run loop) so
            // we hop back to MainActor before touching any state.
            delegate.onData = { [weak self] count in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.rfcommRxBytes += count
                    self.trace("RFCOMM RX +\(count) bytes (total \(self.rfcommRxBytes))")
                }
            }
            delegate.onClosed = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.trace("RFCOMM channel closed by remote or system")
                }
            }

            var channel: IOBluetoothRFCOMMChannel?
            let kickoff = device.openRFCOMMChannelAsync(
                &channel,
                withChannelID: BluetoothRFCOMMChannelID(candidate.channelID),
                delegate: delegate
            )
            trace("  async kickoff → \(Self.describeIOReturn(kickoff)) channel=\(channel == nil ? "nil" : "non-nil")")

            if kickoff == IOReturn(kIOReturnNotPermitted) {
                trace("  kIOReturnNotPermitted on async kickoff — waiting 1.5s for TCC prompt then retrying")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                channel = nil
                let retry = device.openRFCOMMChannelAsync(
                    &channel,
                    withChannelID: BluetoothRFCOMMChannelID(candidate.channelID),
                    delegate: delegate
                )
                trace("  async retry kickoff → \(Self.describeIOReturn(retry))")
                if retry == IOReturn(kIOReturnNotPermitted) {
                    throw CoordinatorError.permissionDenied
                }
                if retry != kIOReturnSuccess {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
            } else if kickoff != kIOReturnSuccess {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            // Wait for `rfcommChannelOpenComplete:status:`. Cap at 5s —
            // the typical successful open completes in under a second.
            let openStatus = await delegate.awaitOpenComplete(timeout: 5.0)
            switch openStatus {
            case .success:
                trace("  async open complete: status=success")
            case .failed(let code):
                trace("  async open complete: status=\(Self.describeIOReturn(code))")
                // Channel allocation may still be sitting in `channel` —
                // close it explicitly so the next candidate has a clean
                // slate.
                if let ch = channel { _ = ch.close() }
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            case .timeout:
                trace("  async open TIMED OUT after 5s — no rfcommChannelOpenComplete callback")
                if let ch = channel { _ = ch.close() }
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }

            // Open succeeded. Hold the channel + delegate alive for the
            // lifetime of the transport.
            guard let channel else {
                trace("  WARNING: open status was success but channel pointer is nil — skipping")
                continue
            }
            self.rfcommChannel = channel
            self.rfcommDelegate = delegate
            self.currentDevice = device
            trace("  RFCOMM channel \(candidate.channelID) OPEN (async) — keeping reference alive")

            // Poll up to 10 s for the /dev/cu.* device file to appear.
            for _ in 0..<20 {
                if let path = Self.findPortPath(forDeviceName: device.name ?? "",
                                                addressString: addressString) {
                    trace("  cu.* file resolved: \(path)")
                    return path
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            // Channel is up but no cu.* file appeared. This is a
            // diagnostic-worthy state: the modern API succeeded yet
            // the kernel serial driver didn't materialize a port. Tear
            // down so the next candidate (or the legacy fallback) gets
            // a clean slate.
            trace("  async open succeeded but no cu.* file appeared in 10s — tearing down and trying next path")
            tearDownLink()
        }
        return nil
    }

    // MARK: - Legacy RFCOMM open (sync, fallback)

    /// Attempt to open an RFCOMM channel using the deprecated synchronous
    /// API. Kept as a fallback for older macOS versions where the async
    /// path may not behave as expected. Returns the resolved cu.* path
    /// on success, nil on failure.
    private func tryLegacyRFCOMMOpen(device: IOBluetoothDevice,
                                     candidates: [RFCOMMCandidate],
                                     addressString: String) async throws -> String? {
        for candidate in candidates {
            trace("attempt sync RFCOMM open: channel=\(candidate.channelID) source=\(candidate.source)")
            var channel: IOBluetoothRFCOMMChannel?
            var openResult = device.openRFCOMMChannelSync(
                &channel,
                withChannelID: BluetoothRFCOMMChannelID(candidate.channelID),
                delegate: nil
            )
            trace("  sync open → \(Self.describeIOReturn(openResult)) channel=\(channel == nil ? "nil" : "non-nil")")

            if openResult == IOReturn(kIOReturnNotPermitted) {
                trace("  kIOReturnNotPermitted — waiting 1.5s for TCC prompt")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                channel = nil
                openResult = device.openRFCOMMChannelSync(
                    &channel,
                    withChannelID: BluetoothRFCOMMChannelID(candidate.channelID),
                    delegate: nil
                )
                trace("  retry sync open → \(Self.describeIOReturn(openResult))")
                if openResult == IOReturn(kIOReturnNotPermitted) {
                    throw CoordinatorError.permissionDenied
                }
            }

            if openResult == kIOReturnSuccess, let channel {
                trace("  RFCOMM channel \(candidate.channelID) OPEN (sync) — keeping reference alive")
                self.rfcommChannel = channel
                self.currentDevice = device

                for _ in 0..<20 {
                    if let path = Self.findPortPath(forDeviceName: device.name ?? "",
                                                    addressString: addressString) {
                        return path
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                trace("  sync open succeeded but no cu.* file appeared in 10s — tearing down and trying next path")
                tearDownLink()
                continue
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    /// A single RFCOMM channel we're going to try, plus a short label for
    /// error messages explaining where the channel ID came from.
    private struct RFCOMMCandidate {
        let channelID: Int
        let source: String
    }

    /// Run an SDP query against the device and return the list of RFCOMM
    /// channels it advertises, in preference order. Always ends with the
    /// d75link hard-coded fallback (channel 2) and channels 1 and 3 as
    /// last-ditch attempts, since some paired TH-D7x instances return
    /// empty SDP records after ad-hoc resigning.
    private func discoverRFCOMMCandidates(for device: IOBluetoothDevice) async -> [RFCOMMCandidate] {
        // Kick off an SDP query first — the cached records may be empty
        // or stale after a re-pair.
        let sdpResult = device.performSDPQuery(nil)
        trace("performSDPQuery() returned \(Self.describeIOReturn(sdpResult))")
        trace("sleeping 1.5s for SDP query to complete")
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        var candidates: [RFCOMMCandidate] = []
        var seenIDs = Set<Int>()

        func addCandidate(_ id: Int, source: String) {
            guard id > 0, !seenIDs.contains(id) else { return }
            seenIDs.insert(id)
            candidates.append(RFCOMMCandidate(channelID: id, source: source))
        }

        // **TH-D75-specific priority:** the data TNC channel is RFCOMM
        // channel 2 according to the d75link binary in the sibling
        // th-programmer project. The radio also advertises another SPP
        // service on channel 1 that appears to be a different endpoint
        // (memory programming, OBEX file transfer, or similar) — not
        // the data TNC. If we open channel 1 first, the open will
        // succeed but no bytes will ever flow because we're talking
        // to the wrong service. Always try channel 2 FIRST.
        addCandidate(2, source: "TH-D75 d75link data channel")

        // Then enumerate every RFCOMM channel ID from the SDP service
        // records. We don't filter by service UUID — we just want any
        // channel the radio has offered.
        if let services = device.services as? [IOBluetoothSDPServiceRecord] {
            trace("device.services: \(services.count) service record(s)")
            for (idx, service) in services.enumerated() {
                let serviceName = service.getServiceName() ?? "(no name)"
                var channelID: BluetoothRFCOMMChannelID = 0
                let chResult = service.getRFCOMMChannelID(&channelID)
                if chResult == kIOReturnSuccess {
                    trace("  service[\(idx)] name=\(serviceName) RFCOMM channel=\(channelID)")
                    addCandidate(Int(channelID), source: "SDP: \(serviceName)")
                } else {
                    trace("  service[\(idx)] name=\(serviceName) — not RFCOMM (getRFCOMMChannelID → \(Self.describeIOReturn(chResult)))")
                }
            }
        } else {
            trace("device.services: nil or unexpected type")
        }

        // Generic SPP channel numbers as last resorts.
        addCandidate(1, source: "generic SPP channel 1 fallback")
        addCandidate(3, source: "generic SPP channel 3 fallback")

        trace("RFCOMM candidates to try (in order): \(candidates.map { "ch\($0.channelID)" }.joined(separator: ", "))")
        return candidates
    }

    /// Short IOReturn renderer for trace lines. Different from
    /// `CoordinatorError.formatIOReturn` (which is verbose with
    /// suggested fixes) — this one is compact for log scroll-back.
    private nonisolated static func describeIOReturn(_ code: Int32) -> String {
        let hex = String(format: "0x%08X", UInt32(bitPattern: code))
        let named: String
        switch code {
        case kIOReturnSuccess:          named = "success"
        case kIOReturnError:            named = "kIOReturnError (generic)"
        case kIOReturnBusy:             named = "kIOReturnBusy"
        case kIOReturnNotPermitted:     named = "kIOReturnNotPermitted"
        case kIOReturnNoDevice:         named = "kIOReturnNoDevice"
        case kIOReturnNotOpen:          named = "kIOReturnNotOpen"
        case kIOReturnExclusiveAccess:  named = "kIOReturnExclusiveAccess"
        case kIOReturnTimeout:          named = "kIOReturnTimeout"
        case kIOReturnAborted:          named = "kIOReturnAborted"
        case kIOReturnNotFound:         named = "kIOReturnNotFound"
        case kIOReturnUnsupported:      named = "kIOReturnUnsupported"
        default:                        named = "IOReturn(\(code))"
        }
        return "\(named) \(hex)"
    }

    /// Tear down the RFCOMM channel (and by extension the cu.* device file).
    /// Call AFTER the `USBSerialTransport` has been disconnected.
    public func tearDownLink() {
        if let ch = rfcommChannel {
            _ = ch.close()
            ch.setDelegate(nil)
        }
        rfcommChannel = nil
        rfcommDelegate = nil
        // Intentionally don't call currentDevice.closeConnection() — macOS
        // keeps the ACL connection cached across re-opens and closing it
        // here just makes the next bring-up slower. The ACL link will time
        // out on its own when the radio goes out of range or is powered off.
        currentDevice = nil
    }

    // MARK: - Pure helpers (testable)

    /// Returns true if the device name looks like a TH-D74 or TH-D75.
    nonisolated public static func isSupportedRadio(_ device: IOBluetoothDevice) -> Bool {
        isSupportedRadioName(device.name ?? "")
    }

    /// Pure string test, exposed for unit testing without IOBluetooth.
    nonisolated public static func isSupportedRadioName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("TH-D75") || upper.contains("THD75")
            || upper.contains("TH-D74") || upper.contains("THD74")
    }

    /// Find the `/dev/cu.*` file corresponding to a Bluetooth device name or
    /// address. Looks for matches on the slugged device name, the
    /// dash-joined address, or a generic "th-d75"/"th-d74" substring.
    nonisolated public static func findPortPath(forDeviceName name: String,
                                                 addressString: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else {
            return nil
        }
        let addrSuffix = addressString.replacingOccurrences(of: ":", with: "-")
        return entries
            .sorted()
            .first { entry in
                entry.hasPrefix("cu.") &&
                portEntryMatches(entry, deviceName: name, addressSuffix: addrSuffix)
            }
            .map { "/dev/\($0)" }
    }

    /// Pure string test for whether a /dev entry matches a BT device.
    /// Exposed for unit testing.
    nonisolated public static func portEntryMatches(_ entry: String,
                                                     deviceName: String,
                                                     addressSuffix: String) -> Bool {
        let lower = entry.lowercased()
        let nameSlug = deviceName.replacingOccurrences(of: " ", with: "-").lowercased()
        let addrLower = addressSuffix.lowercased()

        if !nameSlug.isEmpty && lower.contains(nameSlug) { return true }
        if !addrLower.isEmpty && lower.contains(addrLower) { return true }
        return lower.contains("th-d75") || lower.contains("thd75")
            || lower.contains("th-d74") || lower.contains("thd74")
    }

    /// Shell out to `system_profiler SPBluetoothDataType` and parse the
    /// output for a paired TH-D75 or TH-D74. Used as a fallback when the
    /// `IOBluetooth.pairedDevices()` API returns nothing due to TCC
    /// restrictions (common with ad-hoc signed builds).
    nonisolated public static func scrapePairedRadioFromSystemProfiler() -> PairedRadio? {
        let output = runSystemProfilerBluetooth()
        guard !output.isEmpty else { return nil }
        return parseSystemProfilerOutput(output)
    }

    /// Pure function: given the stdout of `system_profiler SPBluetoothDataType`,
    /// return the first TH-D74/D75 paired device found.
    ///
    /// The format we parse looks like (indentation varies):
    ///
    /// ```
    /// TH-D75:
    ///   Address: 12:34:56:78:9A:BC
    ///   Minor Type: Handheld
    /// ```
    nonisolated public static func parseSystemProfilerOutput(_ output: String) -> PairedRadio? {
        let lines = output.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            // "TH-D75:" or "TH-D74:" marks the start of a device stanza.
            if trimmed.hasSuffix(":") {
                let nameCandidate = String(trimmed.dropLast())
                if isSupportedRadioName(nameCandidate) {
                    // Scan forward for the Address line.
                    var j = i + 1
                    while j < lines.count {
                        let inner = lines[j].trimmingCharacters(in: .whitespaces)
                        if inner.hasPrefix("Address:") {
                            let addr = inner
                                .replacingOccurrences(of: "Address:", with: "")
                                .trimmingCharacters(in: .whitespaces)
                            if addr.count >= 17 && addr.contains(":") {
                                let port = findPortPath(forDeviceName: nameCandidate,
                                                        addressString: addr)
                                return PairedRadio(
                                    name: nameCandidate,
                                    address: addr,
                                    isCurrentlyConnected: port != nil,
                                    existingPortPath: port
                                )
                            }
                        }
                        // Bail out of this stanza when we hit another device.
                        if inner.hasSuffix(":") && !inner.hasPrefix("Address")
                            && !inner.hasPrefix("Services") {
                            break
                        }
                        j += 1
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private nonisolated static func runSystemProfilerBluetooth() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        guard let data = try? pipe.fileHandleForReading.readDataToEndOfFile(),
              let output = String(data: data, encoding: .utf8) else {
            return ""
        }
        return output
    }
}

// MARK: - RFCOMM Channel Delegate (modern async path)

/// Bridge between the C-style `IOBluetoothRFCOMMChannelDelegate` informal
/// protocol and Swift `async`. Lives outside `BluetoothCoordinator` because
/// IOBluetooth dispatches delegate callbacks from internal threads, and
/// nesting it inside a `@MainActor` class would force every callback to
/// hop through the main actor before it could even update its own state.
///
/// The delegate exposes:
///
/// - `awaitOpenComplete(timeout:)` — async wait for `rfcommChannelOpenComplete`
///   with a hard timeout. Resolves to `.success`, `.failed(IOReturn)`, or
///   `.timeout`.
/// - `onData` — fired for every `rfcommChannelData` callback with the byte
///   count. The coordinator uses this to drive its `rfcommRxBytes` counter
///   for diagnostics.
/// - `onClosed` — fired when the channel closes (either side).
///
/// All state mutation is serialized through an internal NSLock so the
/// callbacks can fire from any thread without races.
final class RFCOMMChannelDelegate: NSObject, @unchecked Sendable {

    enum OpenStatus {
        case success
        case failed(IOReturn)
        case timeout
    }

    /// Fired for every RX data callback with the number of bytes received.
    /// Set by the coordinator before kicking off the async open.
    var onData: ((Int) -> Void)?

    /// Fired when the RFCOMM channel closes. Set by the coordinator before
    /// kicking off the async open.
    var onClosed: (() -> Void)?

    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<OpenStatus, Never>?
    private var openResolved = false

    /// Suspend until `rfcommChannelOpenComplete:status:` fires, or `timeout`
    /// seconds elapse, whichever comes first. Safe to call exactly once per
    /// delegate instance — the open continuation can only resolve once.
    func awaitOpenComplete(timeout: TimeInterval) async -> OpenStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<OpenStatus, Never>) in
            lock.lock()
            if openResolved {
                lock.unlock()
                cont.resume(returning: .failed(kIOReturnAborted))
                return
            }
            openContinuation = cont
            lock.unlock()

            // Schedule a hard timeout that races against the delegate
            // callback. Whichever fires first wins; resolveOpen() is
            // idempotent.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveOpen(.timeout)
            }
        }
    }

    private func resolveOpen(_ status: OpenStatus) {
        lock.lock()
        if openResolved {
            lock.unlock()
            return
        }
        openResolved = true
        let cont = openContinuation
        openContinuation = nil
        lock.unlock()
        cont?.resume(returning: status)
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate (informal)

    @objc func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                          status error: IOReturn) {
        if error == kIOReturnSuccess {
            resolveOpen(.success)
        } else {
            resolveOpen(.failed(error))
        }
    }

    @objc func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                  data dataPointer: UnsafeMutableRawPointer!,
                                  length dataLength: Int) {
        onData?(dataLength)
    }

    @objc func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        // If we close before the open callback fires (e.g. immediate
        // failure), make sure any pending awaiter still gets a result.
        resolveOpen(.failed(kIOReturnAborted))
        onClosed?()
    }

    @objc func rfcommChannelControlSignalsChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
    @objc func rfcommChannelFlowControlChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
    @objc func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                           refcon: UnsafeMutableRawPointer!,
                                           status error: IOReturn) {}
    @objc func rfcommChannelQueueSpaceAvailable(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
}
#endif
