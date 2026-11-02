import Foundation
import IOBluetooth

// Speaks the Samsung SMEP host protocol to Galaxy Buds: keeps the vendor channel
// open, answers the buds' property reads, and refreshes the multipoint permission
// value. Logs every frame so the exchange is visible.
// usage: smep-host <address>

let address = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (ProcessInfo.processInfo.environment["BUDS_ADDR"] ?? "")

if address.isEmpty {
    print("set BUDS_ADDR or pass the earbuds Bluetooth address as the first argument")
    exit(2)
}
let serviceName = "SPPSERVICE4"
let asVerRefresh: TimeInterval = 20

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
    for byte in data {
        crc = table[Int((crc >> 8) ^ UInt16(byte))] ^ (crc << 8)
    }
    return crc
}

/// SMEP frame: preamble, length, type, message id, payload, checksum, postamble.
func frame(_ messageID: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let body = [0x01, messageID] + payload
    let checksum = crc16(body)
    return [0xFC, UInt8(body.count + 2), 0x00] + body + [UInt8(checksum & 0xff), UInt8(checksum >> 8), 0xCC]
}

func tlv(_ tag: Int, _ value: [UInt8]) -> [UInt8] {
    [UInt8(tag & 0xff), UInt8(tag >> 8), UInt8(value.count)] + value
}

let propertyNames: [Int: String] = [
    0x0301: "CMD_SUBSCRIBE",
    0x0401: "DESCRIPTION_EIR_MANU_DATA",
    0xC102: "CUSTOM_DISC_FOR_AUTO_SWITCH",
    0xC103: "CUSTOM_CONNECTION_STATE",
    0xC106: "CUSTOM_CONNECTED_WITH_PROFILE",
    0x0100: "SUPPORTED_FEATURES",
    0x0108: "FEATURE_SEAMLESS",
    0x010E: "FEATURE_AUTO_SWITCH",
    0x0200: "ALL_CURRENT_STATES",
    0x0213: "STATE_SEAMLESS",
    0x0219: "STATE_DEVICE_GROUP_ID",
    0x021F: "STATE_CONN_COUNT",
    0x0224: "STATE_BONDED_DEVICES",
]

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

final class Host: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var buffer = [UInt8]()
    var channel: IOBluetoothRFCOMMChannel?

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        buffer.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
        parse()
    }

    func parse() {
        while buffer.count >= 4, buffer[0] == 0xFC {
            let size = Int(buffer[1])
            guard buffer.count >= size + 2 else { return }
            let body = Array(buffer[2..<(size + 1)])
            buffer.removeFirst(size + 2)
            handle(body)
        }
        if let start = buffer.firstIndex(of: 0xFC), start > 0 {
            buffer.removeFirst(start)
        }
    }

    func handle(_ body: [UInt8]) {
        guard body.count >= 2 else { return }
        let messageID = body[1]
        let payload = Array(body.dropFirst(2))
        switch messageID {
        case 0x44:
            log("read request \(hex(payload))")
            answer(payload)
        case 0x43:
            log("write \(hex(payload))")
        case 0x45:
            log("notify \(describe(payload))")
        default:
            log("message \(String(format: "%02X", messageID)) \(hex(payload))")
        }
    }

    private func answer(_ payload: [UInt8]) {
        var index = 0
        var out = [UInt8]()
        while index + 2 < payload.count {
            let tag = Int(payload[index]) | (Int(payload[index + 1]) << 8)
            let length = Int(payload[index + 2])
            index += 3 + length
            let value: [UInt8] = tag == 0x021F ? [0x01] : [0x01]
            out += tlv(tag, value)
            log("  answer \(propertyNames[tag] ?? String(format: "0x%04X", tag)) = \(hex(value))")
        }
        if !out.isEmpty {
            send(frame(0x45, out))
        }
    }

    func send(_ bytes: [UInt8]) {
        guard let ch = channel else { return }
        var payload = bytes
        let count = payload.count
        let status: IOReturn = payload.withUnsafeMutableBytes {
            ch.writeSync($0.baseAddress, length: UInt16(count))
        }
        if status != kIOReturnSuccess {
            log("write failed \(status)")
        }
    }

    private func describe(_ payload: [UInt8]) -> String {
        var parts = [String]()
        var index = 0
        while index + 2 < payload.count {
            let tag = Int(payload[index]) | (Int(payload[index + 1]) << 8)
            let length = Int(payload[index + 2])
            let end = min(payload.count, index + 3 + length)
            let value = Array(payload[(index + 3)..<end])
            parts.append("\(propertyNames[tag] ?? String(format: "0x%04X", tag))=\(hex(value))")
            index += 3 + length
        }
        return parts.isEmpty ? hex(payload) : parts.joined(separator: " ")
    }
}

