import CoreAudio
import Foundation
import IOBluetooth

// Mirrors Samsung's Windows auto-switch behaviour: watch local audio, read the
// earbuds' own multipoint status, ask for the earbuds when this Mac is playing,
// stand down when the other device is on a call, and give up after a timeout.
// usage: buds-sync [address]

let address = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (ProcessInfo.processInfo.environment["BUDS_ADDR"] ?? "")

if address.isEmpty {
    print("set BUDS_ADDR or pass the earbuds Bluetooth address as the first argument")
    exit(2)
}
let gearService = "GEARMANAGER"
let vendorService = "SPPSERVICE4"

let pollInterval: TimeInterval = 1.5
let antiFightWindow: TimeInterval = 3
let sustainWindow: TimeInterval = 1
let requestTimeout: TimeInterval = 12
let requestSpacing: TimeInterval = 3

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

/// Standard channel frame, used for the multipoint status request.
func standardFrame(_ messageID: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
    let body: [UInt8] = [messageID] + payload
    let checksum = crc16(body)
    return [0xFE, UInt8(body.count + 2), 0x00] + body
        + [UInt8(checksum & 0xff), UInt8(checksum >> 8), 0xEE]
}

/// Vendor channel frames, byte for byte what Samsung's Windows host sends:
/// autoswitch metadata version 3, then the take-over request for a computer.
let vendorFrames: [[UInt8]] = [
    [0xFC, 0x0C, 0x00, 0x01, 0x43, 0x43, 0x04, 0x03, 0x04, 0x00, 0x00, 0x0B, 0x03, 0xC4, 0x49, 0xCC],
    [0xFC, 0x05, 0x10, 0x01, 0x71, 0x01, 0x79, 0x1C, 0xCC],
]

/// Sent when quitting, so the earbuds are not left in autoswitch mode.
let genericVersionFrame: [UInt8] =
    [0xFC, 0x0C, 0x00, 0x01, 0x43, 0x43, 0x04, 0x03, 0x04, 0x00, 0x00, 0x0B, 0x00, 0xA7, 0x79, 0xCC]

/// Sends Samsung's two vendor frames: auto-switch metadata version 3, then the
/// take-over request carrying the computer device class.
func claim(_ device: IOBluetoothDevice) -> Bool {
    if !device.isConnected() { _ = device.openConnection() }
    var waited = 0
    while !device.isConnected() && waited < 40 {
        Thread.sleep(forTimeInterval: 0.1)
        waited += 1
    }
    if vendor.channel?.isOpen() != true {
        _ = open(device, named: vendorService, vendor)
    }
    guard vendor.channel?.isOpen() == true else { return false }
    var sent = false
    for frame in vendorFrames {
        sent = write(vendor, frame) || sent
        Thread.sleep(forTimeInterval: 0.3)
    }
    return sent
}

struct MultipointStatus {
    var support = 0
    var state = 0
    var focus = 0
    var streaming: UInt8 = 0

    /// Samsung's StreamType bits: A2DP 1, HFP 2, CIS_MEDIA 4, BIS 8, CIS_CALL 16.
    var otherDeviceOnCall: Bool {
        streaming & (2 | 0x10) != 0
    }
    var ours: Bool { focus != 0 }
}

/// Name of the current default output device, used to tell whether the earbuds
/// already own audio. Samsung's host checks the same thing instead of trusting
/// the earbuds' reported focus.
func defaultOutputName() -> String {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var getAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &getAddress, 0, nil, &size, &device) == noErr else {
        return ""
    }
    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr else {
        return ""
    }
    return (name?.takeRetainedValue() as String?) ?? ""
}

/// Every output device with its name, so the earbuds can be found and made the default.
func outputDevices() -> [(id: AudioDeviceID, name: String)] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
        return []
    }

    var found: [(AudioDeviceID, String)] = []
    for id in ids {
        var streams = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var streamSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else {
            continue
        }
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var name: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr else {
            continue
        }
        found.append((id, (name?.takeRetainedValue() as String?) ?? ""))
    }
    return found
}

/// Makes an output device the system default, which is what a Samsung host does after it
/// wins the earbuds. Without this the music keeps going to the speakers.
@discardableResult
func makeDefaultOutput(matching token: String) -> Bool {
    guard let target = outputDevices().first(where: { $0.name.lowercased().contains(token) }) else {
        return false
    }
    if defaultOutputName().lowercased().contains(token) {
        return true
    }
    var device = target.id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &device)
    return status == noErr
}

