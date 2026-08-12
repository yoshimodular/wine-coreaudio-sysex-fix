// midisniff - captures MIDI and checks SysEx integrity.
//
//   midisniff -v "NAME"   creates a virtual destination and captures what is sent to it
//   midisniff -s "NAME"   attaches to an already existing source
//
// Two CoreMIDI traps that falsified the first measurements, and which this
// program avoids:
//
//  1. Copying a MIDIPacket by value (`var p = pl.pointee.packet`) TRUNCATES it
//     to the 256 bytes of the `data` tuple, and reading past that returns stack
//     garbage. On top of that, MIDIPacketNext on the copy computes the wrong
//     next address. The list must be walked with pointers into the original
//     MIDIPacketList.
//
//  2. The callback has to be extremely fast. If it writes to disk, CoreMIDI
//     drops whatever arrives meanwhile and you end up measuring the slowness of
//     your own instrument. Here it only accumulates in memory; a separate
//     thread writes the report.
//
// Build:  swiftc -O midisniff.swift -o midisniff

import Foundation
import CoreMIDI

func fail(_ m: String) -> Never {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1)
}

let pktOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!

func bytes(of pl: UnsafePointer<MIDIPacketList>) -> [UInt8] {
    var out: [UInt8] = []
    var pkt = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(pl))
        .advanced(by: pktOffset).assumingMemoryBound(to: MIDIPacket.self)
    for _ in 0..<pl.pointee.numPackets {
        let n = Int(pkt.pointee.length)
        let d = UnsafeRawPointer(pkt).advanced(by: dataOffset)
            .assumingMemoryBound(to: UInt8.self)
        out.append(contentsOf: UnsafeBufferPointer(start: d, count: n))
        pkt = MIDIPacketNext(pkt)
    }
    return out
}

var virtualName: String? = nil
var sourceName: String? = nil
var outPath = "sniff.bin"

var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "-v", "--virtual": virtualName = it.next()
    case "-s", "--source":  sourceName = it.next()
    case "-o", "--out":     outPath = it.next() ?? outPath
    case "-h", "--help":
        print("""
        usage: midisniff [-v NAME | -s NAME] [-o file]

          -v, --virtual <n>  create a virtual destination with that name
          -s, --source  <n>  attach to an existing source
          -o, --out <file>   where to dump what is captured (def. sniff.bin)

        Also writes <file>.txt with the summary: bytes, packets, complete and
        truncated SysEx, and the largest. Ctrl-C to stop.
        """)
        exit(0)
    default: break
    }
}
if virtualName == nil && sourceName == nil { virtualName = "SNIFF" }

var buf = Data()
var packets = 0
let lock = NSLock()

func report(_ buf: Data, _ packets: Int) {
    var complete = 0, truncated = 0, maxLen = 0, cur = 0, open = false
    for b in buf {
        if b == 0xF0 {
            if open { truncated += 1 }
            open = true; cur = 1
        } else if b == 0xF7 {
            if open { complete += 1; cur += 1; maxLen = max(maxLen, cur); open = false }
        } else if open { cur += 1 }
    }
    let s = """
    bytes            : \(buf.count)
    packets          : \(packets)
    complete sysex   : \(complete)
    truncated sysex  : \(truncated + (open ? 1 : 0))
    largest sysex    : \(maxLen)

    """
    try? s.write(toFile: outPath + ".txt", atomically: true, encoding: .utf8)
    try? buf.write(to: URL(fileURLWithPath: outPath))
}

var client = MIDIClientRef()
MIDIClientCreate("midisniff" as CFString, nil, nil, &client)

let handler: MIDIReadBlock = { pl, _ in
    let b = bytes(of: pl)
    lock.lock()
    buf.append(contentsOf: b)
    packets += Int(pl.pointee.numPackets)
    lock.unlock()
}

// Copy under the lock and write outside it: holding it across two writes to
// disk blocks the CoreMIDI callback every half second, which is exactly what
// note 2 at the top of this file says must be avoided.
let writer = Thread {
    while true {
        Thread.sleep(forTimeInterval: 0.5)
        lock.lock()
        let copy = buf
        let np = packets
        lock.unlock()
        report(copy, np)
    }
}
writer.stackSize = 512 * 1024
writer.start()

if let v = virtualName {
    var ep = MIDIEndpointRef()
    guard MIDIDestinationCreateWithBlock(client, v as CFString, &ep, handler) == noErr else {
        fail("cannot create the virtual destination \"\(v)\"")
    }
    print("virtual destination \"\(v)\" created -> \(outPath)")
} else if let s = sourceName {
    var found = MIDIEndpointRef()
    for i in 0..<MIDIGetNumberOfSources() {
        let ep = MIDIGetSource(i)
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf)
        if (cf?.takeRetainedValue() as String?) == s { found = ep }
    }
    if found == 0 { fail("no such source \"\(s)\"") }
    var port = MIDIPortRef()
    MIDIInputPortCreateWithBlock(client, "in" as CFString, &port, handler)
    MIDIPortConnectSource(port, found, nil)
    print("listening to source \"\(s)\" -> \(outPath)")
}
fflush(stdout)
CFRunLoopRun()
