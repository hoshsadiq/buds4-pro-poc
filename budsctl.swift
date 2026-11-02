import Foundation
import IOBluetooth

// Manual handoff control for Galaxy Buds, the switching model Buds4 Pro supports.
// take    opens the audio link and holds the vendor channel, which moves audio to this Mac
// release closes the channel and the link, so another device can take the earbuds
// status  reports whether the buds are connected and to whom
// usage: budsctl take|release|status [address]

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "status"
let address = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : (ProcessInfo.processInfo.environment["BUDS_ADDR"] ?? "")

if address.isEmpty {
    print("set BUDS_ADDR or pass the earbuds Bluetooth address")
    exit(2)
}
let serviceName = "SPPSERVICE4"
let holdFile = "/tmp/budsctl-hold"

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("\(stamp) \(message)")
    fflush(stdout)
}

func crc16(_ data: [UInt8]) -> UInt16 {
    var table = [UInt16]()
    for index in 0..<256 {
        var value = UInt16(index) << 8
        for _ in 0..<8 {
            value = (value & 0x8000) != 0 ? (value << 1) ^ 0x1021 : (value << 1)
        }
        table.append(value)
    }
    var crc: UInt16 = 0
    for byte in data { crc = table[Int((crc >> 8) ^ UInt16(byte))] ^ (crc << 8) }
    return crc
}

func smepFrame(_ messageID: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let body = [0x01, messageID] + payload
    let checksum = crc16(body)
    return [0xFC, UInt8(body.count + 2), 0x00] + body + [UInt8(checksum & 0xff), UInt8(checksum >> 8), 0xCC]
}

/// Standard channel frame, used for the announcement and the take-over request.
func standardFrame(_ messageID: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
    let body: [UInt8] = [messageID] + payload
    let checksum = crc16(body)
    return [0xFE, UInt8(body.count + 2), 0x00] + body
        + [UInt8(checksum & 0xff), UInt8(checksum >> 8), 0xEE]
}

/// Message 0x73. Announces this host as a Samsung peer and which transport it uses.
/// The transport byte is 1 for ordinary Bluetooth and 2 for LE Audio.
func settingInfoFrame(transport: UInt8) -> [UInt8] {
    standardFrame(0x73, [0x01, transport] + [UInt8](repeating: 0, count: 15))
}

/// Message 0x43 on the vendor channel, with the metadata version at offset 0x0B.
/// Three means auto-switch is enabled, zero returns the earbuds to the generic state.
func metadataFrame(version: UInt8) -> [UInt8] {
    smepFrame(0x43, [0x43, 0x04, 0x03, 0x04, 0x00, 0x00, 0x0B, version])
}

/// Message 0x71. The take-over request, with one payload byte holding the host device
/// class. One means computer. This is the frame that actually moves audio.
func takeOverFrame() -> [UInt8] {
    standardFrame(0x71, [0x01])
}

func gearChannel(_ device: IOBluetoothDevice, _ delegate: Delegate) -> IOBluetoothRFCOMMChannel? {
    if device.services == nil {
        _ = device.performSDPQuery(nil)
        var waited = 0
        while device.services == nil && waited < 40 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
    }
    let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
    for record in records {
        guard let attr = record.getAttributeDataElement(0x0100),
              let raw = attr.getDataValue() as? Data,
              String(data: raw, encoding: .utf8) == "GEARMANAGER" else { continue }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { return nil }
        var channel: IOBluetoothRFCOMMChannel?
        guard device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: delegate) == kIOReturnSuccess,
              let ch = channel else { return nil }
        return ch
    }
    return nil
}

func send(_ channel: IOBluetoothRFCOMMChannel, _ frame: [UInt8]) -> Bool {
    var payload = frame
    let count = payload.count
    return payload.withUnsafeMutableBytes {
        channel.writeSync($0.baseAddress, length: UInt16(count))
    } == kIOReturnSuccess
}

