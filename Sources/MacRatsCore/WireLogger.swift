import Foundation

/// Append-only wire-level byte log.
///
/// Writes a one-line timestamped hex+ASCII record for every direction
/// of traffic on the transport. Designed for VoiceOver-friendly bench
/// debugging: the user enables wire logging in Preferences, opens
/// Terminal, runs `tail -f ~/Downloads/MacRats/wire.log`, and VoiceOver
/// reads each new line as it arrives.
///
/// Default location: `~/Downloads/MacRats/wire.log`. Rotates at 10 MB
/// to `wire.log.old`. Each append is a single `write(2)` call so the
/// file can be tailed safely while MacRats is running.
///
/// Line format (one per direction per write):
///
/// ```
/// HH:mm:ss.SSS TX   39 bytes  5b 53 4f 42 5d dd 00 00 00 fe 00 10 ...  | [SOB]............
/// ```
///
/// Column widths are fixed so VoiceOver reads each column coherently.
public final class WireLogger: @unchecked Sendable {

    // MARK: - Configuration

    public let url: URL
    public let rotateAtBytes: Int64

    /// Maximum bytes of a chunk to print per line. Chunks longer than
    /// this are truncated with a `... N more bytes` suffix. Default is
    /// large enough to show a full DDT2 encoded frame (~200-300 bytes).
    public let maxBytesPerLine: Int

    // MARK: - State

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let timeFormatter: DateFormatter

    // MARK: - Init

    public init(url: URL,
                rotateAtBytes: Int64 = 10 * 1024 * 1024,
                maxBytesPerLine: Int = 512) {
        self.url = url
        self.rotateAtBytes = rotateAtBytes
        self.maxBytesPerLine = maxBytesPerLine
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        self.timeFormatter = f
    }

    /// Default logger under `~/Downloads/MacRats/wire.log`. Creates
    /// the directory if necessary. Throws on filesystem errors.
    public static func defaultLogger() throws -> WireLogger {
        let fm = FileManager.default
        let downloads = try fm.url(for: .downloadsDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
        let dir = downloads.appendingPathComponent("MacRats", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fileURL = dir.appendingPathComponent("wire.log")
        return WireLogger(url: fileURL)
    }

    // MARK: - Append

    /// Append a line for the given direction and data chunk. Best-
    /// effort: errors are silently swallowed (wire logging is
    /// diagnostic and should never interfere with the real transport
    /// flow).
    public func log(_ direction: String, _ data: Data) {
        do {
            try logThrowing(direction, data)
        } catch {
            FileHandle.standardError.write("WireLogger error: \(error.localizedDescription)\n".data(using: .utf8) ?? Data())
        }
    }

    /// Throwing variant for tests.
    public func logThrowing(_ direction: String, _ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let line = formatLine(direction: direction, data: data)
        let bytes = line.data(using: .utf8) ?? Data()

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)

        // Rotate if we've grown past the threshold.
        if let size = try? handle.offset(), Int64(size) >= rotateAtBytes {
            try rotate()
        }
    }

    /// Build one log line from a direction tag and a data chunk.
    /// Exposed for tests.
    internal func formatLine(direction: String, data: Data) -> String {
        let timestamp = timeFormatter.string(from: Date())
        let paddedDirection = direction.padding(toLength: 2, withPad: " ", startingAt: 0)
        let byteCount = data.count

        let chunkToFormat: Data
        let truncated: Bool
        if byteCount > maxBytesPerLine {
            chunkToFormat = data.prefix(maxBytesPerLine)
            truncated = true
        } else {
            chunkToFormat = data
            truncated = false
        }

        let hex = chunkToFormat.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ascii = String(decoding: chunkToFormat.map { byte -> UInt8 in
            (byte >= 0x20 && byte < 0x7F) ? byte : 0x2E // '.'
        }, as: UTF8.self)

        let suffix = truncated ? "  ...(\(byteCount - maxBytesPerLine) more bytes)" : ""
        return "\(timestamp) \(paddedDirection) \(byteCount) bytes  \(hex)  | \(ascii)\(suffix)\n"
    }

    // MARK: - Rotate / delete

    /// Rotate the log — rename to `.old`. Called automatically when
    /// the file exceeds `rotateAtBytes`. Exposed for tests.
    public func rotate() throws {
        let oldURL = url.appendingPathExtension("old")
        if fileManager.fileExists(atPath: oldURL.path) {
            try fileManager.removeItem(at: oldURL)
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.moveItem(at: url, to: oldURL)
        }
        fileManager.createFile(atPath: url.path, contents: nil)
    }

    /// Delete both active and rotated files. For tests and for a
    /// future "Clear Wire Log" menu item.
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
}
