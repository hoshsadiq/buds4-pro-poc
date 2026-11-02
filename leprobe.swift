import CoreBluetooth
import Foundation

// Lists Bluetooth Low Energy advertisers and their service UUIDs, so we can see
// whether the earbuds offer the LE Audio services (PACS 0x184D, ASCS 0x184E,
// BASS 0x184F) to this Mac. CoreBluetooth scans for LE only.

final class Probe: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager?
    let deadline = Date().addingTimeInterval(12)

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("scanning for low energy advertisers")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        default:
            print("central state \(central.state.rawValue), cannot scan")
            exit(1)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "-"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let text = services.map { $0.uuidString }.joined(separator: ",")
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? false
        let manufacturer = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.map {
            String(format: "%02X", $0)
        }.joined() ?? ""
        print("LE  \(name)  id=\(peripheral.identifier.uuidString.prefix(8))  rssi=\(RSSI)  connectable=\(connectable)  services=[\(text)]  mfr=[\(manufacturer.prefix(20))]")
        _ = [CBUUID(string: "184D"), CBUUID(string: "184E"), CBUUID(string: "184F")]
        if Date() > deadline {
            central.stopScan()
            exit(0)
        }
    }
}

let probe = Probe()
probe.start()
while Date() < probe.deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
}
probe.central?.stopScan()
print("scan finished")
