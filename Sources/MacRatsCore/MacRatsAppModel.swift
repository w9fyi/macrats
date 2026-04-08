import Foundation

/// The keystone view-model for the MacRats SwiftUI app.
///
/// Owns the `SessionManager`, tracks heard stations, accumulates the
/// chat log, holds the current `MacRatsSettings`, and exposes high-level
/// intents the UI calls (`connect()`, `sendChatMessage(_:to:)`,
/// `pingStation(_:)`, etc.).
///
/// Intentionally does NOT import SwiftUI — all SwiftUI views consume
/// this model via `@ObservedObject` from their own files in the app
/// target. Keeping SwiftUI out of MacRatsCore lets this be tested with
/// the Swift Testing framework under `swift test` without any UI
/// runtime.
///
/// This class is `@unchecked Sendable` because:
///
/// - Its mutable state (`chatMessages`, `stations`, `settings`,
///   `connectionStatus`) is only written while holding the internal
///   `NSLock`.
/// - The observation callback (`onStateChanged`) is invoked synchronously
///   while the lock is held but only AFTER the state has been updated —
///   UI layers are expected to hop to the main actor themselves before
///   reading the published snapshots via `snapshot()`.
public final class MacRatsAppModel: @unchecked Sendable {

    // MARK: - Observation

    /// Callback fired after ANY state change (new chat message, station
    /// update, settings change, connection status change). SwiftUI views
    /// wrap this in a Combine publisher or `@ObservedObject` shim in
    /// their own file.
    public var onStateChanged: (@Sendable () -> Void)?

    /// Log callback for diagnostic output. If nil, messages are silently
    /// dropped. SwiftUI wires this to a rolling buffer the debug view
    /// can display.
    public var logHandler: (@Sendable (String) -> Void)?

    // MARK: - Persisted + runtime state

    private let lock = NSLock()

    private var _settings: MacRatsSettings
    private let stationTracker: HeardStationTracker
    private var _chatMessages: [ChatMessage] = []
    private var _connectionStatus: TransportStatus = .disconnected
    private let maxChatHistory: Int

    // MARK: - Session plumbing

    private var manager: SessionManager?
    private var chatSession: ChatSession?
    private var chatDelegateShim: ChatDelegateShim?

    /// The currently active file transfer session, if any. MacRats
    /// supports one transfer at a time in v0.1 — start a second one
    /// while the first is running and you get an error.
    private var fileTransferSession: FileTransferSession?
    private var fileTransferDelegateShim: FileTransferDelegateShim?

    /// Fixed session id used for the single-file-at-a-time file
    /// transfer slot. Both peers must use the same id (see the
    /// StatefulSession / FileTransferSession docs — MacRats does not
    /// implement the session open handshake, so ids are agreed out
    /// of band via this constant).
    public static let fileTransferSessionID: UInt8 = 3

    /// Throttle for progress-reporting chat-log entries. We only
    /// emit a new system-event line every 10% of the transfer, so a
    /// 1 MB push doesn't fill the chat log with 200 progress lines.
    private var lastProgressPercentLogged: Int = -10

    /// Where settings are persisted. Injected for testability.
    public let settingsURL: URL?

    // MARK: - Init

    /// Optional persistent on-disk chat log. `nil` = no persistence
    /// (useful for tests). When set, new messages are appended to the
    /// store in real time and `loadHistory()` can repopulate the
    /// in-memory log from disk on startup.
    private let chatLogStore: ChatLogStore?

    /// Optional wire-level byte logger. Created lazily the first
    /// time wire logging is enabled, so users who never turn it on
    /// never get an empty log file sitting in ~/Downloads/MacRats/.
    private var wireLogger: WireLogger?

    public init(settings: MacRatsSettings = MacRatsSettings(),
                settingsURL: URL? = nil,
                chatLogStore: ChatLogStore? = nil,
                maxChatHistory: Int = 500) {
        self._settings = settings
        self.settingsURL = settingsURL
        self.chatLogStore = chatLogStore
        self.maxChatHistory = maxChatHistory
        self.stationTracker = HeardStationTracker()
    }

