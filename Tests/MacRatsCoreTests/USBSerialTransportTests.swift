import Foundation
import Darwin
import Testing
@testable import MacRatsCore

/// Tests for `USBSerialTransport` against a pseudo-terminal pair created with
/// `openpty(3)`. The transport opens the *slave* (e.g. `/dev/ttysNNN`) and
/// the test reads/writes the *master* fd directly. This proves the termios
/// configuration is correct, that bytes flow in both directions, that the
/// dispatch read source fires, and that disconnect cleans up — all without
/// needing the TH-D75 plugged in.
struct USBSerialTransportTests {

    /// Lightweight delegate that records inbound bytes and status changes.
    final class CapturingDelegate: RadioTransportDelegate, @unchecked Sendable {
        let lock = NSLock()
        var received = Data()
        var statusHistory: [TransportStatus] = []
        var errors: [String] = []
        var firstByteContinuation: CheckedContinuation<Data, Never>?

        func transport(_ transport: RadioTransport, didReceive data: Data) {
            lock.lock()
            received.append(data)
            let cont = firstByteContinuation
            firstByteContinuation = nil
            let snapshot = received
            lock.unlock()
            cont?.resume(returning: snapshot)
        }

        func transport(_ transport: RadioTransport, didChangeStatus status: TransportStatus) {
            lock.lock()
            statusHistory.append(status)
            lock.unlock()
        }

        func transport(_ transport: RadioTransport, didEncounterError error: Error) {
            lock.lock()
            errors.append(error.localizedDescription)
            lock.unlock()
        }

        func awaitFirstByte() async -> Data {
            await withCheckedContinuation { cont in
                lock.lock()
                if !received.isEmpty {
                    let snapshot = received
                    lock.unlock()
                    cont.resume(returning: snapshot)
                    return
                }
                firstByteContinuation = cont
                lock.unlock()
            }
        }
    }

    /// Wrap `openpty(3)`. Returns (masterFD, slaveDevicePath).
    private static func makePTYPair() throws -> (Int32, String) {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        let rc = openpty(&master, &slave, &name, nil, nil)
        if rc != 0 {
            throw POSIXError(.EIO)
        }
        // We don't need the slave fd open for ourselves — the transport will
        // open the slave by path. Close our handle on it.
        close(slave)
        // Trim trailing nulls from the C buffer before decoding.
        let cleaned = name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let path = String(decoding: cleaned, as: UTF8.self)
        return (master, path)
    }

    @Test("Serial transport opens a PTY slave and receives bytes written to the master")
    func receivesBytes() async throws {
        let (masterFD, slavePath) = try Self.makePTYPair()
        defer { close(masterFD) }

        let transport = USBSerialTransport(devicePath: slavePath, baudRate: 9600)
        let delegate = CapturingDelegate()
        transport.setDelegate(delegate)
        try transport.connect()
        defer { transport.disconnect() }

        #expect(transport.status == .connected)

        // Write a small payload to the master end. The transport should
        // surface it via the delegate.
        let payload = Data("hello over serial".utf8)
        payload.withUnsafeBytes { raw in
            _ = Darwin.write(masterFD, raw.baseAddress, raw.count)
        }

        // Wait for the dispatch source to deliver the bytes.
        let got = await delegate.awaitFirstByte()
        // Bytes can arrive in chunks; spin briefly to catch any straggler bytes.
        try await Task.sleep(nanoseconds: 50_000_000)
        let final: Data = await {
            await withCheckedContinuation { cont in
                delegate.lock.lock()
                let snapshot = delegate.received
                delegate.lock.unlock()
                cont.resume(returning: snapshot)
            }
        }()
        #expect(got.count > 0)
        #expect(final == payload)
    }

