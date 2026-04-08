#if canImport(IOBluetooth)
import Testing
@testable import MacRatsCore

/// Unit tests for the pure-function helpers on `BluetoothCoordinator`.
///
/// The live IOBluetooth bring-up code is NOT exercised here — that requires
/// a real paired TH-D75 in range and a user willing to approve the TCC
/// permission prompt. Those paths are verified manually during live testing
/// (see `memory/macrats_live_test_plan.md` and the BT bring-up section of
/// `memory/macrats.md`).
///
/// What IS covered here:
///
/// - `isSupportedRadioName` — recognizing TH-D74/D75 device names across
///   the variations Kenwood and macOS can produce
/// - `portEntryMatches` — matching a `/dev/cu.*` entry against a device
///   name or address suffix
/// - `parseSystemProfilerOutput` — extracting a paired radio from the
///   indented key-value output of `system_profiler SPBluetoothDataType`
@Suite
struct BluetoothCoordinatorTests {

    // MARK: - isSupportedRadioName

    @Test("Recognizes canonical TH-D75 name")
    func recognizesCanonicalD75() {
        #expect(BluetoothCoordinator.isSupportedRadioName("TH-D75"))
    }

    @Test("Recognizes canonical TH-D74 name")
    func recognizesCanonicalD74() {
        #expect(BluetoothCoordinator.isSupportedRadioName("TH-D74"))
    }

    @Test("Recognizes THD75 without dash")
    func recognizesD75WithoutDash() {
        #expect(BluetoothCoordinator.isSupportedRadioName("THD75"))
    }

    @Test("Recognizes THD74 without dash")
    func recognizesD74WithoutDash() {
        #expect(BluetoothCoordinator.isSupportedRadioName("THD74"))
    }

    @Test("Recognizes TH-D75 case-insensitive")
    func recognizesD75CaseInsensitive() {
        #expect(BluetoothCoordinator.isSupportedRadioName("th-d75"))
        #expect(BluetoothCoordinator.isSupportedRadioName("Th-D75"))
    }

    @Test("Recognizes TH-D75 with trailing serial or suffix")
    func recognizesD75WithSuffix() {
        // Some Kenwood firmwares broadcast "TH-D75 1234" or similar.
        #expect(BluetoothCoordinator.isSupportedRadioName("TH-D75 AI5OS"))
        #expect(BluetoothCoordinator.isSupportedRadioName("Kenwood TH-D75"))
    }

    @Test("Rejects empty string")
    func rejectsEmptyString() {
        #expect(!BluetoothCoordinator.isSupportedRadioName(""))
    }

    @Test("Rejects unrelated device names")
    func rejectsUnrelatedNames() {
        #expect(!BluetoothCoordinator.isSupportedRadioName("AirPods Pro"))
        #expect(!BluetoothCoordinator.isSupportedRadioName("Magic Mouse"))
        #expect(!BluetoothCoordinator.isSupportedRadioName("iPhone"))
        #expect(!BluetoothCoordinator.isSupportedRadioName("IC-705"))
        #expect(!BluetoothCoordinator.isSupportedRadioName("ID-52"))
        // Near-miss names we should NOT claim.
        #expect(!BluetoothCoordinator.isSupportedRadioName("TH-D72"))
        #expect(!BluetoothCoordinator.isSupportedRadioName("TH-F6A"))
    }

    // MARK: - portEntryMatches