    /// Convenience: load settings from disk (or defaults), wire up the
    /// default chat log store under the user's application support
    /// directory, and repopulate the chat history from disk.
    public static func loadFromDisk() -> MacRatsAppModel {
        let loaded = MacRatsSettings.load()
        let store = try? ChatLogStore.defaultStore(subdirectory: loaded.chatLogSubdirectory)
        let model = MacRatsAppModel(settings: loaded, chatLogStore: store)
        model.loadHistory()
        return model
    }

    /// Repopulate the in-memory chat log from the persistent store.
    /// Safe to call multiple times — each call replaces the history
    /// with the store's current contents.
    public func loadHistory() {
        guard let chatLogStore else { return }
        let history = chatLogStore.loadRecent()
        lock.lock()
        _chatMessages = history
        lock.unlock()
        notifyObservers()
    }

    // MARK: - Public snapshots (thread-safe reads)

    /// Atomic snapshot of everything the UI might want to show.
    public struct Snapshot: Sendable {
        public let settings: MacRatsSettings
        public let connectionStatus: TransportStatus
        public let chatMessages: [ChatMessage]
        public let stations: [HeardStation]
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        let settings = _settings
        let status = _connectionStatus
        let messages = _chatMessages
        lock.unlock()
        let stations = stationTracker.sortedSnapshot()
        return Snapshot(settings: settings,
                        connectionStatus: status,
                        chatMessages: messages,
                        stations: stations)
    }

    /// Current settings (for config sheets).
    public var settings: MacRatsSettings {
        lock.lock()
        defer { lock.unlock() }
        return _settings
    }

    /// Current transport status.
    public var connectionStatus: TransportStatus {
        lock.lock()
        defer { lock.unlock() }
        return _connectionStatus
    }

    /// Current chat log.
    public var chatMessages: [ChatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return _chatMessages
    }

    /// Current heard-stations list, most recent first.
    public var heardStations: [HeardStation] {
        stationTracker.sortedSnapshot()
    }

    // MARK: - Settings management

    /// Replace settings. Disconnects if the connection-related fields
    /// changed, so the next `connect()` picks up the new config.
    public func updateSettings(_ newSettings: MacRatsSettings) {
        var needsDisconnect = false
        lock.lock()
        let old = _settings
        if old.connectionKind != newSettings.connectionKind
            || old.serialDevicePath != newSettings.serialDevicePath
            || old.serialBaudRate != newSettings.serialBaudRate
            || old.bluetoothRadioAddress != newSettings.bluetoothRadioAddress
            || old.tcpHost != newSettings.tcpHost
            || old.tcpPort != newSettings.tcpPort {
            needsDisconnect = true
        }
        _settings = newSettings
        lock.unlock()

        if needsDisconnect {
            disconnect()
        }

        // Update the chat session's ping reply text if it's live.
        if let chatSession {
            chatSession.pingReplyText = newSettings.pingReplyText
        }

        // Update the session manager's wire tuning live so warmup
        // changes take effect on the next outbound frame. Only applies
        // to serial connections — TCP always uses the NET profile.
        if let manager,
           newSettings.connectionKind == .serial || newSettings.connectionKind == .bluetooth {
            manager.wireTuning = SessionManager.WireTuning(
                warmupLength: newSettings.warmupLength,
                warmupTimeoutSeconds: newSettings.warmupTimeoutSeconds,
                forceDelaySeconds: newSettings.forceDelaySeconds
            )
        }

        // Persist.
        do {
            try newSettings.save(to: settingsURL)
        } catch {
            log("failed to save settings: \(error.localizedDescription)")
        }

        notifyObservers()
    }

    // MARK: - Connection lifecycle