    @Test("Serial transport sends bytes that the master end can read back")
    func sendsBytes() async throws {
        let (masterFD, slavePath) = try Self.makePTYPair()
        defer { close(masterFD) }

        let transport = USBSerialTransport(devicePath: slavePath, baudRate: 9600)
        let delegate = CapturingDelegate()
        transport.setDelegate(delegate)
        try transport.connect()
        defer { transport.disconnect() }

        let payload = Data("ping from MacRats".utf8)
        try transport.send(payload)

        // Read it back from the master fd. PTY writes are usually delivered
        // immediately but we still loop briefly to be safe.
        var got = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(2.0)
        while got.count < payload.count && Date() < deadline {
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.read(masterFD, base, ptr.count)
            }
            if n > 0 {
                got.append(contentsOf: buffer.prefix(n))
            } else {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(got == payload)
    }

    @Test("Bad device path produces a failed status and throws")
    func badPath() throws {
        let transport = USBSerialTransport(devicePath: "/dev/cu.this-device-does-not-exist", baudRate: 9600)
        #expect(throws: TransportError.self) {
            try transport.connect()
        }
        // Status should be `.failed(...)` rather than `.connected`.
        if case .failed = transport.status {
            // expected
        } else {
            Issue.record("Expected .failed status, got \(transport.status)")
        }
    }

    @Test("Disconnect is idempotent and closes the file descriptor cleanly")
    func disconnectIdempotent() async throws {
        let (masterFD, slavePath) = try Self.makePTYPair()
        defer { close(masterFD) }

        let transport = USBSerialTransport(devicePath: slavePath, baudRate: 9600)
        try transport.connect()
        transport.disconnect()
        transport.disconnect() // second call must not crash
        #expect(transport.status == .disconnected)
    }

    @Test("End-to-end: pack a DDT2 frame, send through serial, splitter reassembles, decode matches")
    func endToEndDDT2OverSerial() async throws {
        let (masterFD, slavePath) = try Self.makePTYPair()
        defer { close(masterFD) }

        // Receiver side: open the PTY slave as a USBSerialTransport, run
        // its bytes through DDT2FrameSplitter.
        let receiver = USBSerialTransport(devicePath: slavePath, baudRate: 9600)
        let splitter = DDT2FrameSplitter()

        final class CollectingFrames: RadioTransportDelegate, @unchecked Sendable {
            let splitter: DDT2FrameSplitter
            let lock = NSLock()
            var frames: [Data] = []
            var firstFrameContinuation: CheckedContinuation<Data, Never>?

            init(splitter: DDT2FrameSplitter) { self.splitter = splitter }

            func transport(_ transport: RadioTransport, didReceive data: Data) {
                let new = splitter.feed(data)
                lock.lock()
                frames.append(contentsOf: new)
                let cont = firstFrameContinuation
                if !new.isEmpty { firstFrameContinuation = nil }
                lock.unlock()
                if let f = new.first { cont?.resume(returning: f) }
            }
            func transport(_ transport: RadioTransport, didChangeStatus status: TransportStatus) {}
            func transport(_ transport: RadioTransport, didEncounterError error: Error) {}

            func awaitFirstFrame() async -> Data {
                await withCheckedContinuation { cont in
                    lock.lock()
                    if let f = frames.first {
                        lock.unlock()
                        cont.resume(returning: f)
                    } else {
                        firstFrameContinuation = cont
                        lock.unlock()
                    }
                }
            }
        }

        let delegate = CollectingFrames(splitter: splitter)
        receiver.setDelegate(delegate)
        try receiver.connect()
        defer { receiver.disconnect() }

        // Sender side: build a real DDT2 frame and write it to the master fd
        // in two chunks, to exercise the splitter's partial-frame logic.
        let frame = DDT2Frame(seq: 99,
                              session: 0,
                              type: 1,
                              sStation: "AI5OS",
                              dStation: "W9FYI",
                              data: Data("Serial loopback works!".utf8),
                              compress: true)
        let wire = DDT2EncodedFrame.pack(frame)

        let mid = wire.count / 2
        wire.prefix(mid).withUnsafeBytes { raw in
            _ = Darwin.write(masterFD, raw.baseAddress, raw.count)
        }
        // Small gap to force the dispatch source to fire twice.
        try await Task.sleep(nanoseconds: 50_000_000)
        wire.suffix(from: mid).withUnsafeBytes { raw in
            _ = Darwin.write(masterFD, raw.baseAddress, raw.count)
        }

        let received = await delegate.awaitFirstFrame()
        let parsed = try DDT2EncodedFrame.unpack(received)
        #expect(parsed.seq == 99)
        #expect(parsed.sStation == "AI5OS")
        #expect(parsed.dStation == "W9FYI")
        #expect(parsed.data == Data("Serial loopback works!".utf8))
    }
}
