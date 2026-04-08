#if canImport(IOBluetooth)
import Foundation
import IOBluetooth

/// Enumerates paired TH-D74 / TH-D75 Bluetooth radios for the picker UI.
///
/// ## History (important for future maintainers)
///
/// An earlier incarnation of this class also **brought up** the Bluetooth
/// RFCOMM link — ACL open, SDP query, `openRFCOMMChannelSync`, polling
/// for a `/dev/cu.*` file to appear, handing the path to
/// `USBSerialTransport`. That path turned out to be a dead end on the
/// TH-D75: the kernel BT serial driver behind `cu.*` is wired to a
/// different endpoint than the radio's DV data TNC, so reads produced
/// nothing and the session layer was stuck in a TX-only state.
///
/// The Bluetooth bring-up now lives in `BluetoothRFCOMMTransport`, which
/// talks to an `IOBluetoothRFCOMMChannel` directly (via `writeAsync` +
/// the `rfcommChannelData` delegate). `BluetoothCoordinator` is kept
/// only to enumerate paired radios for the picker UI — the fallback
/// path that scrapes `system_profiler SPBluetoothDataType` is still
/// needed because ad-hoc code-signed builds sometimes lose TCC
/// permission to call `IOBluetooth.pairedDevices()` even when the
/// pairing is intact, and we want the picker to keep working.
///
/// **Do not reintroduce a bring-up method here.** If you think you need
/// one, read the commit history for `BluetoothRFCOMMTransport.swift`
/// and the current README section on Bluetooth SPP first.
public enum BluetoothCoordinator {

    /// A paired Bluetooth radio suitable for MacRats.
    public struct PairedRadio: Equatable, Sendable {
        public let name: String
        public let address: String       // "XX-XX-XX-XX-XX-XX" or "XX:XX:XX:XX:XX:XX"
        public let isCurrentlyConnected: Bool
        /// Path to the `/dev/cu.*` device file macOS created for this
        /// device, if one exists. Used only by the picker to display
        /// "linked" state — the Bluetooth transport does not actually
        /// read or write through this path.
        public let existingPortPath: String?

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

    // MARK: - Enumeration

    /// Returns the list of paired TH-D74/D75 radios currently known to
    /// `IOBluetooth`. If TCC has blocked `pairedDevices()` (common after
    /// ad-hoc re-signing), falls back to parsing `system_profiler
    /// SPBluetoothDataType` for the device addresses. If that also fails,
    /// returns an empty array.
    @MainActor
    public static func pairedRadios() -> [PairedRadio] {
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

    // MARK: - Pure helpers (testable)

    /// Returns true if the device name looks like a TH-D74 or TH-D75.
    public static func isSupportedRadio(_ device: IOBluetoothDevice) -> Bool {
        isSupportedRadioName(device.name ?? "")
    }

    /// Pure string test, exposed for unit testing without IOBluetooth.
    public static func isSupportedRadioName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("TH-D75") || upper.contains("THD75")
            || upper.contains("TH-D74") || upper.contains("THD74")
    }

    /// Find the `/dev/cu.*` file corresponding to a Bluetooth device name or
    /// address. Looks for matches on the slugged device name, the
    /// dash-joined address, or a generic "th-d75"/"th-d74" substring.
    public static func findPortPath(forDeviceName name: String,
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
    public static func portEntryMatches(_ entry: String,
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
    public static func scrapePairedRadioFromSystemProfiler() -> PairedRadio? {
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
    public static func parseSystemProfilerOutput(_ output: String) -> PairedRadio? {
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

    private static func runSystemProfilerBluetooth() -> String {
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