    @Test("Matches cu.TH-D75 against canonical device name")
    func matchesCanonicalPort() {
        #expect(BluetoothCoordinator.portEntryMatches(
            "cu.TH-D75",
            deviceName: "TH-D75",
            addressSuffix: "12-34-56-78-9A-BC"
        ))
    }

    @Test("Matches cu.TH-D75-SPPDev against device name")
    func matchesNamedPortWithSuffix() {
        #expect(BluetoothCoordinator.portEntryMatches(
            "cu.TH-D75-SPPDev",
            deviceName: "TH-D75",
            addressSuffix: "12-34-56-78-9A-BC"
        ))
    }

    @Test("Matches address-suffix port without needing name")
    func matchesAddressSuffixPort() {
        #expect(BluetoothCoordinator.portEntryMatches(
            "cu.Bluetooth-Incoming-Port-12-34-56-78-9A-BC",
            deviceName: "",
            addressSuffix: "12-34-56-78-9A-BC"
        ))
    }

    @Test("Matches generic TH-D75 keyword fallback")
    func matchesGenericKeywordFallback() {
        // Zero info about the device — fallback keyword match should fire.
        #expect(BluetoothCoordinator.portEntryMatches(
            "cu.TH-D75-something",
            deviceName: "",
            addressSuffix: ""
        ))
    }

    @Test("Rejects non-cu entries via caller filter contract")
    func rejectsNonCuEntryContract() {
        // portEntryMatches does not itself check the cu. prefix — the caller
        // (findPortPath) does. This test documents that contract so anyone
        // reusing portEntryMatches in isolation knows to pre-filter.
        #expect(BluetoothCoordinator.portEntryMatches(
            "tty.TH-D75",
            deviceName: "TH-D75",
            addressSuffix: ""
        ))
    }

    @Test("Rejects unrelated USB device")
    func rejectsUnrelatedUsb() {
        #expect(!BluetoothCoordinator.portEntryMatches(
            "cu.usbmodem14201",
            deviceName: "TH-D75",
            addressSuffix: "12-34-56-78-9A-BC"
        ))
    }

    @Test("Rejects another Bluetooth device's cu file")
    func rejectsOtherBluetoothDevice() {
        #expect(!BluetoothCoordinator.portEntryMatches(
            "cu.Mobilinkd-TNC3",
            deviceName: "TH-D75",
            addressSuffix: "12-34-56-78-9A-BC"
        ))
    }

    // MARK: - parseSystemProfilerOutput

    @Test("Parses a TH-D75 stanza out of system_profiler output")
    func parsesSimpleD75Stanza() {
        let output = """
        Bluetooth:

          Connected: Yes

          Devices (Paired, Configured, etc.):

              TH-D75:
                  Address: 12:34:56:78:9A:BC
                  Minor Type: Handheld
                  Major Type: Peripheral
                  Services: Serial Port
        """
        let parsed = BluetoothCoordinator.parseSystemProfilerOutput(output)
        #expect(parsed != nil)
        #expect(parsed?.name == "TH-D75")
        #expect(parsed?.address == "12:34:56:78:9A:BC")
    }

    @Test("Parses a TH-D74 stanza")
    func parsesD74Stanza() {
        let output = """
            TH-D74:
                Address: AA:BB:CC:DD:EE:FF
                Minor Type: Handheld
        """
        let parsed = BluetoothCoordinator.parseSystemProfilerOutput(output)
        #expect(parsed?.name == "TH-D74")
        #expect(parsed?.address == "AA:BB:CC:DD:EE:FF")
    }

    @Test("Returns nil when no supported radio is present")
    func returnsNilWhenNoRadioPaired() {
        let output = """
            AirPods Pro:
                Address: 00:11:22:33:44:55
                Minor Type: Headphones

            Magic Mouse:
                Address: 66:77:88:99:AA:BB
                Minor Type: Mouse
        """
        #expect(BluetoothCoordinator.parseSystemProfilerOutput(output) == nil)
    }

    @Test("Returns nil for empty input")
    func returnsNilForEmptyInput() {
        #expect(BluetoothCoordinator.parseSystemProfilerOutput("") == nil)
    }

    @Test("Picks the first TH-D7x when multiple devices are listed")
    func picksFirstOfMultipleDevices() {
        let output = """
            AirPods Pro:
                Address: 00:11:22:33:44:55

            TH-D75:
                Address: 12:34:56:78:9A:BC
                Minor Type: Handheld

            Magic Keyboard:
                Address: FF:EE:DD:CC:BB:AA
        """
        let parsed = BluetoothCoordinator.parseSystemProfilerOutput(output)
        #expect(parsed?.name == "TH-D75")
        #expect(parsed?.address == "12:34:56:78:9A:BC")
    }

    @Test("Rejects a stanza that names a TH-D75 but has no Address line")
    func rejectsStanzaMissingAddress() {
        let output = """
            TH-D75:
                Minor Type: Handheld
                Services: Serial Port
        """
        #expect(BluetoothCoordinator.parseSystemProfilerOutput(output) == nil)
    }

    @Test("Rejects an Address that's clearly not a MAC")
    func rejectsMalformedAddress() {
        let output = """
            TH-D75:
                Address: not-a-mac
                Minor Type: Handheld
        """
        #expect(BluetoothCoordinator.parseSystemProfilerOutput(output) == nil)
    }
}
#endif
