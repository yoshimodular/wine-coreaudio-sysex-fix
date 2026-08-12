// midislow - virtual MIDI port that forwards at real cable speed.
//
// Creates a destination (default name "MIDI Slow"). Whatever is sent to it goes
// out to the real port limited to ~2500 B/s, below the 3125 B/s of MIDI over
// DIN. Short messages (notes, controllers) pass through whole and immediately;
// only long dumps are slowed down.
//
// A WARNING ABOUT ITS ACTUAL USEFULNESS: it does not fix the dumps of an
// application running under Wine, because its input is a virtual destination
// and suffers the same CoreMIDI 12001-byte ceiling: it would receive the
// message already truncated. That is what the winmm proxy is for. It is still
// useful for native macOS applications that already chunk their sends and only
// need to be paced.
//
// A detail that took a while to find: long SysEx messages are sent in 256-byte
// blocks with a pause. With small fragments (a dozen bytes) CoreMIDI mangles
// the message from the first block onwards; with 256 it arrives identical.
//
// Build:  swiftc -O midislow.swift -o midislow

import Foundation
import CoreMIDI

func fail(_ m: String) -> Never {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1)
}

func endpoints(_ dest: Bool) -> [(String, MIDIEndpointRef)] {
    let n = dest ? MIDIGetNumberOfDestinations() : MIDIGetNumberOfSources()
    return (0..<n).map { i in
        let ep = dest ? MIDIGetDestination(i) : MIDIGetSource(i)
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf)
        return (cf?.takeRetainedValue() as String? ?? "?", ep)
    }
}

var target = ""
var virtualName = "MIDI Slow"
var rate = 2500.0
var chunk = 256
var verbose = true

var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "-t", "--target": target = it.next() ?? target
    case "-n", "--name":   virtualName = it.next() ?? virtualName
    case "-r", "--rate":   rate = Double(it.next() ?? "") ?? rate
    case "-b", "--chunk":  chunk = Int(it.next() ?? "") ?? chunk
    case "-q", "--quiet":  verbose = false
    case "-h", "--help":
        print("""
        usage: midislow -t "Real Port" [options]
          -t, --target <port>   real destination   (required)
          -n, --name   <name>   virtual port name  (default "MIDI Slow")
          -r, --rate   <B/s>    maximum throughput (default 2500; DIN gives 3125)
          -b, --chunk  <bytes>  block size         (default 256, do not lower)
          -q, --quiet           no progress messages
        """)
        exit(0)
    default: break
    }
}

if target.isEmpty {
    FileHandle.standardError.write("No target given (-t). Available destinations:\n".data(using: .utf8)!)
    for (n, _) in endpoints(true) { FileHandle.standardError.write("  \(n)\n".data(using: .utf8)!) }
    exit(1)
}
// Unvalidated: -b 0 is an infinite loop at 99% CPU, -b -1 aborts the process
// when the range is built, and -r 0 leaves the pause at infinity.
// The minimum is 64 because with fragments of a dozen bytes CoreMIDI mangles
// the message (see docs/coremidi-12001.md); 256 is the tested size. The
// maximum is NOT Wine's 498 limit, which is irrelevant here: this talks to
// CoreMIDI directly and 600-byte blocks are verified to work.
if chunk < 64 || chunk > 32768 {
    FileHandle.standardError.write("--chunk out of range (64-32768; 256 is the tested value)\n".data(using: .utf8)!); exit(1)
}
if rate < 1 || rate > 1_000_000 {
    FileHandle.standardError.write("--rate out of range (1-1000000 B/s)\n".data(using: .utf8)!); exit(1)
}

guard let dst = endpoints(true).first(where: { $0.0 == target })?.1 else {
    FileHandle.standardError.write("No such destination \"\(target)\".\n".data(using: .utf8)!)
    for (n, _) in endpoints(true) { FileHandle.standardError.write("  \(n)\n".data(using: .utf8)!) }
    exit(1)
}