func waitForServices(_ device: IOBluetoothDevice) {
    guard device.services == nil else { return }
    _ = device.performSDPQuery(nil)
    var waited = 0
    while device.services == nil && waited < 40 {
        Thread.sleep(forTimeInterval: 0.1)
        waited += 1
    }
}

func smepChannelID(_ records: [IOBluetoothSDPServiceRecord]) -> BluetoothRFCOMMChannelID? {
    for record in records {
        guard let attr = record.getAttributeDataElement(0x0100),
              let raw = attr.getDataValue() as? Data,
              String(data: raw, encoding: .utf8) == serviceName else { continue }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { return nil }
        return channelID
    }
    return nil
}

func openChannel(_ device: IOBluetoothDevice, _ channelID: BluetoothRFCOMMChannelID,
                 _ delegate: Host) -> IOBluetoothRFCOMMChannel? {
    var channel: IOBluetoothRFCOMMChannel?
    guard device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: delegate) == kIOReturnSuccess,
          let ch = channel else { return nil }
    var waited = 0
    while !ch.isOpen() && waited < 20 {
        Thread.sleep(forTimeInterval: 0.1)
        waited += 1
    }
    return ch.isOpen() ? ch : nil
}

func openSMEPChannel(_ device: IOBluetoothDevice, _ delegate: Host) -> IOBluetoothRFCOMMChannel? {
    waitForServices(device)
    let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
    guard let channelID = smepChannelID(records) else { return nil }
    return openChannel(device, channelID, delegate)
}

func permissionFrame() -> [UInt8] {
    frame(0x43, [0x43] + tlv(0x040B, [0x04, 0x00, 0x00, 0x0B, 0x02]))
}

/// Tells the earbuds this host wants property notifications, which is what lets
/// them send a handoff request instead of dropping the link silently.
func subscribeFrame() -> [UInt8] {
    frame(0x43, tlv(0x0301, [0x01]))
}

/// Samsung manufacturer data identifying this host as a Galaxy-class device that
/// supports seamless connection and auto switch.
func samsungIdentityFrame() -> [UInt8] {
    let manufacturerData: [UInt8] = [
        0x75, 0x00,             // Samsung company id, little endian
        0x00, 0x00, 0x00,
        0x09,                   // service id: Samsung wearable service
        0x00, 0x00,             // associated service id
        0x02,                   // proximity type
        0x00,
        0x02,                   // device type: phone
        0x00, 0x00, 0x00, 0x00,
        0x04,                   // LE connectivity field present
        0x00, 0x00, 0x00,
    ]
    return frame(0x43, tlv(0x0401, manufacturerData))
}

let host = Host()
var lastRefresh = Date.distantPast
var lastPoll = Date.distantPast
signal(SIGPIPE, SIG_IGN)
log("starting host for \(address)")

while true {
    if host.channel == nil {
        if let device = IOBluetoothDevice(addressString: address) {
            if !device.isConnected() { _ = device.openConnection() }
            if let ch = openSMEPChannel(device, host) {
                host.channel = ch
                log("host channel open")
                host.send(subscribeFrame())
                log("subscribed to property notifications")
                host.send(samsungIdentityFrame())
                log("announced Samsung host identity")
                host.send(permissionFrame())
                lastRefresh = Date()
            }
        }
    } else if Date().timeIntervalSince(lastPoll) >= 10 {
        host.send(frame(0x44, tlv(0x021F, [])))
        host.send(frame(0x44, tlv(0x0219, [])))
        lastPoll = Date()
    } else if Date().timeIntervalSince(lastRefresh) >= asVerRefresh {
        host.send(permissionFrame())
        lastRefresh = Date()
        log("permission refreshed")
    }
    Thread.sleep(forTimeInterval: 2)
}
