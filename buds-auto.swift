import CoreAudio
import Foundation
import IOBluetooth

// Watches for the earbuds being taken away while this Mac is producing audio, and
// asks for them back with the same take-over message a Samsung host sends.
// usage: buds-auto [address]

let address = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (ProcessInfo.processInfo.environment["BUDS_ADDR"] ?? "")

if address.isEmpty {
    print("set BUDS_ADDR or pass the earbuds Bluetooth address as the first argument")
    exit(2)
}
let poll: TimeInterval = 2
let retakeCooldown: TimeInterval = 20

func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
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

func switchFrame() -> [UInt8] {
    let body: [UInt8] = [0x71]
    let checksum = crc16(body)
    return [0xFE, UInt8(body.count + 2), 0x00] + body
        + [UInt8(checksum & 0xff), UInt8(checksum >> 8), 0xEE]
}

/// The vendor-channel frames Samsung's Windows host sends when it takes the earbuds:
/// autoswitch version 3, then the take-over request carrying the computer device class.
func vendorFrames() -> [[UInt8]] {
    [
        [0xFC, 0x0B, 0x00, 0x01, 0x43, 0x04, 0x03, 0x04, 0x00, 0x00, 0x0B, 0x03, 0x3F, 0xBF, 0xCC],
        [0xFC, 0x05, 0x10, 0x01, 0x71, 0x01, 0x79, 0x1C, 0xCC],
    ]
}

/// True when any output device is actually rendering audio right now.
func audioIsPlaying() -> Bool {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
        return false
    }
    var running = UInt32(0)
    var runningSize = UInt32(MemoryLayout<UInt32>.size)
    var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &runningSize, &running) == noErr else {
        return false
    }
    return running != 0
}

final class Delegate: NSObject, IOBluetoothRFCOMMChannelDelegate {}

func gearChannelID(_ device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
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
        return channelID
    }
    return nil
}

/// Writes the two vendor frames on the SPPSERVICE4 channel, matching Samsung's own host.
func sendVendorFrames(_ device: IOBluetoothDevice) {
    let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
    for record in records {
        guard let attr = record.getAttributeDataElement(0x0100),
              let raw = attr.getDataValue() as? Data,
              String(data: raw, encoding: .utf8) == "SPPSERVICE4" else { continue }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { return }
        let delegate = Delegate()
        var channel: IOBluetoothRFCOMMChannel?
        guard device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: delegate) == kIOReturnSuccess,
              let ch = channel else {
            log("vendor channel unavailable")
            return
        }
        for var frame in vendorFrames() {
            let count = frame.count
            _ = frame.withUnsafeMutableBytes { ch.writeSync($0.baseAddress, length: UInt16(count)) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 0.5)
        ch.close()
        log("vendor frames sent")
        return
    }
}

func sendSwitch(_ device: IOBluetoothDevice, _ channelID: BluetoothRFCOMMChannelID) -> Bool {
    let delegate = Delegate()
    var channel: IOBluetoothRFCOMMChannel?
    guard device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: delegate) == kIOReturnSuccess,
          let ch = channel else { return false }
    var payload = switchFrame()
    let count = payload.count
    var ok = false
    for _ in 0..<3 {
        let status: IOReturn = payload.withUnsafeMutableBytes {
            ch.writeSync($0.baseAddress, length: UInt16(count))
        }
        ok = ok || status == kIOReturnSuccess
        Thread.sleep(forTimeInterval: 0.3)
    }
    Thread.sleep(forTimeInterval: 1)
    ch.close()
    return ok
}

/// Asks up to three times, because a single request can land while the earbuds are
/// still settling after the device that took them connected.
func takeOver(_ device: IOBluetoothDevice) -> Bool {
    for attempt in 1...3 {
        if device.isConnected() { return true }
        if !device.isConnected() { _ = device.openConnection() }
        var waited = 0
        while !device.isConnected() && waited < 40 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
        guard let channelID = gearChannelID(device) else {
            Thread.sleep(forTimeInterval: 2)
            continue
        }
        sendVendorFrames(device)
        let sent = sendSwitch(device, channelID)
        log("attempt \(attempt): request sent=\(sent), connected=\(device.isConnected())")
        Thread.sleep(forTimeInterval: 2)
        if device.isConnected() && sent { return true }
    }
    return device.isConnected()
}

guard let buds = IOBluetoothDevice(addressString: address) else {
    log("device \(address) not found")
    exit(1)
}

log("watching \(buds.name ?? address)")
signal(SIGPIPE, SIG_IGN)
var wasConnected = buds.isConnected()
var wasPlaying = audioIsPlaying()
var lastRetake = Date.distantPast

while true {
    let connected = buds.isConnected()
    let playing = audioIsPlaying()

    // Claim when this Mac starts producing audio, the same moment a Galaxy host
    // asks for the earbuds. No waiting for another device to take them first.
    if playing && !wasPlaying && !connected {
        log("audio started here, claiming the earbuds")
        if Date().timeIntervalSince(lastRetake) >= retakeCooldown {
            lastRetake = Date()
            log(takeOver(buds) ? "claimed" : "claim failed")
        }
    }

    // And if they are taken while audio keeps running, ask again.
    if wasConnected && !connected && playing {
        log("earbuds taken while audio was playing, asking for them back")
        if Date().timeIntervalSince(lastRetake) >= retakeCooldown {
            lastRetake = Date()
            log(takeOver(buds) ? "take-over sent" : "take-over failed")
        }
    }
    if wasConnected != connected {
        log("link \(connected ? "up" : "down"), audio \(playing ? "playing" : "idle")")
    }
    wasConnected = connected
    wasPlaying = playing
    Thread.sleep(forTimeInterval: poll)
}