var client = MIDIClientRef()
guard MIDIClientCreate("midislow" as CFString, nil, nil, &client) == noErr else { fail("MIDIClientCreate failed") }
var outPort = MIDIPortRef()
guard MIDIOutputPortCreate(client, "out" as CFString, &outPort) == noErr else { fail("MIDIOutputPortCreate failed") }

func emit(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    let size = bytes.count + 128
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size,
                alignment: MemoryLayout<MIDIPacketList>.alignment)
    let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
    var cur = MIDIPacketListInit(list)
    bytes.withUnsafeBufferPointer { buf in
        cur = MIDIPacketListAdd(list, size, cur, 0, bytes.count, buf.baseAddress!)
    }
    MIDISend(outPort, dst, list)
    raw.deallocate()
}

let lock = NSCondition()
var queue: [[UInt8]] = []
var queuedBytes = 0

func enqueue(_ m: [UInt8]) {
    lock.lock(); queue.append(m); queuedBytes += m.count; lock.signal(); lock.unlock()
}

var sysex: [UInt8] = []
var inSysex = false
var running: UInt8 = 0
var pending: [UInt8] = []
var need = 0

func dataBytes(for status: UInt8) -> Int {
    switch status & 0xF0 {
    case 0xC0, 0xD0: return 1
    case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 2
    default:
        switch status { case 0xF1, 0xF3: return 1; case 0xF2: return 2; default: return 0 }
    }
}

func feed(_ b: UInt8) {
    if b >= 0xF8 { emit([b]); return }        // real time: no queue, no wait
    if inSysex {
        if b == 0xF7 { sysex.append(b); enqueue(sysex); sysex = []; inSysex = false; return }
        if b & 0x80 == 0 { sysex.append(b); return }
        enqueue(sysex); sysex = []; inSysex = false   // unexpected status: abort
    }
    if b == 0xF0 { inSysex = true; sysex = [b]; return }
    if b & 0x80 != 0 {
        running = b; need = dataBytes(for: b); pending = [b]
        if need == 0 { enqueue(pending); pending = [] }
    } else if !pending.isEmpty || running != 0 {
        if pending.isEmpty { pending = [running] }
        pending.append(b)
        if pending.count == need + 1 { enqueue(pending); pending = [] }
    }
}

var totalSent = 0

let sender = Thread {
    while true {
        lock.lock()
        while queue.isEmpty { lock.wait() }
        let msg = queue.removeFirst()
        queuedBytes -= msg.count
        lock.unlock()

        if msg.first == 0xF0 && msg.count > chunk {
            let pause = Double(chunk) / rate
            var off = 0
            while off < msg.count {
                let end = min(off + chunk, msg.count)
                emit(Array(msg[off..<end]))
                totalSent += end - off
                off = end
                if off < msg.count { Thread.sleep(forTimeInterval: pause) }
            }
            if verbose { print("  sysex of \(msg.count) bytes delivered"); fflush(stdout) }
        } else {
            emit(msg); totalSent += msg.count
        }
    }
}
sender.stackSize = 512 * 1024
sender.start()

// Walk the list with pointers into the original: copying a MIDIPacket by value
// truncates it to the 256 bytes of the `data` tuple and you read garbage.
let pktOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!

var virt = MIDIEndpointRef()
guard MIDIDestinationCreateWithBlock(client, virtualName as CFString, &virt, { pl, _ in
    var pkt = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(pl))
        .advanced(by: pktOffset).assumingMemoryBound(to: MIDIPacket.self)
    for _ in 0..<pl.pointee.numPackets {
        let n = Int(pkt.pointee.length)
        let d = UnsafeRawPointer(pkt).advanced(by: dataOffset)
            .assumingMemoryBound(to: UInt8.self)
        for k in 0..<n { feed(d[k]) }
        pkt = MIDIPacketNext(pkt)
    }
}) == noErr else { fail("cannot create the virtual port \"\(virtualName)\"") }

print("""
Port "\(virtualName)" created -> forwards to "\(target)"
throughput \(Int(rate)) B/s (the MIDI cable gives 3125), blocks of \(chunk) bytes
Ctrl-C to stop.
""")
fflush(stdout)
CFRunLoopRun()