func audioIsPlaying() -> Bool {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var getAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &getAddress, 0, nil, &size, &device) == noErr else {
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

final class Channel: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var buffer = [UInt8]()
    var onFrame: (([UInt8]) -> Void)?

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        buffer.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
        var index = 0
        while index + 3 < buffer.count {
            let preamble = buffer[index]
            guard preamble == 0xFC || preamble == 0xFE || preamble == 0xFD else {
                index += 1
                continue
            }
            let size = Int(buffer[index + 1])
            guard index + size + 2 <= buffer.count else { break }
            let frame = Array(buffer[index..<(index + size + 2)])
            index += size + 2
            onFrame?(frame)
        }
        if index > 0 { buffer.removeFirst(index) }
    }
}

func services(_ device: IOBluetoothDevice) -> [IOBluetoothSDPServiceRecord] {
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

func channelID(_ device: IOBluetoothDevice, named name: String) -> BluetoothRFCOMMChannelID? {
    for record in services(device) {
        guard let attr = record.getAttributeDataElement(0x0100),
              let raw = attr.getDataValue() as? Data,
              String(data: raw, encoding: .utf8) == name else { continue }
        var id: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&id) == kIOReturnSuccess else { return nil }
        return id
    }
    return nil
}

func open(_ device: IOBluetoothDevice, named name: String, _ channel: Channel) -> Bool {
    guard let id = channelID(device, named: name) else { return false }
    var rfcomm: IOBluetoothRFCOMMChannel?
    guard device.openRFCOMMChannelSync(&rfcomm, withChannelID: id, delegate: channel) == kIOReturnSuccess,
          let ch = rfcomm, ch.isOpen() else { return false }
    channel.channel = ch
    return true
}

private let writeQueue = DispatchQueue(label: "buds.write", qos: .userInitiated)

/// Writes with a deadline. A dead link makes writeSync block instead of failing, which
/// would stall the whole loop, so the write runs on another queue and is abandoned if
/// it does not come back in time.
@discardableResult
func write(_ channel: Channel, _ bytes: [UInt8], timeout: TimeInterval = 2) -> Bool {
    guard let ch = channel.channel else { return false }
    if !ch.isOpen() {
        channel.channel = nil
        return false
    }
    let done = DispatchSemaphore(value: 0)
    var ok = false
    writeQueue.async {
        var payload = bytes
        let count = payload.count
        ok = payload.withUnsafeMutableBytes {
            ch.writeSync($0.baseAddress, length: UInt16(count))
        } == kIOReturnSuccess
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        channel.channel = nil
        return false
    }
    if !ok { channel.channel = nil }
    return ok
}

func parseStatus(_ frame: [UInt8]) -> MultipointStatus? {
    guard frame.count > 9 else { return nil }
    let messageID = frame[3]
    guard messageID == 0x76 else { return nil }
    let payload = Array(frame[4..<(frame.count - 3)])
    guard payload.count >= 5 else { return nil }
    return MultipointStatus(support: Int(payload[1]), state: Int(payload[2]),
                            focus: Int(payload[3]), streaming: payload[4])
}

guard let buds = IOBluetoothDevice(addressString: address) else {
    log("device \(address) not found")
    exit(1)
}

/// Mutes or unmutes the current output device. Samsung backs up the user's own mute
/// state first, so unmuting never overrides a mute the user set deliberately.
var userWasMuted: Bool?

func outputIsMuted() -> Bool {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var getAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &getAddress, 0, nil, &size, &device) == noErr else {
        return false
    }
    var muted = UInt32(0)
    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted) == noErr else {
        return false
    }
    return muted != 0
}

func setOutputMuted(_ mute: Bool) {
    if outputIsMuted() == mute { return }
    if mute, userWasMuted == nil {
        userWasMuted = outputIsMuted()
    }
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var getAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &getAddress, 0, nil, &size, &device) == noErr else {
        return
    }
    var value: UInt32 = mute ? 1 : 0
    var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    _ = AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
}

