import Foundation
import Testing
@testable import MacRatsCore

struct SerialPortDiscoveryTests {

    // MARK: - Classifier

    @Test("Classifies a usbmodem path as .usbModem")
    func classifiesUSBModem() {
        #expect(SerialPortDiscovery.classify("/dev/cu.usbmodem2011201") == .usbModem)
        #expect(SerialPortDiscovery.classify("/dev/cu.usbmodem14201") == .usbModem)
    }

    @Test("Classifies usbserial + SLAB paths as .usbSerial")
    func classifiesUSBSerial() {
        #expect(SerialPortDiscovery.classify("/dev/cu.usbserial-2011310") == .usbSerial)
        #expect(SerialPortDiscovery.classify("/dev/cu.SLAB_USBtoUART") == .usbSerial)
        #expect(SerialPortDiscovery.classify("/dev/cu.SLAB_USBtoUART12") == .usbSerial)
    }

    @Test("Classifies TH-D75 path as .bluetooth")
    func classifiesTHD75AsBluetooth() {
        #expect(SerialPortDiscovery.classify("/dev/cu.TH-D75") == .bluetooth)
        #expect(SerialPortDiscovery.classify("/dev/cu.TH-D75-SerialPort") == .bluetooth)
        #expect(SerialPortDiscovery.classify("/dev/cu.thd75") == .bluetooth)
    }

    @Test("Classifies TH-D74 path as .bluetooth")
    func classifiesTHD74AsBluetooth() {
        #expect(SerialPortDiscovery.classify("/dev/cu.TH-D74") == .bluetooth)
        #expect(SerialPortDiscovery.classify("/dev/cu.thd74") == .bluetooth)
    }

    @Test("Classifies debug-console as .other")
    func classifiesDebugConsoleAsOther() {
        #expect(SerialPortDiscovery.classify("/dev/cu.debug-console") == .other)
    }

    @Test("Bluetooth-Incoming-Port is detected as bluetooth")
    func bluetoothIncomingPort() {
        #expect(SerialPortDiscovery.classify("/dev/cu.Bluetooth-Incoming-Port") == .bluetooth)
    }

    @Test("Leaf name strips /dev/cu. prefix")
    func leafName() {
        let port = SerialPortDiscovery.Port(path: "/dev/cu.usbmodem2011201", kind: .usbModem)
        #expect(port.leafName == "usbmodem2011201")
    }

    // MARK: - availablePorts()

    @Test("availablePorts returns real devices in the expected order")
    func availablePortsSorted() {
        let ports = SerialPortDiscovery.availablePorts()
        // We can't predict exactly which ports are present on a given machine,
        // but we CAN verify that if ports of different kinds exist, usbModem
        // comes before bluetooth which comes before other.
        var lastOrder = -1
        var seenKinds = Set<SerialPortDiscovery.Kind>()
        for port in ports {
            seenKinds.insert(port.kind)
            let order: Int
            switch port.kind {
            case .usbModem:  order = 0
            case .usbSerial: order = 1
            case .bluetooth: order = 2
            case .other:     order = 3
            }
            #expect(order >= lastOrder, "ports must be sorted by kind (usbModem, usbSerial, bluetooth, other) — got \(port.path) after kind with order \(lastOrder)")
            lastOrder = order
        }
        // At least some ports should exist on any dev Mac — if none show up,
        // the directory walker is broken.
        #expect(!ports.isEmpty, "no /dev/cu.* devices found at all — very suspicious")
    }
}
