import Foundation
import IOBluetooth

// Sends one standard-channel frame to the earbuds (channel GEARMANAGER) and prints
// whatever comes back. Standard frames are FE ... EE, unlike the SMEP channel.
// usage: gear <address> <hexframe> [seconds]

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: gear <address> <hexframe> [seconds]")
    exit(2)
}
let address = args[1]
let hex = args[2].replacingOccurrences(of: " ", with: "")
let seconds = args.count > 3 ? (Double(args[3]) ?? 4) : 4
let serviceName = "GEARMANAGER"

func bytes(_ s: String) -> [UInt8] {
    var out = [UInt8]()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        if let v = UInt8(s[i..<j], radix: 16) { out.append(v) }
        i = j
    }
    return out
}

final class Delegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var received = [UInt8]()
    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        received.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
    }
}

guard let device = IOBluetoothDevice(addressString: address) else {
    print("cannot resolve \(address)")
    exit(1)
}
if !device.isConnected() { _ = device.openConnection() }
if device.services == nil {
    _ = device.performSDPQuery(nil)
    var waited = 0
    while device.services == nil && waited < 40 {
        Thread.sleep(forTimeInterval: 0.1)
        waited += 1
    }
}
let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
var channelID: BluetoothRFCOMMChannelID = 0
var found = false
for record in records {
    guard let attr = record.getAttributeDataElement(0x0100),
          let raw = attr.getDataValue() as? Data,
          String(data: raw, encoding: .utf8) == serviceName else { continue }
    if record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess { found = true }
    break
}
guard found else {
    print("\(serviceName) not advertised")
    exit(1)
}

let delegate = Delegate()
var channel: IOBluetoothRFCOMMChannel?
guard device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: delegate) == kIOReturnSuccess,
      let ch = channel else {
    print("channel open refused")
    exit(1)
}
var waited = 0
while !ch.isOpen() && waited < 20 {
    Thread.sleep(forTimeInterval: 0.1)
    waited += 1
}

var payload = bytes(hex)
let count = payload.count
let status: IOReturn = payload.withUnsafeMutableBytes {
    ch.writeSync($0.baseAddress, length: UInt16(count))
}
print("write status=\(status)")
Thread.sleep(forTimeInterval: seconds)
ch.close()
print("rx \(delegate.received.count)")
print(delegate.received.map { String(format: "%02X", $0) }.joined(separator: " "))
