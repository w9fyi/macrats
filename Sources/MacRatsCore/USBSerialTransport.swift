import Foundation
import Darwin

/// A `RadioTransport` backed by a POSIX serial device file (`/dev/cu.*`).
///
/// Works with:
/// - USB CDC-ACM radios like the Kenwood TH-D75 (`/dev/cu.usbmodem*`)
/// - Silicon Labs CP210x bridges (`/dev/cu.SLAB_USBtoUART*`)
/// - FTDI USB-serial bridges (`/dev/cu.usbserial-*`)
///
/// **Bluetooth SPP is intentionally NOT supported by this transport.** macOS
/// does create a `/dev/cu.TH-D75` device file for paired Bluetooth radios, and
/// `open()` against that file even succeeds, but on the TH-D75 the kernel BT
/// serial driver behind that file is wired to a different endpoint than the
/// radio's DV data TNC. Writes go into the void and reads never deliver
/// anything. The correct path for Bluetooth is `BluetoothRFCOMMTransport`,
/// which holds an `IOBluetoothRFCOMMChannel` reference directly and speaks to
/// the channel object rather than a POSIX device file.
///
/// ## Implementation notes
///
/// This is a hardened port of the POSIX serial logic from the sibling
/// `th-programmer` project's `Sources/TH-Programmer/Radio/SerialPort.swift`,
/// which has been battle-tested against the TH-D75 over both USB and
/// Bluetooth. Key differences from a naive POSIX serial implementation:
///
/// - **`TIOCEXCL`** — exclusive access to the port. If another app already
///   has it open, we fail fast instead of silently stealing half the bytes.
/// - **Manual DTR/RTS assertion** when hardware flow control is disabled.
///   The TH-D75 specifically only responds after `DTR=1` is received via
///   `SET_CONTROL_LINE_STATE` on the USB-CDC-ACM interface — without it the
///   radio is completely silent. The Java programmer asserts both DTR and
///   RTS; we mirror that.
/// - **`poll()` with a hard timeout** instead of blind `read()` — the read
///   loop never hangs forever on a dead file descriptor. `POLLHUP`, `POLLERR`,
///   and `POLLNVAL` are surfaced as `.portDied` errors instead of infinite
///   block.
/// - **`isHealthy()`** — non-blocking health check usable from any thread,
///   for detecting radio power-off / USB unplug / Bluetooth link drop.
/// - **`IOSSIOSPEED`** fallback for non-standard baud rates (e.g. MMDVM at
///   38400 is standard; but we'd need this for 125000 or anything else
///   unusual).
/// - **`flushInput()`** after open — some Bluetooth stacks emit a preamble
///   that would confuse the first command we send.
/// - Raw mode via `cfmakeraw()` with 8N1, `CREAD | CLOCAL | CS8`, all flow
///   control disabled in the iflag (`IXON/IXOFF/IXANY`) and cflag
///   (`CRTSCTS`). DDT2 frames are arbitrary binary and the tty layer cannot
///   be allowed to eat any byte.
public final class USBSerialTransport: RadioTransport, @unchecked Sendable {

    // MARK: - Configuration

    /// Path to the device file, e.g. `/dev/cu.usbmodem2011201` or `/dev/cu.TH-D75`.
    public let devicePath: String

    /// Baud rate. For USB CDC-ACM the baud rate is mostly virtual but the
    /// radio still checks it in some modes:
    ///
    /// - TH-D75 normal CAT: 9600
    /// - TH-D75 terminal mode (MMDVM): **38400** — NOT the standard 115200!
    /// - Hotspots / external TNCs: typically 9600–115200
    public let baudRate: Int32

    /// Whether to enable hardware flow control (RTS/CTS). Default `false` —
    /// USB-CDC-ACM and Bluetooth SPP don't have real RTS/CTS lines, and
    /// enabling CRTSCTS on those transports causes permanent silence.
    public let hardwareFlowControl: Bool

    public let displayName: String

    // MARK: - State

    private let queue = DispatchQueue(label: "MacRatsCore.USBSerialTransport")
    private let stateLock = NSLock()