signal(SIGPIPE, SIG_IGN)
var shouldStop = false
signal(SIGTERM) { _ in shouldStop = true }
signal(SIGINT) { _ in shouldStop = true }

let gear = Channel()
let vendor = Channel()
var status = MultipointStatus()
var lastLost = Date.distantPast
var lastRequest = Date.distantPast
var requestSent: Date?

var openFailures = 0
var wasPlaying = false
var playingSince: Date?
var wasForeground = false
var steppedAside = false

/// Samsung requires one continuous second of sound before it acts.
func sustainedSound(now: Date) -> Bool {
    guard playingSince != nil else { return false }
    return now.timeIntervalSince(playingSince!) >= sustainWindow
}

func restoreGenericMode() {
    if vendor.channel?.isOpen() != true, let device = IOBluetoothDevice(addressString: address) {
        _ = open(device, named: vendorService, vendor)
    }
    if vendor.channel?.isOpen() == true {
        _ = write(vendor, genericVersionFrame)
    }
}

log("watching \(buds.name ?? address)")

while true {
    let audible = audioIsPlaying()

    // Never pull the earbuds to this Mac unless this Mac is actually producing sound.
    if !buds.isConnected() {
        if audible && playingSince.map({ Date().timeIntervalSince($0) >= sustainWindow }) == true {
            log("not connected while playing, asking for the earbuds")
            _ = claim(buds)
        }
        Thread.sleep(forTimeInterval: pollInterval)
        continue
    }

    if gear.channel?.isOpen() != true {
        gear.onFrame = { frame in
            if let parsed = parseStatus(frame) { status = parsed }
        }
        if !open(buds, named: gearService, gear) {
            openFailures += 1
            if openFailures == 1 || openFailures % 15 == 0 {
                log("cannot open the status channel (\(openFailures) attempts). If macOS denied Bluetooth access, allow this app in System Settings, Privacy and Security, Bluetooth.")
            }
            Thread.sleep(forTimeInterval: 2)
            continue
        }
        openFailures = 0
        log("status channel open")
    }

    if !write(gear, standardFrame(0x76)) {
        log("status channel stalled, reopening")
        gear.channel?.close()
        gear.channel = nil
        Thread.sleep(forTimeInterval: 1)
        continue
    }
    Thread.sleep(forTimeInterval: 0.6)

    let playing = audioIsPlaying()
    let now = Date()

    if playing && playingSince == nil { playingSince = now }
    if !playing { playingSince = nil }

    let owns = defaultOutputName().lowercased().contains("buds")

    if owns {
        if requestSent != nil { log("we hold the earbuds") }
        requestSent = nil
        steppedAside = false
        setOutputMuted(false)
    } else if playing && buds.isConnected() && !status.otherDeviceOnCall { 
        // We have the earbuds back but macOS is still sending audio elsewhere.
        if makeDefaultOutput(matching: "buds") {
            log("made the earbuds the default output")
        }
    }
    // Samsung only arms the anti-fight clock when it had foreground before.
    if wasForeground && !owns && playing {
        lastLost = now
    }

    if sustainedSound(now: now) && !owns {
        // Samsung mutes while it waits, so the wait is silent rather than doubled.
        setOutputMuted(true)
        if status.otherDeviceOnCall {
            if !steppedAside {
                steppedAside = true
                log("other device is on a call, standing down")
            }
        } else if requestSent == nil,
                  now.timeIntervalSince(lastLost) >= antiFightWindow,
                  now.timeIntervalSince(lastRequest) >= requestSpacing {
            if claim(buds) {
                log("asked for the earbuds")
                requestSent = now
                lastRequest = now
            }
        }
    }

    if let sent = requestSent, now.timeIntervalSince(sent) >= requestTimeout {
        log("no answer after \(Int(requestTimeout))s, giving up")
        requestSent = nil
        lastRequest = now
    }

    wasPlaying = playing
    wasForeground = owns

    if shouldStop {
        log("stopping, sending generic metadata so the earbuds leave auto-switch mode")
        if buds.isConnected(), vendor.channel?.isOpen() != true {
            _ = open(buds, named: vendorService, vendor)
        }
        if vendor.channel?.isOpen() == true {
            _ = write(vendor, genericVersionFrame)
        }
        setOutputMuted(false)
        exit(0)
    }

    Thread.sleep(forTimeInterval: pollInterval)
}
