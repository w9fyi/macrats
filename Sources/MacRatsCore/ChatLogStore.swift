import Foundation

/// Append-only on-disk chat log.
///
/// Writes one JSON object per line (NDJSON) to a file in the MacRats
/// application support directory. Designed so that:
///
/// - Each append is atomic at the line level — we write the full JSON
///   line (with trailing newline) in a single `write` call.
/// - The file can be tailed with `tail -f` from the command line.
/// - Recovering from a crash or power loss loses at most the
///   in-flight line.
/// - Loading history on launch only needs to read the tail of the
///   file — we don't re-parse the entire log.
/// - Rotating the log when it grows past a size threshold is a local
///   operation (move file, continue writing).
///
/// Persistence wire format (one per line):
///
/// ```json
/// {"id":"<uuid>","ts":1234567890.123,"kind":"message",
///  "s":"W9FYI","d":"CQCQCQ","text":"Hi","out":false}
/// ```
///
/// The `kind` field encodes the case as a tagged enum so future kinds
/// (gps fix, file transfer) don't break old files.
public final class ChatLogStore: @unchecked Sendable {

    // MARK: - Configuration

    /// Absolute path to the log file.
    public let url: URL

    /// Rotate when the file exceeds this many bytes. Default 10 MB.
    /// Set to `.max` to disable rotation.
    public let rotateAtBytes: Int64

    /// Maximum number of messages returned by `loadRecent()`. Default 500.
    public let maxRecentCount: Int

    // MARK: - State

    private let lock = NSLock()
    private let fileManager = FileManager.default

    // MARK: - Errors

    public enum StoreError: Error, LocalizedError {
        case writeFailed(String)
        case rotateFailed(String)

        public var errorDescription: String? {
            switch self {
            case .writeFailed(let msg):  return "Chat log write failed: \(msg)"
            case .rotateFailed(let msg): return "Chat log rotate failed: \(msg)"
            }
        }
    }

    // MARK: - Init

    public init(url: URL,
                rotateAtBytes: Int64 = 10 * 1024 * 1024,
                maxRecentCount: Int = 500) {
        self.url = url
        self.rotateAtBytes = rotateAtBytes
        self.maxRecentCount = maxRecentCount
    }

