import Foundation
import IOBluetooth

// Keeps multipoint open on Galaxy Buds by writing the MDE_VERSION asVer field on
// the SMEP channel: once when the buds connect, then on a slow heartbeat.
// No Samsung account and no Galaxy Buds app involved.

let budAddress = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (ProcessInfo.processInfo.environment["BUDS_ADDR"] ?? "")

if budAddress.isEmpty {
    print("set BUDS_ADDR or pass the earbuds Bluetooth address as the first argument")
    exit(2)
}
let heartbeat: TimeInterval = 20
let smepServiceName = "SPPSERVICE4"

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("\(stamp) \(message)")
    fflush(stdout)
}

func crc16(_ data: [UInt8]) -> UInt16 {
    var table = [UInt16]()
    for index in 0..<256 {
        var crc = UInt16(index) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
        }
        table.append(crc)
    }
    var value: UInt16 = 0
    for byte in data {
        value = table[Int((value >> 8) ^ UInt16(byte))] ^ (value << 8)
    }
    return value
}

/// SMEP frame carrying MDE_VERSION (opcode 0x0b) with the given asVer value.
func asVerFrame(_ version: UInt8) -> [UInt8] {
    let body: [UInt8] = [0x01, 0x04, 0x03, 0x04, 0x00, 0x00, 0x0b, version]
    let checksum = crc16(body)
    return [0xfc, UInt8(body.count + 2), 0x00] + body
        + [UInt8(checksum & 0xff), UInt8(checksum >> 8), 0xcc]
}

func serviceRecords(_ device: IOBluetoothDevice) -> [IOBluetoothSDPServiceRecord] {
    if device.services == nil {
        _ = device.performSDPQuery(nil)
        var waited = 0
        while device.services == nil && waited < 40 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
    }
    return (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
}

func smepChannelID(_ device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
    for record in serviceRecords(device) {
        guard let attr = record.getAttributeDataElement(0x0100),
              let raw = attr.getDataValue() as? Data,
              String(data: raw, encoding: .utf8) == smepServiceName else {
            continue
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        if record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
            return channelID
        }
    }
    return nil
}

final class ChannelDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {}

let channelDelegate = ChannelDelegate()

func openChannel(_ device: IOBluetoothDevice, _ channelID: BluetoothRFCOMMChannelID) -> IOBluetoothRFCOMMChannel? {
    var channel: IOBluetoothRFCOMMChannel?
    guard device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: channelDelegate) == kIOReturnSuccess else {
        return nil
    }
    var waited = 0
    while channel?.isOpen() != true && waited < 20 {
        Thread.sleep(forTimeInterval: 0.1)
        waited += 1
    }
    return channel?.isOpen() == true ? channel : nil
}

func writeFrame(_ channel: IOBluetoothRFCOMMChannel, _ frame: [UInt8]) -> Bool {
    var payload = frame
    let length = UInt16(payload.count)
    for _ in 0..<3 {
        let status: IOReturn = payload.withUnsafeMutableBytes { buffer in
            channel.writeSync(buffer.baseAddress, length: length)
        }
        if status == kIOReturnSuccess {
            return true
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    return false
}

func writeAsVer(_ device: IOBluetoothDevice, version: UInt8) -> Bool {
    guard let channelID = smepChannelID(device) else {
        log("SMEP service not advertised")
        return false
    }
    guard let channel = openChannel(device, channelID) else {
        log("could not open the SMEP channel")
        return false
    }
    let ok = writeFrame(channel, asVerFrame(version))
    channel.close()
    return ok
}

signal(SIGPIPE, SIG_IGN)
signal(SIGINT) { _ in
    log("interrupted")
    exit(0)
}

log("starting for \(budAddress)")
var lastWrite = Date.distantPast

while true {
    if let device = IOBluetoothDevice(addressString: budAddress) {
        if device.isConnected() && Date().timeIntervalSince(lastWrite) >= heartbeat {
            if writeAsVer(device, version: 2) {
                lastWrite = Date()
                log("asVer=2 written")
            } else {
                log("write failed, retrying")
            }
        }
    }
    Thread.sleep(forTimeInterval: 5)
}
