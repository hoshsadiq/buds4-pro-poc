import Foundation
import IOBluetooth

// Pairs with the earbuds over classic Bluetooth and reports the result, so we can see
// which profiles macOS negotiated, including whether LE Audio appears.

let address = ProcessInfo.processInfo.environment["BUDS_ADDR"] ?? CommandLine.arguments.dropFirst().first ?? ""
if address.isEmpty {
    print("set BUDS_ADDR")
    exit(2)
}

func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
    fflush(stdout)
}

guard let device = IOBluetoothDevice(addressString: address) else {
    log("cannot resolve \(address)")
    exit(1)
}

log("device \(device.name ?? "?") paired=\(device.isPaired()) connected=\(device.isConnected())")

if !device.isPaired() {
    log("requesting pairing, confirm it on screen if asked")
    if let pairer = IOBluetoothDevicePair(device: device) {
        pairer.start()
        log("pairing started")
    } else {
        log("could not create a pairing session")
    }
}

var waited = 0
while !device.isPaired() && waited < 60 {
    Thread.sleep(forTimeInterval: 0.5)
    waited += 1
}
log("paired=\(device.isPaired()) after \(waited / 2)s")

if device.isPaired() && !device.isConnected() {
    log("opening connection")
    _ = device.openConnection()
    waited = 0
    while !device.isConnected() && waited < 40 {
        Thread.sleep(forTimeInterval: 0.25)
        waited += 1
    }
}
log("connected=\(device.isConnected())")

_ = device.performSDPQuery(nil)
waited = 0
while device.services == nil && waited < 40 {
    Thread.sleep(forTimeInterval: 0.2)
    waited += 1
}
let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
log("services \(records.count)")
for record in records {
    var name = "-"
    if let attr = record.getAttributeDataElement(0x0100), let raw = attr.getDataValue() as? Data {
        name = String(data: raw, encoding: .utf8) ?? "-"
    }
    var channel: BluetoothRFCOMMChannelID = 0
    let hasChannel = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess
    log("  \(name) rfcomm=\(hasChannel ? String(channel) : "-")")
}