    /// Default store under `~/Library/Application Support/MacRats/chat.log.jsonl`,
    /// or the user's configured subdirectory. Creates the directory if
    /// necessary.
    public static func defaultStore(subdirectory: String = "") throws -> ChatLogStore {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)
        var dir = support.appendingPathComponent("MacRats", isDirectory: true)
        if !subdirectory.isEmpty {
            dir = dir.appendingPathComponent(subdirectory, isDirectory: true)
        }
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fileURL = dir.appendingPathComponent("chat.log.jsonl")
        return ChatLogStore(url: fileURL)
    }

    // MARK: - Append

    /// Append one message to the log file. Thread-safe; silently
    /// swallows errors after logging to stderr — the chat log is a
    /// best-effort persistence layer and the in-memory log is the
    /// source of truth during a session.
    public func append(_ message: ChatMessage) {
        do {
            try appendThrowing(message)
        } catch {
            FileHandle.standardError.write("ChatLogStore append failed: \(error.localizedDescription)\n".data(using: .utf8) ?? Data())
        }
    }

    /// Append one message, throwing on any error. Primarily for tests.
    public func appendThrowing(_ message: ChatMessage) throws {
        lock.lock()
        defer { lock.unlock() }

        // Make sure the directory exists (in case it was deleted after
        // init).
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Ensure the file exists.
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let record = WireRecord(from: message)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var jsonData = try encoder.encode(record)
        jsonData.append(0x0A) // newline

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw StoreError.writeFailed("open: \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: jsonData)
        } catch {
            throw StoreError.writeFailed("write: \(error.localizedDescription)")
        }

        // Rotate if we've grown past the threshold.
        if let currentSize = try? handle.offset(), Int64(currentSize) >= rotateAtBytes {
            try rotate()
        }
    }

    // MARK: - Load

    /// Read the last `maxRecentCount` messages from the log. Used at
    /// startup to repopulate the in-memory chat view.
    ///
    /// Reads the file once, parses every line, keeps the last N valid
    /// records in a rolling window. Lines that fail to parse are
    /// silently dropped (forward-compatible with future kinds).
    public func loadRecent() -> [ChatMessage] {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else { return [] }

        // Split on newlines. NDJSON means we can scan linearly without
        // trying to parse the file as one big JSON object.
        let decoder = JSONDecoder()
        var recent: [ChatMessage] = []
        recent.reserveCapacity(maxRecentCount)

        for line in data.split(separator: 0x0A) {
            guard !line.isEmpty else { continue }
            guard let record = try? decoder.decode(WireRecord.self, from: Data(line)) else {
                continue
            }
            recent.append(record.toChatMessage())
            if recent.count > maxRecentCount {
                recent.removeFirst(recent.count - maxRecentCount)
            }
        }

        return recent
    }

    // MARK: - Rotate

    /// Rotate the log — rename the current file to `<name>.old` and
    /// start a fresh file on the next append. Any previous `.old` file
    /// is overwritten.
    ///
    /// Internal — called automatically from `appendThrowing(_:)` when
    /// the file grows past `rotateAtBytes`. Exposed for tests.
    public func rotate() throws {
        let oldURL = url.appendingPathExtension("old")
        if fileManager.fileExists(atPath: oldURL.path) {
            try fileManager.removeItem(at: oldURL)
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.moveItem(at: url, to: oldURL)
        }
        // Recreate the empty file so subsequent appends don't re-check.
        fileManager.createFile(atPath: url.path, contents: nil)
    }

    /// Delete both the current log and the rotated backup. Used by
    /// tests and by the "Clear Chat History" menu item.
    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let oldURL = url.appendingPathExtension("old")
        if fileManager.fileExists(atPath: oldURL.path) {
            try fileManager.removeItem(at: oldURL)
        }
    }

    // MARK: - Wire format

    /// Tagged Codable record representing one chat message on disk.
    ///
    /// Deliberately a separate type from `ChatMessage` so we can evolve
    /// the wire format independently of the in-memory struct. The only
    /// cost is a small conversion step on append/load.
    private struct WireRecord: Codable {

        enum Kind: String, Codable {
            case message
            case pingRequest
            case pingResponse
            case status
            case systemEvent
        }

        let id: String
        let ts: Double  // seconds since 1970
        let kind: Kind
        let s: String   // sStation
        let d: String   // dStation
        let text: String
        let out: Bool
        let statusCode: Int?   // present only when kind == status
        let replyText: String? // present only when kind == pingResponse

        init(from message: ChatMessage) {
            self.id = message.id.uuidString
            self.ts = message.timestamp.timeIntervalSince1970
            self.s = message.sStation
            self.d = message.dStation
            self.text = message.text
            self.out = message.outgoing

            switch message.kind {
            case .message:
                self.kind = .message
                self.statusCode = nil
                self.replyText = nil
            case .pingRequest:
                self.kind = .pingRequest
                self.statusCode = nil
                self.replyText = nil
            case .pingResponse(let reply):
                self.kind = .pingResponse
                self.statusCode = nil
                self.replyText = reply
            case .status(let status):
                self.kind = .status
                self.statusCode = status.rawValue
                self.replyText = nil
            case .systemEvent:
                self.kind = .systemEvent
                self.statusCode = nil
                self.replyText = nil
            }
        }

        func toChatMessage() -> ChatMessage {
            let uuid = UUID(uuidString: id) ?? UUID()
            let timestamp = Date(timeIntervalSince1970: ts)
            let chatKind: ChatMessage.Kind
            switch kind {
            case .message:
                chatKind = .message
            case .pingRequest:
                chatKind = .pingRequest
            case .pingResponse:
                chatKind = .pingResponse(replyText: replyText ?? "")
            case .status:
                let resolved = StationStatus(rawValue: statusCode ?? 0) ?? .unknown
                chatKind = .status(resolved)
            case .systemEvent:
                chatKind = .systemEvent
            }
            return ChatMessage(id: uuid,
                               timestamp: timestamp,
                               kind: chatKind,
                               sStation: s,
                               dStation: d,
                               text: text,
                               outgoing: out)
        }
    }
}