    private var _status: TransportStatus = .disconnected
    public var status: TransportStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return _status
    }

    private weak var delegate: RadioTransportDelegate?

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var savedTermios: termios?

    // MARK: - Init

    public init(devicePath: String,
                baudRate: Int32 = 9600,
                hardwareFlowControl: Bool = false) {
        self.devicePath = devicePath
        self.baudRate = baudRate
        self.hardwareFlowControl = hardwareFlowControl
        // Show just the device name (not /dev/cu. prefix) for compactness in
        // the UI; the full path is still available via the property.
        let leaf = (devicePath as NSString).lastPathComponent
            .replacingOccurrences(of: "cu.", with: "")
        self.displayName = "Serial: \(leaf) @ \(baudRate)"
    }

    // MARK: - RadioTransport

    public func setDelegate(_ delegate: RadioTransportDelegate?) {
        stateLock.lock(); defer { stateLock.unlock() }
        self.delegate = delegate
    }

    public func connect() throws {
        setStatus(.connecting)

        // 1. Open the device file. O_NOCTTY prevents us from becoming the
        //    controlling terminal of the device. O_NONBLOCK lets us bail out
        //    immediately if the device isn't ready instead of hanging.
        let opened = devicePath.withCString { path in
            Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        }
        if opened < 0 {
            let err = String(cString: strerror(errno))
            setStatus(.failed("open() failed: \(err)"))
            throw TransportError.openFailed(devicePath, err)
        }
        self.fd = opened

        // 2. TIOCEXCL — exclusive access to the port. Another app trying to
        //    open the same cu.* device while we hold it will get EBUSY, which
        //    is exactly what we want. Without this, two processes can both
        //    hold the fd and split bytes randomly between them.
        if ioctl(opened, TIOCEXCL) == -1 {
            let err = String(cString: strerror(errno))
            closeFD()
            setStatus(.failed("ioctl TIOCEXCL failed: \(err)"))
            throw TransportError.ioctlFailed("TIOCEXCL", err)
        }

        // 3. Clear the non-blocking flag — we want blocking semantics from
        //    this point on, with the dispatch read source handling readability
        //    events for us.
        let flags = fcntl(opened, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(opened, F_SETFL, flags & ~O_NONBLOCK)
        }

        // 4. Save existing termios so we can restore on disconnect, then
        //    install raw mode with the requested baud rate and flow control.
        var current = termios()
        if tcgetattr(opened, &current) != 0 {
            let err = String(cString: strerror(errno))
            closeFD()
            setStatus(.failed("tcgetattr() failed: \(err)"))
            throw TransportError.configFailed("tcgetattr: \(err)")
        }
        self.savedTermios = current

        do {
            try configureLine(fd: opened, baud: baudRate, hfc: hardwareFlowControl)
        } catch {
            closeFD()
            setStatus(.failed("configure failed: \(error.localizedDescription)"))
            throw error
        }

        // 5. Flush any input bytes that may have been buffered during the
        //    open (Bluetooth stacks sometimes dump preamble here).
        _ = tcflush(opened, TCIFLUSH)

        // 6. Manual DTR/RTS assertion when HFC is off.
        //    THIS IS CRITICAL FOR THE TH-D75. The USB-CDC-ACM interface only
        //    delivers bytes from the radio after the host asserts DTR via
        //    SET_CONTROL_LINE_STATE. Without it the radio is totally silent
        //    — no error, just nothing. Java programmers assert both DTR and
        //    RTS; we mirror that exactly.
        if !hardwareFlowControl {
            var flagsToSet: Int32 = TIOCM_DTR | TIOCM_RTS
            _ = ioctl(opened, TIOCMBIS, &flagsToSet)
        }

        // 7. Start the inbound read loop on our private queue.
        let source = DispatchSource.makeReadSource(fileDescriptor: opened, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        source.setCancelHandler { [weak self] in
            self?.closeFD()
        }
        self.readSource = source
        source.resume()

        setStatus(.connected)
    }

    public func disconnect() {
        // Close the fd synchronously before cancelling the dispatch source
        // so `isHealthy()` immediately reports false and a subsequent
        // `connect()` can re-open the device without racing the cancel
        // handler. The source's cancel handler still runs — it's idempotent
        // because `closeFD()` checks `fd >= 0`.
        closeFD()
        if let source = readSource {
            readSource = nil
            source.cancel()
        }
        setStatus(.disconnected)
    }

    public func send(_ data: Data) throws {
        let fdSnapshot: Int32
        stateLock.lock()
        fdSnapshot = self.fd
        stateLock.unlock()

        guard fdSnapshot >= 0 else {
            throw TransportError.notConnected
        }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var remaining = data.count
            var pointer = base
            while remaining > 0 {
                let written = Darwin.write(fdSnapshot, pointer, remaining)
                if written < 0 {
                    let e = errno
                    if e == EAGAIN || e == EINTR {
                        // Tiny back-off and retry — non-blocking write
                        // collisions on serial devices are rare but not zero.
                        usleep(1_000)
                        continue
                    }
                    let err = String(cString: strerror(e))
                    throw TransportError.writeFailed(err)
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    // MARK: - Health

    /// Non-blocking check of whether the file descriptor is still valid and
    /// the underlying device still alive. Useful for proactively detecting
    /// a Bluetooth link drop or a USB unplug without waiting for a read to
    /// fail.
    ///
    /// Safe to call from any thread. Returns `false` if the port is
    /// disconnected, the fd is invalid, or any error condition is set on it.
    public func isHealthy() -> Bool {
        stateLock.lock()
        let fdSnapshot = self.fd
        stateLock.unlock()
        guard fdSnapshot >= 0 else { return false }

        var pfd = pollfd(fd: fdSnapshot, events: Int16(POLLIN), revents: 0)
        let result = poll(&pfd, 1, 0) // non-blocking (0ms timeout)
        if result < 0 { return false }
        let revents = pfd.revents
        if revents & Int16(POLLHUP) != 0
            || revents & Int16(POLLERR) != 0
            || revents & Int16(POLLNVAL) != 0 {
            return false
        }
        return true
    }

    // MARK: - Read loop

    private func handleReadable() {
        let fdSnapshot: Int32
        stateLock.lock()
        fdSnapshot = self.fd
        stateLock.unlock()
        guard fdSnapshot >= 0 else { return }

        // Poll first so we can detect POLLHUP/POLLERR/POLLNVAL and fail fast
        // with a clear error rather than looping on a dead fd.
        var pfd = pollfd(fd: fdSnapshot, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, 0)
        if pr < 0 {
            let e = errno
            if e != EINTR && e != EAGAIN {
                notifyError(TransportError.readFailed(String(cString: strerror(e))))
                disconnect()
            }
            return
        }
        let revents = pfd.revents
        if revents & Int16(POLLHUP) != 0
            || revents & Int16(POLLERR) != 0
            || revents & Int16(POLLNVAL) != 0 {
            notifyError(TransportError.portDied)
            disconnect()
            return
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return Darwin.read(fdSnapshot, base, ptr.count)
        }

        if n > 0 {
            let chunk = Data(buffer.prefix(n))
            notifyReceive(chunk)
        } else if n == 0 {
            // EOF — the device went away (unplugged, BT dropped, etc.)
            notifyError(TransportError.deviceGone)
            disconnect()
        } else {
            let e = errno
            if e == EAGAIN || e == EINTR {
                return // Spurious wake — wait for next event.
            }
            let err = String(cString: strerror(e))
            notifyError(TransportError.readFailed(err))
            disconnect()
        }
    }

    private func closeFD() {
        stateLock.lock()
        let oldFD = self.fd
        let saved = self.savedTermios
        self.fd = -1
        self.savedTermios = nil
        stateLock.unlock()

        if oldFD >= 0 {
            // Restore original termios as a courtesy to whatever else might
            // talk to this device next.
            if var saved {
                _ = tcsetattr(oldFD, TCSANOW, &saved)
            }
            _ = Darwin.close(oldFD)
        }
    }

    // MARK: - termios configuration

    /// Configure the tty line for raw 8N1, with optional hardware flow control,
    /// at the requested baud rate. Non-standard rates fall through to
    /// `IOSSIOSPEED` automatically.
    private func configureLine(fd: Int32, baud: Int32, hfc: Bool) throws {
        var t = termios()
        if tcgetattr(fd, &t) != 0 {
            throw TransportError.configFailed("tcgetattr: \(String(cString: strerror(errno)))")
        }

        cfmakeraw(&t)

        // 8N1, CREAD | CLOCAL. Clear parity, stop-bit-2, and size.
        t.c_cflag &= ~UInt(PARENB | CSTOPB | CSIZE)
        t.c_cflag |= UInt(CS8 | CREAD | CLOCAL)

        // Flow control.
        if hfc {
            t.c_cflag |= UInt(CRTSCTS)
        } else {
            t.c_cflag &= ~UInt(CRTSCTS)
        }

        // Input flags — NO software flow control. DDT2 frames are arbitrary
        // binary and the tty layer must never interpret XON/XOFF.
        t.c_iflag &= ~UInt(IXON | IXOFF | IXANY)

        // VMIN=1, VTIME=0 — read returns as soon as at least one byte is
        // available. (The dispatch source handles readiness, so VMIN=1 is
        // safe and avoids any 200ms delay from VTIME>0.)
        t.c_cc.16 = 1 // VMIN
        t.c_cc.17 = 0 // VTIME

        // Try to set the baud rate via the standard path first.
        if cfsetispeed(&t, speed_t(baud)) != 0 || cfsetospeed(&t, speed_t(baud)) != 0 {
            // Not fatal — we'll try IOSSIOSPEED below.
        }

        if tcsetattr(fd, TCSANOW, &t) != 0 {
            throw TransportError.configFailed("tcsetattr: \(String(cString: strerror(errno)))")
        }

        // Fall-back path for non-standard rates: IOSSIOSPEED. The constant
        // value 0x80045402 is _IOW('T', 2, speed_t) from <IOKit/serial/ioss.h>.
        // We hard-code it so we don't need to import IOKit.serial just for
        // one number.
        let IOSSIOSPEED: UInt = 0x80045402
        var speed = speed_t(baud)
        _ = ioctl(fd, IOSSIOSPEED, &speed)
    }

    // MARK: - Status / delegate plumbing

    private func setStatus(_ newStatus: TransportStatus) {
        let delegate: RadioTransportDelegate?
        stateLock.lock()
        if _status == newStatus {
            stateLock.unlock()
            return
        }
        _status = newStatus
        delegate = self.delegate
        stateLock.unlock()
        delegate?.transport(self, didChangeStatus: newStatus)
    }

    private func notifyReceive(_ data: Data) {
        let delegate: RadioTransportDelegate?
        stateLock.lock()
        delegate = self.delegate
        stateLock.unlock()
        delegate?.transport(self, didReceive: data)
    }

    private func notifyError(_ error: Error) {
        let delegate: RadioTransportDelegate?
        stateLock.lock()
        delegate = self.delegate
        stateLock.unlock()
        delegate?.transport(self, didEncounterError: error)
    }
}

// MARK: - Errors

extension TransportError {
    public static func openFailed(_ path: String, _ message: String) -> TransportError {
        .descriptive("Failed to open \(path): \(message)")
    }
    public static func configFailed(_ message: String) -> TransportError {
        .descriptive("Serial config failed: \(message)")
    }
    public static func writeFailed(_ message: String) -> TransportError {
        .descriptive("Serial write failed: \(message)")
    }
    public static func readFailed(_ message: String) -> TransportError {
        .descriptive("Serial read failed: \(message)")
    }
    public static func ioctlFailed(_ op: String, _ message: String) -> TransportError {
        .descriptive("ioctl \(op) failed: \(message)")
    }
    public static var deviceGone: TransportError {
        .descriptive("Device went away (unplugged or disconnected)")
    }
    public static var portDied: TransportError {
        .descriptive("Serial port died (POLLHUP/POLLERR) — radio may be off, unplugged, or the Bluetooth link dropped")
    }
}
