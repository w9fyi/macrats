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

    public enum CoordinatorError: Error, CustomStringConvertible {
        case deviceNotFound(address: String)
        case aclConnectionFailed(code: Int32)
        case rfcommChannelFailed(code: Int32)
        case portDidNotAppear
        case permissionDenied

        public var description: String {
            switch self {
            case .deviceNotFound(let address):
                return "Bluetooth device \(address) is not paired. Pair the radio in System Settings → Bluetooth first."
            case .aclConnectionFailed(let code):
                return "Bluetooth ACL connection failed (IOReturn \(code)). Make sure the radio is powered on and in range."
            case .rfcommChannelFailed(let code):
                return "Could not open RFCOMM channel 2 on the radio (IOReturn \(code)). Try power-cycling the radio's Bluetooth."
            case .portDidNotAppear:
                return "The Bluetooth serial port did not appear within the timeout. Try turning the radio off and on."
            case .permissionDenied:
                return "macOS denied Bluetooth permission for MacRats. Check System Settings → Privacy & Security → Bluetooth."
            }
        }
    }

    /// The kept-alive RFCOMM channel reference. Must stay in memory for the
    /// lifetime of the serial transport or macOS tears down the cu.* file.
    private var rfcommChannel: IOBluetoothRFCOMMChannel?

    /// The device we're currently linked to. Cleared on teardown.
    private var currentDevice: IOBluetoothDevice?

    public init() {}

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

        guard let device = IOBluetoothDevice(addressString: addressString) else {
            throw CoordinatorError.deviceNotFound(address: addressString)
        }

        // Step 1: open the ACL connection. If the device reports "connected"
        // but no cu.* file exists, the baseband connection is stale (e.g.
        // radio power-cycled) — close and reopen.
        if device.isConnected() && Self.findPortPath(forDeviceName: device.name ?? "",
                                                     addressString: addressString) == nil {
            device.closeConnection()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if !device.isConnected() {
            let aclResult = device.openConnection()
            if aclResult != kIOReturnSuccess {
                throw CoordinatorError.aclConnectionFailed(code: aclResult)
            }
            // Let macOS finish the baseband handshake.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Step 2: open RFCOMM channel 2 and hold the reference.
        var channel: IOBluetoothRFCOMMChannel?
        var openResult = device.openRFCOMMChannelSync(
            &channel,
            withChannelID: BluetoothRFCOMMChannelID(2),
            delegate: nil
        )

        // If we hit NotPermitted, macOS is showing (or about to show) the
        // TCC Bluetooth permission prompt. Wait a moment, then retry once.
        if openResult != kIOReturnSuccess && openResult == IOReturn(kIOReturnNotPermitted) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            channel = nil
            openResult = device.openRFCOMMChannelSync(
                &channel,
                withChannelID: BluetoothRFCOMMChannelID(2),
                delegate: nil
            )
            if openResult == IOReturn(kIOReturnNotPermitted) {
                throw CoordinatorError.permissionDenied
            }
        }

        if openResult != kIOReturnSuccess {
            throw CoordinatorError.rfcommChannelFailed(code: openResult)
        }

        self.rfcommChannel = channel
        self.currentDevice = device

        // Step 3: poll up to 10 s for the /dev/cu.* device file to appear.
        for _ in 0..<20 {
            if let path = Self.findPortPath(forDeviceName: device.name ?? "",
                                            addressString: addressString) {
                return path
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // The channel is up but no cu.* file appeared. Release the channel
        // before throwing so we don't leak it.
        tearDownLink()
        throw CoordinatorError.portDidNotAppear
    }

    /// Tear down the RFCOMM channel (and by extension the cu.* device file).
    /// Call AFTER the `USBSerialTransport` has been disconnected.
    public func tearDownLink() {
        if let ch = rfcommChannel {
            _ = ch.close()
            ch.setDelegate(nil)
        }
        rfcommChannel = nil
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
#endif
