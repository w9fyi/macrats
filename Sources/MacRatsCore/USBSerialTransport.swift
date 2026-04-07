import Foundation
import Darwin

/// A `RadioTransport` backed by a POSIX serial device file (`/dev/cu.*`).
///
/// Works with:
/// - USB CDC-ACM radios like the Kenwood TH-D75 (`/dev/cu.usbmodem*`)
/// - Silicon Labs CP210x bridges (`/dev/cu.SLAB_USBtoUART*`)
/// - FTDI USB-serial bridges (`/dev/cu.usbserial-*`)
///
/// **Bluetooth SPP is intentionally NOT supported by this transport alone.**
/// macOS does create a `/dev/cu.TH-D75` (or similar) device file for any paired
/// Bluetooth SPP device, and `open()` against that file will succeed even when
/// the radio's Bluetooth radio is off — but the file is a stale shim, not a
/// live link. Bytes written to it go nowhere until an `IOBluetooth` ACL
/// connection is established AND an `IOBluetoothRFCOMMChannel` reference is
/// held alive in memory by the application. For the TH-D75 specifically, the
/// data channel is RFCOMM channel 2 (not the SDP-advertised SPP channel).
///
/// v1.1 will add a `BluetoothCoordinator` that handles the IOBluetooth dance
/// (modeled on the `th-programmer` project's `BluetoothManager.swift`) and
/// then hands the resulting `/dev/cu.*` path to *this* transport class. The
/// byte-pipe code below is reused unchanged for both USB and Bluetooth — only
/// the connection lifecycle differs.
///
/// Implementation notes:
///
/// - Opens with `O_RDWR | O_NOCTTY | O_NONBLOCK` so we never become the
///   controlling terminal of the device.
/// - Uses `cfmakeraw()` to put the line discipline into raw 8-bit mode with
///   no echo, no flow control, no signal characters, and no special handling
///   of any byte. DDT2 frames are arbitrary binary — we cannot tolerate the
///   tty layer eating bytes.
/// - For USB CDC-ACM and Bluetooth SPP, the baud rate is functionally a
///   no-op (the device is virtual) but we still call `cfsetspeed()` for
///   completeness, and we use the macOS `IOSSIOSPEED` ioctl for non-standard
///   rates if the caller asks for one.
/// - A `DispatchSourceRead` runs the inbound read loop on a private serial
///   queue. Outbound writes go straight to `write(2)` with a short retry on
///   `EAGAIN`.
public final class USBSerialTransport: RadioTransport, @unchecked Sendable {

    // MARK: - Configuration

    /// Path to the device file, e.g. `/dev/cu.usbmodem2011201` or `/dev/cu.TH-D75`.
    public let devicePath: String

    /// Baud rate. For USB CDC-ACM and Bluetooth SPP this is virtual but still
    /// gets reported on the wire — pick something the radio expects (TH-D75 is
    /// happy at any rate; the default of 9600 is a safe choice for most ham
    /// gear).
    public let baudRate: Int32

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

    public init(devicePath: String, baudRate: Int32 = 9600) {
        self.devicePath = devicePath
        self.baudRate = baudRate
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

        // 2. Clear the non-blocking flag now that we have the fd — we want
        //    blocking semantics from this point on, with the dispatch source
        //    handling readability events for us.
        let flags = fcntl(opened, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(opened, F_SETFL, flags & ~O_NONBLOCK)
        }

        // 3. Save the existing termios so we can restore it on disconnect,
        //    then put the line into raw mode and apply the requested baud rate.
        var current = termios()
        if tcgetattr(opened, &current) != 0 {
            let err = String(cString: strerror(errno))
            closeFD()
            setStatus(.failed("tcgetattr() failed: \(err)"))
            throw TransportError.configFailed("tcgetattr: \(err)")
        }
        self.savedTermios = current

        var raw = current
        cfmakeraw(&raw)
        // Force 8 data bits, no parity, 1 stop bit, no flow control,
        // ignore modem control lines (so we work with USB-CDC and BT-SPP).
        raw.c_cflag |= UInt(CLOCAL | CREAD | CS8)
        raw.c_cflag &= ~UInt(PARENB | CSTOPB | CSIZE)
        raw.c_cflag |= UInt(CS8)
        // Disable any flow control. DDT2 carries arbitrary binary; we cannot
        // let the tty layer interpret XON/XOFF or RTS/CTS.
        raw.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
        raw.c_cflag &= ~UInt(CRTSCTS)
        // VMIN=1, VTIME=0 — read returns as soon as at least one byte arrives.
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 0 // VTIME

        if cfsetspeed(&raw, speed_t(baudRate)) != 0 {
            // Some baud rates (e.g. very high custom rates) aren't accepted
            // by cfsetspeed and require IOSSIOSPEED. We try cfsetspeed first
            // because it works for all standard rates including 9600/19200/
            // 38400/57600/115200, then fall back below if needed.
        }

        if tcsetattr(opened, TCSANOW, &raw) != 0 {
            let err = String(cString: strerror(errno))
            closeFD()
            setStatus(.failed("tcsetattr() failed: \(err)"))
            throw TransportError.configFailed("tcsetattr: \(err)")
        }

        // 4. For non-standard baud rates, fall back to IOSSIOSPEED.
        // This is the macOS-specific ioctl that lets you set arbitrary speeds
        // without going through termios. The constant value 0x80045402 is
        // _IOW('T', 2, speed_t) — defined in <IOKit/serial/ioss.h>. We hard-code
        // it here so we don't have to import IOKit.serial just for one number.
        let IOSSIOSPEED: UInt = 0x80045402
        var speed = speed_t(baudRate)
        if ioctl(opened, IOSSIOSPEED, &speed) != 0 {
            // Not fatal — most rates work via termios alone.
        }

        // 5. Flush any stale bytes already in the OS buffers.
        _ = tcflush(opened, TCIOFLUSH)

        // 6. Start the inbound read loop on our private queue.
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
        if let source = readSource {
            readSource = nil
            source.cancel()
        } else {
            closeFD()
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

    // MARK: - Read loop

    private func handleReadable() {
        let fdSnapshot: Int32
        stateLock.lock()
        fdSnapshot = self.fd
        stateLock.unlock()
        guard fdSnapshot >= 0 else { return }

        // Drain whatever is available in one go. We loop until read() returns
        // 0 (EOF) or EAGAIN.
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
    public static var deviceGone: TransportError {
        .descriptive("Device went away (unplugged or disconnected)")
    }
}