    /// Build a transport from the current settings and connect it.
    /// Throws if settings are invalid. Idempotent — calling while already
    /// connected is a no-op.
    ///
    /// For the `.bluetooth` connection kind, `BluetoothRFCOMMTransport`
    /// handles its own IOBluetooth bring-up asynchronously — callers do
    /// not need to pre-resolve anything. For USB the configured device
    /// path is opened directly.
    public func connect() throws {
        lock.lock()
        if _connectionStatus == .connected || _connectionStatus == .connecting {
            lock.unlock()
            return
        }
        let settings = _settings
        lock.unlock()

        if let error = settings.connectionValidationError() {
            log("connect refused: \(error)")
            throw SessionError.notAttachedToManager // placeholder; UI reads the validation error separately
        }

        let transport: RadioTransport
        switch settings.connectionKind {
        case .disconnected:
            throw SessionError.notAttachedToManager
        case .serial:
            transport = USBSerialTransport(devicePath: settings.serialDevicePath,
                                           baudRate: settings.serialBaudRate)
        case .bluetooth:
            // The Bluetooth path uses BluetoothRFCOMMTransport, which
            // talks to RFCOMM channel 2 directly via IOBluetooth. The
            // `/dev/cu.*` file is intentionally NOT used — on the
            // TH-D75 the kernel BT serial driver is wired to a
            // different endpoint than the radio's DV data TNC, so
            // bytes written to `cu.*` go nowhere and reads never
            // produce anything. The transport handles its own
            // bring-up; the caller does not need to pre-resolve a
            // path.
            #if canImport(IOBluetooth)
            let btAddress = settings.bluetoothRadioAddress
            guard !btAddress.isEmpty else {
                log("connect refused: .bluetooth kind but no bluetoothRadioAddress in settings")
                throw SessionError.notAttachedToManager
            }
            let btTransport = BluetoothRFCOMMTransport(address: btAddress)
            // Forward bring-up trace to the app log so MacRatsStore can
            // mirror it into ~/Downloads/MacRats/bluetooth.log.
            btTransport.onDiagnosticLine = { [weak self] line in
                self?.log("[BT] " + line)
            }
            transport = btTransport
            #else
            log("connect refused: .bluetooth kind but IOBluetooth unavailable on this platform")
            throw SessionError.notAttachedToManager
            #endif
        case .tcpLoopback:
            if settings.tcpHost.isEmpty {
                transport = TCPLoopbackTransport(mode: .server(port: settings.tcpPort))
            } else {
                transport = TCPLoopbackTransport(mode: .client(host: settings.tcpHost,
                                                               port: settings.tcpPort))
            }
        case .tcpRatflector:
            // Ratflector transport runs the text-based authentication
            // handshake before handing bytes to the DDT2 layer.
            // Callsign comes from settings; password is optional and
            // only used if the server responds with code 101 + 102.
            // Most public ratflectors send code 100 (no auth) and
            // the password is unused.
            let ratflectorPassword: String? = settings.ratflectorPassword.isEmpty
                ? nil
                : settings.ratflectorPassword
            transport = RatflectorTransport(
                host: settings.tcpHost,
                port: settings.tcpPort,
                callsign: settings.callsign.isEmpty ? nil : settings.callsign,
                password: ratflectorPassword
            )
        }

        // Translate settings into the SessionManager's wire-tuning
        // profile. For .tcpLoopback and .tcpRatflector we force-disable
        // the warmup frame (there's no radio on the other end that
        // benefits from it), regardless of what the user set — it's
        // just wasted bytes on the wire.
        let wireTuning: SessionManager.WireTuning
        switch settings.connectionKind {
        case .serial, .bluetooth:
            wireTuning = SessionManager.WireTuning(
                warmupLength: settings.warmupLength,
                warmupTimeoutSeconds: settings.warmupTimeoutSeconds,
                forceDelaySeconds: settings.forceDelaySeconds
            )
        case .tcpLoopback, .tcpRatflector, .disconnected:
            wireTuning = .net
        }

        let manager = SessionManager(callsign: settings.callsign,
                                     transport: transport,
                                     wireTuning: wireTuning)
        let chat = ChatSession(pingReplyText: settings.pingReplyText)
        let shim = ChatDelegateShim(owner: self)
        chat.delegate = shim
        manager.add(chat, id: 1)

        // Wire logging: if enabled in settings, attach a WireLogger
        // that writes to ~/Downloads/MacRats/wire.log. The user can
        // then `tail -f` that file in Terminal while running a bench
        // test. Off by default.
        if settings.wireLoggingEnabled {
            if wireLogger == nil {
                wireLogger = try? WireLogger.defaultLogger()
            }
            if let wireLogger {
                manager.wireLogHandler = { [weak wireLogger] direction, data in
                    wireLogger?.log(direction, data)
                }
                log("wire logging enabled — tailing ~/Downloads/MacRats/wire.log")
            }
        }

        manager.logHandler = { [weak self] msg in
            self?.log(msg)
            self?.handleTransportLogMessage(msg)
        }
        manager.onInboundFrame = { [weak self] frame in
            self?.stationTracker.note(from: frame.sStation)
            self?.notifyObservers()
        }

        self.manager = manager
        self.chatSession = chat
        self.chatDelegateShim = shim

        do {
            try manager.connect()
            append(systemEvent: "Connecting to \(settings.connectionKind.displayName)…")
        } catch {
            setConnectionStatus(.failed(error.localizedDescription))
            append(systemEvent: "Connect failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Disconnect the current session, if any. Idempotent.
    ///
    /// Sends the configured sign-off message (if any) on the existing
    /// connection BEFORE tearing it down. If the connection is already
    /// dead this send is silently skipped.
    public func disconnect() {
        // Cancel any in-progress file transfer so its worker thread
        // exits cleanly. forceClose() drops queued and outstanding
        // blocks immediately rather than trying to drain them over a
        // transport that's about to close.
        lock.lock()
        let activeTransfer = fileTransferSession
        fileTransferSession = nil
        fileTransferDelegateShim = nil
        lock.unlock()
        activeTransfer?.forceClose()

        sendSignOffIfNeeded()
        manager?.disconnect()
        manager = nil
        chatSession = nil
        chatDelegateShim = nil
        setConnectionStatus(.disconnected)
        append(systemEvent: "Disconnected.")
    }

    /// Send the configured sign-on chat message as a CQCQCQ broadcast,
    /// if one is configured and we have an open chat session. Called
    /// once automatically when the transport transitions to
    /// `.connected`.
    private func sendSignOnIfNeeded() {
        let text = snapshot().settings.signOnMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let chatSession else { return }
        do {
            try chatSession.sendMessage(text, to: "CQCQCQ")
            let myCall = snapshot().settings.callsign
            append(ChatMessage(kind: .message,
                               sStation: myCall,
                               dStation: "CQCQCQ",
                               text: text,
                               outgoing: true))
        } catch {
            log("sign-on send failed: \(error.localizedDescription)")
        }
    }

    /// Send the configured sign-off chat message as a CQCQCQ broadcast,
    /// if one is configured and we have an open chat session. Called
    /// once from `disconnect()` BEFORE the transport is torn down.
    private func sendSignOffIfNeeded() {
        // Only attempt if we're actually connected — otherwise the
        // manager.send() call will error out and we have nothing to
        // say anyway.
        guard _connectionStatus == .connected else { return }
        let text = snapshot().settings.signOffMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let chatSession else { return }
        do {
            try chatSession.sendMessage(text, to: "CQCQCQ")
            let myCall = snapshot().settings.callsign
            append(ChatMessage(kind: .message,
                               sStation: myCall,
                               dStation: "CQCQCQ",
                               text: text,
                               outgoing: true))
            // Delay so the bytes actually reach the transport layer
            // before we cancel it. TCP's NWConnection.cancel() will
            // short-circuit any queued outbound data, so we need a
            // flush window. Serial radios additionally need tail-out
            // time for the TX chain: the D-Rats docs and TH-D75
            // manual both describe tens-to-hundreds of milliseconds
            // of TX delay. 500ms is a conservative value that works
            // for both transport types.
            let postSignoffDelay: TimeInterval =
                (manager?.transport is USBSerialTransport) ? 0.5 : 0.15
            Thread.sleep(forTimeInterval: postSignoffDelay)
        } catch {
            log("sign-off send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Chat intents

    /// Send a chat message to the given destination (CQCQCQ by default).
    public func sendChatMessage(_ text: String, to dest: String = "CQCQCQ") throws {
        guard let chatSession else {
            throw SessionError.notAttachedToManager
        }
        try chatSession.sendMessage(text, to: dest)

        // Echo locally so the user sees their own message in the log.
        let myCall = snapshot().settings.callsign
        append(ChatMessage(kind: .message,
                           sStation: myCall,
                           dStation: dest,
                           text: text,
                           outgoing: true))
    }

    /// Ping another station.
    public func pingStation(_ callsign: String) throws {
        guard let chatSession else {
            throw SessionError.notAttachedToManager
        }
        try chatSession.pingStation(callsign)
        let myCall = snapshot().settings.callsign
        append(ChatMessage(kind: .pingRequest,
                           sStation: myCall,
                           dStation: callsign,
                           text: "Ping",
                           outgoing: true))
    }

    /// Broadcast our current station status.
    public func broadcastStatus(_ status: StationStatus, message: String) throws {
        guard let chatSession else {
            throw SessionError.notAttachedToManager
        }
        chatSession.currentStatus = status
        chatSession.currentStatusMessage = message
        try chatSession.advertise(status: status, message: message)
    }

    /// Broadcast a GPS position beacon using the fixed coordinates
    /// from settings. Returns `.notAttachedToManager` if we're not
    /// currently connected. Returns a "no fixed position" error if
    /// the user hasn't configured `fixedLatitude` / `fixedLongitude`.
    public func broadcastGPSBeacon() throws {
        guard let chatSession else {
            throw SessionError.notAttachedToManager
        }
        let s = snapshot().settings
        guard let lat = s.fixedLatitude, let lon = s.fixedLongitude else {
            throw SessionError.notAttachedToManager
        }
        try chatSession.sendGPSBeacon(latitude: lat,
                                      longitude: lon,
                                      comment: s.gpsComment)

        // Echo locally so the user sees their own beacon in the log,
        // same way sendChatMessage echoes outgoing chat.
        append(ChatMessage(kind: .gpsFix(latitude: lat, longitude: lon),
                           sStation: s.callsign,
                           dStation: "CQCQCQ",
                           text: s.gpsComment.isEmpty ? "Position fix" : s.gpsComment,
                           outgoing: true))
    }

    // MARK: - File transfer

    public enum FileTransferModelError: Error, LocalizedError {
        case alreadyActive
        case notConnected
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyActive:
                return "A file transfer is already in progress. Cancel it or wait for it to finish before starting another."
            case .notConnected:
                return "Not connected. Connect to a radio, TCP loopback, or ratflector before starting a file transfer."
            case .underlying(let msg):
                return msg
            }
        }
    }

    /// Begin sending a file to a remote peer. Creates a sender
    /// `FileTransferSession`, registers it at the reserved file
    /// transfer session id, and starts the D-Rats file wire protocol.
    /// Progress + completion are surfaced as system events in the
    /// chat log. Only one transfer (send OR receive) can be active
    /// at a time — starting a second one while the first is running
    /// throws `alreadyActive`.
    public func sendFile(url: URL, to remoteStation: String) throws {
        guard let manager else {
            throw FileTransferModelError.notConnected
        }

        lock.lock()
        if fileTransferSession != nil {
            lock.unlock()
            throw FileTransferModelError.alreadyActive
        }
        let session = FileTransferSession(remoteStation: remoteStation,
                                           role: .sender)
        let shim = FileTransferDelegateShim(owner: self)
        session.fileDelegate = shim
        fileTransferSession = session
        fileTransferDelegateShim = shim
        lastProgressPercentLogged = -10
        lock.unlock()

        manager.add(session, id: Self.fileTransferSessionID)

        do {
            try session.sendFile(url: url)
            appendSystemEvent("Sending \(url.lastPathComponent) to \(remoteStation)…")
        } catch {
            clearFileTransfer()
            appendSystemEvent("File send failed: \(error.localizedDescription)")
            throw FileTransferModelError.underlying(error.localizedDescription)
        }
    }

    /// Arm MacRats to receive an incoming file from a remote peer.
    /// The caller supplies the station callsign (so we know who to
    /// expect) and a directory to save the received file into. The
    /// session stays armed until a file arrives, the user cancels,
    /// or the transport disconnects.
    public func prepareToReceiveFile(from remoteStation: String,
                                      saveTo directory: URL) throws {
        guard let manager else {
            throw FileTransferModelError.notConnected
        }

        lock.lock()
        if fileTransferSession != nil {
            lock.unlock()
            throw FileTransferModelError.alreadyActive
        }
        let session = FileTransferSession(remoteStation: remoteStation,
                                           role: .receiver)
        let shim = FileTransferDelegateShim(owner: self)
        session.fileDelegate = shim
        fileTransferSession = session
        fileTransferDelegateShim = shim
        lastProgressPercentLogged = -10
        lock.unlock()

        manager.add(session, id: Self.fileTransferSessionID)

        do {
            try session.startReceiving(saveTo: directory)
            appendSystemEvent("Waiting for file from \(remoteStation)…")
        } catch {
            clearFileTransfer()
            appendSystemEvent("File receive arm failed: \(error.localizedDescription)")
            throw FileTransferModelError.underlying(error.localizedDescription)
        }
    }

    /// Cancel any in-progress or pending file transfer. No-op if
    /// nothing is active. Used by the Cancel button and on transport
    /// disconnect.
    public func cancelFileTransfer() {
        lock.lock()
        let session = fileTransferSession
        lock.unlock()

        guard let session else { return }

        // forceClose gets the worker to exit immediately, which then
        // fires the didClose or didFail delegate callback that in
        // turn calls clearFileTransfer() to release the slot.
        session.forceClose()
        appendSystemEvent("File transfer cancelled.")
    }

    /// Called by the delegate shim after the session has reached a
    /// terminal state (complete, failed, or cancelled). Unregisters
    /// the session from the manager and nils out our slot.
    fileprivate func clearFileTransfer() {
        lock.lock()
        let session = fileTransferSession
        fileTransferSession = nil
        fileTransferDelegateShim = nil
        lock.unlock()

        if let session, let manager {
            manager.remove(session)
        }
    }

    /// Called by the delegate shim on every progress update. Throttles
    /// to 10% increments so the chat log doesn't drown in updates.
    fileprivate func handleFileTransferProgress(_ session: FileTransferSession,
                                                  bytesReceived: Int,
                                                  totalBytes: Int) {
        guard totalBytes > 0 else { return }
        let percent = (bytesReceived * 100) / totalBytes

        lock.lock()
        guard percent >= lastProgressPercentLogged + 10 else {
            lock.unlock()
            return
        }
        lastProgressPercentLogged = percent
        lock.unlock()

        let verb = session.role == .sender ? "Sent" : "Received"
        appendSystemEvent("\(verb) \(percent)%")
    }

    fileprivate func handleFileTransferBegin(filename: String, total: Int) {
        // "Sending x" already logged by sendFile(); receiver side wants
        // a begin line now that it knows what's coming.
        lock.lock()
        let isReceiver = (fileTransferSession?.role == .receiver)
        lock.unlock()
        if isReceiver {
            appendSystemEvent("Incoming file: \(filename) (\(total) bytes)")
        }
    }

    fileprivate func handleFileTransferComplete(_ session: FileTransferSession, fileURL: URL) {
        let verb = session.role == .sender ? "Sent" : "Received"
        appendSystemEvent("\(verb) file: \(fileURL.lastPathComponent)")
        clearFileTransfer()
    }

    fileprivate func handleFileTransferFailed(_ session: FileTransferSession, reason: String) {
        appendSystemEvent("File transfer failed: \(reason)")
        clearFileTransfer()
    }

    /// Append a `.systemEvent` chat log entry. Used by file transfer
    /// progress reports and other internal events the user should see.
    private func appendSystemEvent(_ text: String) {
        append(ChatMessage(kind: .systemEvent,
                           sStation: "",
                           dStation: "",
                           text: text,
                           outgoing: false))
    }

    // MARK: - Internal state transitions

    fileprivate func handleIncomingMessage(_ text: String, from sStation: String, to dStation: String) {
        stationTracker.noteMessage(from: sStation)
        append(ChatMessage(kind: .message,
                           sStation: sStation,
                           dStation: dStation,
                           text: text,
                           outgoing: false))
    }

    fileprivate func handleIncomingPingRequest(from sStation: String, to dStation: String) {
        stationTracker.notePing(from: sStation)
        append(ChatMessage(kind: .pingRequest,
                           sStation: sStation,
                           dStation: dStation,
                           text: "Ping request",
                           outgoing: false))
    }

    fileprivate func handleIncomingPingResponse(from sStation: String, to dStation: String, replyText: String) {
        stationTracker.notePing(from: sStation)
        append(ChatMessage(kind: .pingResponse(replyText: replyText),
                           sStation: sStation,
                           dStation: dStation,
                           text: replyText,
                           outgoing: false))
    }

    fileprivate func handleIncomingStatus(from sStation: String, status: StationStatus, message: String) {
        stationTracker.noteStatus(from: sStation, status: status, message: message)
        append(ChatMessage(kind: .status(status),
                           sStation: sStation,
                           dStation: "CQCQCQ",
                           text: message,
                           outgoing: false))
    }

    fileprivate func handleIncomingGPSFix(_ fix: GPSBeacon.Fix) {
        stationTracker.noteGPSFix(from: fix.station,
                                  latitude: fix.latitude,
                                  longitude: fix.longitude,
                                  comment: fix.comment)
        // Display as a chat-log entry so the user sees the beacon
        // arrive. Comment is kept as the text so "KB4XYZ at QTH" shows
        // up in the chat view; if no comment, use a placeholder.
        let displayText = fix.comment.isEmpty
            ? "Position fix"
            : fix.comment
        append(ChatMessage(kind: .gpsFix(latitude: fix.latitude, longitude: fix.longitude),
                           sStation: fix.station,
                           dStation: "CQCQCQ",
                           text: displayText,
                           outgoing: false))
    }

    private func handleTransportLogMessage(_ message: String) {
        // Best-effort parsing of the manager's log strings to update
        // our connection status. The manager emits "transport status: X"
        // for every state change.
        if message.hasPrefix("transport status: ") {
            let state = String(message.dropFirst("transport status: ".count))
            switch state {
            case "connected":    setConnectionStatus(.connected)
            case "connecting":   setConnectionStatus(.connecting)
            case "disconnected": setConnectionStatus(.disconnected)
            default:
                if state.hasPrefix("failed") {
                    setConnectionStatus(.failed(state))
                }
            }
        }
    }

    private func setConnectionStatus(_ status: TransportStatus) {
        let previousStatus: TransportStatus
        lock.lock()
        previousStatus = _connectionStatus
        _connectionStatus = status
        lock.unlock()
        notifyObservers()

        // Fire the sign-on broadcast on the rising edge into .connected.
        // A direct equality check would miss the case where we go from
        // .connecting to .connected (which is the normal path), so we
        // fire whenever previous != .connected AND new == .connected.
        if previousStatus != .connected, status == .connected {
            sendSignOnIfNeeded()
        }
    }

    private func append(_ message: ChatMessage) {
        lock.lock()
        _chatMessages.append(message)
        if _chatMessages.count > maxChatHistory {
            _chatMessages.removeFirst(_chatMessages.count - maxChatHistory)
        }
        lock.unlock()
        // Persist to disk — best-effort, error just logs.
        chatLogStore?.append(message)
        notifyObservers()
    }

    private func append(systemEvent text: String) {
        append(ChatMessage(kind: .systemEvent,
                           sStation: "",
                           dStation: "",
                           text: text,
                           outgoing: false))
    }

    private func notifyObservers() {
        onStateChanged?()
    }

    private func log(_ message: String) {
        logHandler?(message)
    }
}

// MARK: - Chat delegate shim

/// Private shim — `ChatSession.Delegate` must be a class and `MacRatsAppModel`
/// is a class, but making the model conform to `Delegate` directly would
/// pollute its public API with the delegate method signatures. A thin
/// shim keeps the model's API clean.
private final class ChatDelegateShim: ChatSession.Delegate, @unchecked Sendable {
    weak var owner: MacRatsAppModel?

    init(owner: MacRatsAppModel) {
        self.owner = owner
    }

    func chatSession(_ session: ChatSession, didReceiveMessage text: String, from sStation: String, to dStation: String) {
        owner?.handleIncomingMessage(text, from: sStation, to: dStation)
    }

    func chatSession(_ session: ChatSession, didReceivePingRequest from: String, to dStation: String) {
        owner?.handleIncomingPingRequest(from: from, to: dStation)
    }

    func chatSession(_ session: ChatSession, didReceivePingResponse from: String, to dStation: String, replyText: String) {
        owner?.handleIncomingPingResponse(from: from, to: dStation, replyText: replyText)
    }

    func chatSession(_ session: ChatSession, didReceiveEchoRequest from: String, to dStation: String, payload: Data) {
        // v1.0 doesn't surface echo in the UI; v1.1 can add this.
    }

    func chatSession(_ session: ChatSession, didReceiveEchoResponse from: String, to dStation: String, payload: Data) {}

    func chatSession(_ session: ChatSession, didReceiveStationStatus from: String, status: StationStatus, message: String) {
        owner?.handleIncomingStatus(from: from, status: status, message: message)
    }

    func chatSession(_ session: ChatSession, didReceiveGPSFix fix: GPSBeacon.Fix) {
        owner?.handleIncomingGPSFix(fix)
    }
}

/// Delegate shim for `FileTransferSession`. Same pattern as
/// `ChatDelegateShim` — keeps `MacRatsAppModel`'s public surface free
/// of the delegate methods while still providing a long-lived target
/// for the session to hold.
private final class FileTransferDelegateShim: FileTransferSession.FileTransferDelegate, @unchecked Sendable {
    weak var owner: MacRatsAppModel?

    init(owner: MacRatsAppModel) {
        self.owner = owner
    }

    func fileTransferDidBegin(_ session: FileTransferSession,
                               filename: String,
                               totalBytes: Int) {
        owner?.handleFileTransferBegin(filename: filename, total: totalBytes)
    }

    func fileTransfer(_ session: FileTransferSession,
                       didProgressTo bytesReceived: Int,
                       of totalBytes: Int) {
        owner?.handleFileTransferProgress(session,
                                           bytesReceived: bytesReceived,
                                           totalBytes: totalBytes)
    }

    func fileTransferDidComplete(_ session: FileTransferSession, fileURL: URL) {
        owner?.handleFileTransferComplete(session, fileURL: fileURL)
    }

    func fileTransfer(_ session: FileTransferSession, didFailWith reason: String) {
        owner?.handleFileTransferFailed(session, reason: reason)
    }
}
