// midirecv - listens to a CoreMIDI source and describes the SysEx that arrives.
//
// It hooks onto an already existing source, so it can spy on a dump while the
// editor receives it at the same time: CoreMIDI allows several clients on the
// same source.
//
// Useful for getting ground truth about a dump: how many bytes were actually
// transmitted, whether the message closed with F7, and how much of it is real
// data once the 7->8 bit packing used by most manufacturers is undone.
//
// Build:  swiftc -O midirecv.swift -o midirecv

import Foundation
import CoreMIDI

func sources() -> [(Int, String, MIDIEndpointRef)] {
    (0..<MIDIGetNumberOfSources()).map { i in
        let ep = MIDIGetSource(i)
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf)
        return (i, cf?.takeRetainedValue() as String? ?? "?", ep)
    }
}

var portName = ""
var outPath = "capture.syx"
var quiet = 2.0          // seconds of silence before the dump is considered over

var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "-p", "--port": portName = it.next() ?? portName
    case "-o", "--out":  outPath = it.next() ?? outPath
    case "-l", "--list":
        for (i, n, _) in sources() { print(String(format: "%3d  %@", i, n)) }
        exit(0)
    case "-h", "--help":
        print("""
        usage: midirecv -p "Source Name" [-o capture.syx]

        Listens to the given source and saves every SysEx that arrives.
        Prints the transmitted size and the real data size.
        Ctrl-C to finish.
        """)
        exit(0)
    default: break
    }
}

if portName.isEmpty {
    FileHandle.standardError.write("No source given (-p). Available sources:\n".data(using: .utf8)!)
    for (i, n, _) in sources() {
        FileHandle.standardError.write(String(format: "%3d  %@\n", i, n).data(using: .utf8)!)
    }
    exit(1)
}
guard let src = sources().first(where: { $0.1 == portName })?.2 else {
    FileHandle.standardError.write("No such source \"\(portName)\". Available:\n".data(using: .utf8)!)
    for (i, n, _) in sources() {
        FileHandle.standardError.write(String(format: "%3d  %@\n", i, n).data(using: .utf8)!)
    }
    exit(1)
}

let pktOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!

var buf = Data()
var cur = Data()
var inSysex = false
let lock = NSLock()
var lastByte = Date()
var writePending = false

func describe(_ m: Data) {
    let b = [UInt8](m)
    guard b.count > 5 else { return }
    let payload = b.count - 6
    // Most manufacturers pack 8-bit data into 7-bit bytes, 7 data bytes per
    // group of 8 transmitted; this is the resulting real payload size.
    let raw = payload - (payload + 7) / 8
    print(String(format: "  manufacturer 0x%02X  %d B transmitted -> ~%d B of data",
                 b[1], payload, raw))
}

var client = MIDIClientRef()
MIDIClientCreate("midirecv" as CFString, nil, nil, &client)
var port = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { pl, _ in
    lock.lock()
    var pkt = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(pl))
        .advanced(by: pktOffset).assumingMemoryBound(to: MIDIPacket.self)
    for _ in 0..<pl.pointee.numPackets {
        let n = Int(pkt.pointee.length)
        let d = UnsafeRawPointer(pkt).advanced(by: dataOffset)
            .assumingMemoryBound(to: UInt8.self)
        for k in 0..<n {
            let byte = d[k]
            if byte == 0xF0 { inSysex = true; cur = Data([byte]) }
            else if inSysex {
                cur.append(byte)
                if byte == 0xF7 {
                    inSysex = false
                    buf.append(cur)
                    print("complete sysex: \(cur.count) bytes")
                    describe(cur)
                    writePending = true   // written outside the callback
                }
            }
        }
        pkt = MIDIPacketNext(pkt)
    }
    lastByte = Date()
    lock.unlock()
}
MIDIPortConnectSource(port, src, nil)

print("listening to \"\(portName)\" -> \(outPath)")
print("Start the dump now. Ctrl-C to finish.\n")

var announced = true
while true {
    Thread.sleep(forTimeInterval: 0.25)
    lock.lock()
    // Writing the whole file inside the CoreMIDI callback is O(n^2) and blocks
    // a real-time thread: it is done here instead.
    if writePending {
        let copy = buf
        writePending = false
        lock.unlock()
        try? copy.write(to: URL(fileURLWithPath: outPath))
        lock.lock()
    }
    let idle = Date().timeIntervalSince(lastByte)
    if !buf.isEmpty && !inSysex && idle > quiet && !announced {
        announced = true
        print("\n--- silence, dump finished: \(buf.count) bytes -> \(outPath)")
    }
    if inSysex || idle < quiet { announced = false }
    lock.unlock()
}
