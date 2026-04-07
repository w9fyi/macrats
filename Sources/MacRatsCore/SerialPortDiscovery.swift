import Foundation

/// Helpers for discovering and classifying `/dev/cu.*` serial ports on macOS.
///
/// Ported from the sibling `th-programmer` project's
/// `Sources/TH-Programmer/Radio/SerialPort.swift` — specifically
/// `availablePorts()` and `isBluetoothPort(_:)`.
public enum SerialPortDiscovery {

    /// Category a serial port falls into — used for UI grouping in the
    /// device picker.
    public enum Kind: String, Sendable, Equatable {
        case usbModem     // /dev/cu.usbmodem* — CDC-ACM like TH-D75
        case usbSerial    // /dev/cu.usbserial*, /dev/cu.SLAB_USBtoUART* — FTDI, SiLabs
        case bluetooth    // /dev/cu.TH-D75, /dev/cu.<name>-SerialPort, /dev/cu.Bluetooth-*
        case other        // anything else (debug-console, loopback, etc.)
    }

    /// A discovered serial port.
    public struct Port: Sendable, Equatable {
        public let path: String
        public let kind: Kind

        /// The bare device name, without the leading `/dev/cu.` prefix.
        public var leafName: String {
            let leaf = (path as NSString).lastPathComponent
            if leaf.hasPrefix("cu.") {
                return String(leaf.dropFirst(3))
            }
            return leaf
        }

        public init(path: String, kind: Kind) {
            self.path = path
            self.kind = kind
        }
    }

    /// Enumerate all `/dev/cu.*` devices currently present, classified and
    /// sorted into MacRats's preferred order: USB-CDC-ACM first (TH-D75 and
    /// similar), then USB-serial bridges, then Bluetooth SPP, then everything
    /// else. Within each group, entries are alphabetical.
    public static func availablePorts() -> [Port] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else {
            return []
        }
        var paths: [String] = []
        for entry in entries.sorted() where entry.hasPrefix("cu.") {
            paths.append("/dev/\(entry)")
        }
        return paths.map { Port(path: $0, kind: classify($0)) }
            .sorted { lhs, rhs in
                if lhs.kind == rhs.kind { return lhs.path < rhs.path }
                return lhs.kind.order < rhs.kind.order
            }
    }

    /// Classify a single device path into one of the four kinds.
    public static func classify(_ path: String) -> Kind {
        let name = ((path as NSString).lastPathComponent).lowercased()
        if name.contains("usbmodem") { return .usbModem }
        if name.contains("usbserial") || name.contains("slab") { return .usbSerial }
        if isBluetoothPort(path) { return .bluetooth }
        return .other
    }

    /// True when the port path looks like a Bluetooth SPP virtual device
    /// rather than a hardwired USB device. Known TH-D74/D75 Bluetooth SPP
    /// device files appear as `cu.TH-D75` or `cu.TH-D75-SerialPort`.
    ///
    /// **Warning:** A "true" from this function does NOT mean the Bluetooth
    /// link is up. macOS creates and persists these cu.* device files for
    /// any paired Bluetooth SPP device whether the radio is currently
    /// reachable or not. The file is a dormant shim until `IOBluetooth`
    /// brings up an ACL + RFCOMM channel. See the discussion in
    /// `USBSerialTransport.swift`.
    public static func isBluetoothPort(_ path: String) -> Bool {
        let name = ((path as NSString).lastPathComponent).lowercased()
        // Positive match for known ham-radio BT patterns.
        if name.contains("th-d75") || name.contains("thd75")
            || name.contains("th-d74") || name.contains("thd74") {
            return true
        }
        // Generic BT indicators.
        if name.contains("bluetooth") || name.contains("-wireless") {
            return true
        }
        // Known-wired prefixes explicitly aren't BT.
        if name.contains("usbmodem") || name.contains("usbserial")
            || name.contains("slab") {
            return false
        }
        return false
    }
}

// MARK: - Private sort ordering

private extension SerialPortDiscovery.Kind {
    /// Sort order — lower is first in the picker list.
    var order: Int {
        switch self {
        case .usbModem:  return 0
        case .usbSerial: return 1
        case .bluetooth: return 2
        case .other:     return 3
        }
    }
}
