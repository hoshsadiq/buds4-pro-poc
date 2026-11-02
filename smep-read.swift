import Foundation
import IOBluetooth

// Opens the Samsung vendor channel to the earbuds, writes one SMEP frame, and
// dumps everything that comes back as hex so peer records can be inspected.
// usage: smep-read <address> <hexframe> [seconds]

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: smep-read <address> <hexframe> [seconds]")
    exit(2)
}
let address = args[1]
let hex = args[2].replacingOccurrences(of: " ", with: "")
let seconds = args.count > 3 ? (Double(args[3]) ?? 4) : 4
let serviceName = "SPPSERVICE4"

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

final class ChannelDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var received = [UInt8]()
    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        received.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
    }
}

guard let device = IOBluetoothDevice(addressString: address) else {
    print("cannot resolve \(address)")
    exit(1)
}
if !device.isConnected() {
    let status = device.openConnection()
    if status != kIOReturnSuccess {
        print("baseband connect failed \(status)")
        exit(1)
    }
}
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
    if let attr = record.getAttributeDataElement(0x0100),
       let raw = attr.getDataValue() as? Data,
       String(data: raw, encoding: .utf8) == serviceName {
        if record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess { found = true }
        break
    }
}
guard found else {
    print("SMEP service not advertised")
    exit(1)
}

let delegate = ChannelDelegate()
var channel: IOBluetoothRFCOMMChannel?
let openStatus = device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: delegate)
guard openStatus == kIOReturnSuccess, let ch = channel else {
    print("open failed status=\(openStatus)")
    exit(1)
}
var waited = 0
while !ch.isOpen() && waited < 20 {
    Thread.sleep(forTimeInterval: 0.1)
    waited += 1
}
print("channel open=\(ch.isOpen())")

var frame = bytes(hex)
let length = UInt16(frame.count)
let status: IOReturn = frame.withUnsafeMutableBytes { buffer in
    ch.writeSync(buffer.baseAddress, length: length)
}
if status != kIOReturnSuccess { print("write failed \(status)") }

Thread.sleep(forTimeInterval: seconds)
ch.close()
print("rx \(delegate.received.count) bytes")
print(delegate.received.map { String(format: "%02X", $0) }.joined(separator: " "))