/// The three frames Samsung's host sends, in order: announce, enable auto-switch,
/// then ask for the earbuds.
func claim(_ device: IOBluetoothDevice) -> Bool {
    if !isConnected(device) {
        log("opening link (status \(device.openConnection()))")
    }
    _ = waitConnected(device, 50)

    let delegate = Delegate()
    var sent = false
    if let gear = gearChannel(device, delegate) {
        sent = send(gear, settingInfoFrame(transport: 1))
        log("setting info sent: \(sent)")
        Thread.sleep(forTimeInterval: 0.3)
        gear.close()
    }

    if let vendor = vendorChannel(device, Delegate()) {
        let ok = send(vendor, metadataFrame(version: 3))
        log("metadata version 3 sent: \(ok)")
        Thread.sleep(forTimeInterval: 0.3)
        vendor.close()
    }

    if let gear = gearChannel(device, Delegate()) {
        let ok = send(gear, takeOverFrame())
        log("take-over request sent: \(ok)")
        sent = sent || ok
        Thread.sleep(forTimeInterval: 1)
        gear.close()
    }
    return sent
}

final class Delegate: NSObject, IOBluetoothRFCOMMChannelDelegate {}

func resolve(_ address: String) -> IOBluetoothDevice? {
    IOBluetoothDevice(addressString: address)
}

func isConnected(_ device: IOBluetoothDevice) -> Bool {
    device.isConnected()
}

func waitConnected(_ device: IOBluetoothDevice, _ tries: Int) -> Bool {
    var waited = 0
    while !isConnected(device) && waited < tries {
        Thread.sleep(forTimeInterval: 0.1)
        waited += 1
    }
    return isConnected(device)
}

func vendorChannel(_ device: IOBluetoothDevice, _ delegate: Delegate) -> IOBluetoothRFCOMMChannel? {
    if device.services == nil {
        _ = device.performSDPQuery(nil)
        var waited = 0
        while device.services == nil && waited < 40 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
    }
    let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
    for record in records {
        guard let attr = record.getAttributeDataElement(0x0100),
              let raw = attr.getDataValue() as? Data,
              String(data: raw, encoding: .utf8) == serviceName else { continue }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { return nil }
        var channel: IOBluetoothRFCOMMChannel?
        guard device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: delegate) == kIOReturnSuccess,
              let ch = channel else { return nil }
        return ch
    }
    return nil
}

func take(_ device: IOBluetoothDevice) -> Bool {
    if !isConnected(device) {
        log("opening audio link")
        let status = device.openConnection()
        guard status == kIOReturnSuccess else {
            log("connect refused by the earbuds (status \(status))")
            return false
        }
    }
    guard waitConnected(device, 50) else {
        log("link did not come up")
        return false
    }
    log("link up, holding vendor channel")

    let delegate = Delegate()
    guard let ch = vendorChannel(device, delegate) else {
        log("vendor channel refused")
        return false
    }
    let written = send(ch, metadataFrame(version: 3))
    log("metadata version 3 written: \(written), holding")
    FileManager.default.createFile(atPath: holdFile, contents: nil)
    while FileManager.default.fileExists(atPath: holdFile) {
        Thread.sleep(forTimeInterval: 1)
        if !isConnected(device) {
            log("link dropped")
            break
        }
    }
    ch.close()
    return true
}

func release(_ device: IOBluetoothDevice) {
    try? FileManager.default.removeItem(atPath: holdFile)
    if isConnected(device) {
        log("closing link so another device can take over")
        device.closeConnection()
    } else {
        log("already disconnected")
    }
}

guard let device = resolve(address) else {
    log("device \(address) not found")
    exit(1)
}

switch command {
case "switch":
    log("asking the earbuds to move audio to this Mac")
    _ = claim(device)
case "take":
    log("taking \(device.name ?? address)")
    _ = take(device)
case "release":
    release(device)
case "status":
    log("\(device.name ?? address) connected=\(isConnected(device))")
default:
    log("usage: budsctl take|release|status [address]")
    exit(2)
}
