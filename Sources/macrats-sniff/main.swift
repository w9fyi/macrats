import Foundation
import MacRatsCore

/// macrats-sniff — read-only serial smoke test for MacRats.
///
/// Opens a `/dev/cu.*` device and prints any bytes it receives until interrupted
/// or until the optional `--seconds N` timeout expires. Bytes are printed in two
/// columns: hex and ASCII (with non-printable bytes shown as `.`). DDT2 frame
/// envelopes are highlighted with `[SOB]` / `[EOB]` markers when detected.
///
/// **This tool never transmits.** It is safe to run with the radio sitting
/// idle, with the radio receiving, or with another MacRats / D-Rats process
/// already producing traffic — we just snoop, never send.
///
/// Usage:
///   swift run macrats-sniff /dev/cu.usbmodem2011201
///   swift run macrats-sniff /dev/cu.TH-D75 --baud 19200 --seconds 30

@main
struct Sniff {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: macrats-sniff <device> [--baud N] [--seconds N]")
            print("")
            print("Examples:")
            print("  macrats-sniff /dev/cu.usbmodem2011201")
            print("  macrats-sniff /dev/cu.TH-D75 --baud 19200 --seconds 30")
            print("")
            print("This tool is READ-ONLY. It never transmits.")
            exit(2)
        }

        let devicePath = args[1]
        var baud: Int32 = 9600
        var seconds: TimeInterval = 10

        var i = 2
        while i < args.count {
            switch args[i] {
            case "--baud":
                i += 1
                if i < args.count, let n = Int32(args[i]) { baud = n }
            case "--seconds":
                i += 1
                if i < args.count, let n = Double(args[i]) { seconds = n }
            default:
                print("Unknown arg: \(args[i])")
                exit(2)
            }
            i += 1
        }

        print("macrats-sniff: opening \(devicePath) @ \(baud) baud, sniffing for \(Int(seconds))s")
        print("READ-ONLY — never transmits. Press Ctrl-C to stop early.")
        print("")

        let transport = USBSerialTransport(devicePath: devicePath, baudRate: baud)
        let printer = HexPrinter()
        transport.setDelegate(printer)

        do {
            try transport.connect()
        } catch {
            print("Failed to connect: \(error.localizedDescription)")
            exit(1)
        }

        // Run the run loop until the timeout. Keeping it on the main run loop
        // means dispatch events from the transport's private queue still
        // deliver into the delegate; we just need this thread alive.
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        }

        transport.disconnect()
        print("")
        print("--- summary ---")
        print("\(printer.totalBytes) bytes received in \(Int(seconds))s")
        print("\(printer.completedFrames) complete DDT2 frame(s) detected")
    }
}

final class HexPrinter: RadioTransportDelegate, @unchecked Sendable {
    let lock = NSLock()
    var totalBytes = 0
    var completedFrames = 0
    let splitter = DDT2FrameSplitter()

    func transport(_ transport: RadioTransport, didReceive data: Data) {
        lock.lock()
        totalBytes += data.count
        let frames = splitter.feed(data)
        completedFrames += frames.count
        lock.unlock()

        // Print the inbound chunk in hex + ASCII.
        printChunk(data)

        // Try to decode each completed frame.
        for frame in frames {
            do {
                let parsed = try DDT2EncodedFrame.unpack(frame)
                print(">>> Decoded DDT2 frame:")
                print("    seq=\(parsed.seq) session=\(parsed.session) type=\(parsed.type)")
                print("    \(parsed.sStation) -> \(parsed.dStation)")
                print("    payload (\(parsed.data.count) bytes): \(asciiDump(parsed.data))")
                print("")
            } catch {
                print(">>> Frame envelope captured but failed to decode: \(error.localizedDescription)")
            }
        }
    }

    func transport(_ transport: RadioTransport, didChangeStatus status: TransportStatus) {
        print("[status] \(status)")
    }

    func transport(_ transport: RadioTransport, didEncounterError error: Error) {
        print("[error] \(error.localizedDescription)")
    }

    private func printChunk(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ascii = asciiDump(data)
        print("[\(data.count) bytes] \(hex)  |  \(ascii)")
    }

    private func asciiDump(_ data: Data) -> String {
        String(decoding: data.map { (b: UInt8) -> UInt8 in
            (b >= 0x20 && b < 0x7F) ? b : 0x2E /* '.' */
        }, as: UTF8.self)
    }
}
