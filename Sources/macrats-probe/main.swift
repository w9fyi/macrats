import Foundation
import MacRatsCore

/// macrats-probe — identify what's on the other end of a serial port.
///
/// Opens a `/dev/cu.*` device, sends a short Kenwood normal-mode CAT probe
/// (`ID\r`) and an MMDVM `getVersion` probe, then waits briefly for a
/// response after each. Prints what came back and makes a guess about
/// what kind of interface this port is:
///
///   - **Kenwood CAT** — responded to `ID\r` with `ID<model>\r`
///   - **MMDVM terminal mode** — responded to `getVersion` with an `E0`-framed version reply
///   - **Silent** — no reply to either (data-only port or non-responsive mode)
///
/// For the TH-D75 specifically, this tells us which of its two USB ports is
/// the CAT/GPS port and which one is the data port (or the MMDVM terminal
/// port when Menu 650 is active).
///
/// **This is a very small amount of transmit activity** — two probes, ~5
/// bytes each. It is safe to run while the radio is in receive mode and on
/// any idle frequency. It will NOT key the transmitter; both probes target
/// the control interface, not the air interface.
///
/// Usage:
///
///   swift run macrats-probe /dev/cu.usbmodem2011201
///   swift run macrats-probe /dev/cu.usbmodem2011401 --baud 38400
///   swift run macrats-probe /dev/cu.TH-D75
///
/// Defaults: baud 9600, response timeout 1.5s per probe.

@main
struct Probe {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: macrats-probe <device> [--baud N] [--timeout SEC]")
            print("")
            print("Sends a Kenwood CAT 'ID\\r' probe and an MMDVM getVersion probe,")
            print("reports what each replies with, and guesses the interface kind.")
            print("")
            print("Safe — sends only ~10 bytes total to the CONTROL interface, not the air.")
            exit(2)
        }

        let devicePath = args[1]
        var baud: Int32 = 9600
        var timeout: TimeInterval = 1.5

        var i = 2
        while i < args.count {
            switch args[i] {
            case "--baud":
                i += 1
                if i < args.count, let n = Int32(args[i]) { baud = n }
            case "--timeout":
                i += 1
                if i < args.count, let n = Double(args[i]) { timeout = n }
            default:
                print("Unknown arg: \(args[i])")
                exit(2)
            }
            i += 1
        }

        print("macrats-probe: \(devicePath) @ \(baud) baud, \(String(format: "%.1f", timeout))s timeout per probe")
        print("")

        let transport = USBSerialTransport(devicePath: devicePath, baudRate: baud)
        let collector = Collector()
        transport.setDelegate(collector)

        do {
            try transport.connect()
        } catch {
            print("Failed to connect: \(error.localizedDescription)")
            exit(1)
        }

        // Let the line settle and any preamble flush through. The TH-D75
        // sometimes emits a byte or two right after the CDC-ACM line
        // stabilizes.
        Thread.sleep(forTimeInterval: 0.2)
        collector.lock.lock()
        collector.received.removeAll()
        collector.lock.unlock()

        // ==================== Probe 1: Kenwood CAT `ID\r` ====================
        print("--- Probe 1: Kenwood CAT 'ID\\r' ---")
        do {
            try transport.send(Data("ID\r".utf8))
        } catch {
            print("send failed: \(error.localizedDescription)")
        }
        Thread.sleep(forTimeInterval: timeout)

        collector.lock.lock()
        let kenwoodReply = collector.received
        collector.received = Data()
        collector.lock.unlock()

        if kenwoodReply.isEmpty {
            print("  (no reply)")
        } else {
            printReply(kenwoodReply)
        }
        print("")

        // ==================== Probe 2: MMDVM `getVersion` ====================
        print("--- Probe 2: MMDVM getVersion ---")
        do {
            try transport.send(MMDVMProtocol.buildGetVersion())
        } catch {
            print("send failed: \(error.localizedDescription)")
        }
        Thread.sleep(forTimeInterval: timeout)

        collector.lock.lock()
        let mmdvmReply = collector.received
        collector.received = Data()
        collector.lock.unlock()

        if mmdvmReply.isEmpty {
            print("  (no reply)")
        } else {
            printReply(mmdvmReply)
            // Try to parse it as MMDVM frames.
            let parser = MMDVMParser()
            let frames = parser.feed(mmdvmReply)
            for frame in frames {
                print("  parsed: \(frame)")
            }
        }
        print("")

        // ==================== Summary / verdict ====================
        print("--- Verdict ---")
        let kenwoodLooksReal = kenwoodLike(kenwoodReply)
        let mmdvmLooksReal = mmdvmLike(mmdvmReply)

        switch (kenwoodLooksReal, mmdvmLooksReal) {
        case (true, false):
            print("  This port speaks KENWOOD CAT. Use baud 9600 for the TH-D75.")
        case (false, true):
            print("  This port speaks MMDVM TERMINAL MODE.")
            print("  Note: MacRats uses 38400 baud for TH-D75 terminal mode — rerun with --baud 38400 if that wasn't already set.")
        case (true, true):
            print("  Both probes got replies — unusual. This may be a multi-mode port or the")
            print("  MMDVM frame was misinterpreted by a CAT-mode interface.")
        case (false, false):
            print("  Port is SILENT — no reply to either probe.")
            print("  Likely possibilities:")
            print("    - This is the DATA/GPS port (passively reports NMEA, ignores CAT)")
            print("    - The TH-D75 is in terminal mode but on a different baud rate (try --baud 38400)")
            print("    - The radio requires DTR assertion (MacRats's USBSerialTransport does this, but double-check)")
            print("    - The radio is in a mode that silences both probes")
        }

        transport.disconnect()
    }

    static func printReply(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ascii = String(decoding: data.map { (b: UInt8) -> UInt8 in
            (b >= 0x20 && b < 0x7F) ? b : 0x2E
        }, as: UTF8.self)
        print("  \(data.count) bytes: \(hex)")
        print("  ascii   : \(ascii)")
    }

    /// Heuristic — Kenwood CAT `ID;` / `ID\r` replies look like `ID<model>;` or `ID<model>\r`.
    static func kenwoodLike(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let prefix = data.prefix(2)
        return prefix == Data("ID".utf8)
    }

    /// Heuristic — MMDVM replies always start with 0xE0.
    static func mmdvmLike(_ data: Data) -> Bool {
        data.first == MMDVMProtocol.frameMarker
    }
}

final class Collector: RadioTransportDelegate, @unchecked Sendable {
    let lock = NSLock()
    var received = Data()

    func transport(_ transport: RadioTransport, didReceive data: Data) {
        lock.lock()
        received.append(data)
        lock.unlock()
    }
    func transport(_ transport: RadioTransport, didChangeStatus status: TransportStatus) {
        print("[status] \(status)")
    }
    func transport(_ transport: RadioTransport, didEncounterError error: Error) {
        print("[error] \(error.localizedDescription)")
    }
}
