// sysexsend - sends a .syx file to a CoreMIDI port at a controlled rate.
//
// MIDI over DIN runs at 31250 baud = ~3125 bytes/s. A bank dump is 34 KB, i.e.
// ~11 s of cable time. The Mac pushes it out in milliseconds and overruns
// whatever is at the other end. Here it is chunked and paced so as not to
// exceed that speed.
//
// There is also a hard ceiling: CoreMIDI truncates at 12001 bytes any SysEx
// handed to it in a single MIDISend call, without reporting an error. That is
// why it is always sent in chunks.
//
// Build:  swiftc -O sysexsend.swift -o sysexsend

import Foundation
import CoreMIDI

func fail(_ m: String) -> Never {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1)
}
func req<T>(_ v: T?, _ m: String) -> T { guard let v = v else { fail(m) }; return v }

func destinations() -> [(Int, String, MIDIEndpointRef)] {
    (0..<MIDIGetNumberOfDestinations()).map { i in
        let ep = MIDIGetDestination(i)
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf)
        return (i, cf?.takeRetainedValue() as String? ?? "?", ep)
    }
}

// ---- arguments ---------------------------------------------------------
var files: [String] = []
var portName = ""
var chunk = 256          // bytes per block
var delay = 100          // ms between blocks -> 2560 B/s, below the DIN rate
var gap = 500            // ms between distinct SysEx messages
var listOnly = false
var dryRun = false

var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--port", "-p":  portName = req(it.next(), "missing port name")
    case "--chunk", "-b": chunk = req(Int(it.next() ?? ""), "--chunk needs a number")
    case "--delay", "-d": delay = req(Int(it.next() ?? ""), "--delay needs a number")
    case "--gap", "-g":   gap = req(Int(it.next() ?? ""), "--gap needs a number")
    case "--list", "-l":  listOnly = true
    case "--dry-run":     dryRun = true
    case "-h", "--help":
        print("""
        usage: sysexsend <file.syx> [...] [options]

          -p, --port <name>    destination port (required unless --dry-run)
          -b, --chunk <n>      bytes per block          (default 256)
          -d, --delay <ms>     pause between blocks     (default 100 -> ~2.5 KB/s)
          -g, --gap <ms>       pause between SysEx messages (default 500)
          -l, --list           list the MIDI output ports and exit
              --dry-run        analyse the file without sending anything

        The resulting throughput is printed before sending. Keep the rate below
        3.1 KB/s, which is the physical limit of the MIDI cable.
        """)
        exit(0)
    default:
        if a.hasPrefix("-") { fail("unknown option: \(a)") }
        files.append(a)
    }
}

if listOnly {
    for (i, n, _) in destinations() { print(String(format: "%3d  %@", i, n)) }
    exit(0)
}
if files.isEmpty { fail("Missing the .syx file. Try --help.") }
if chunk < 1 || chunk > 65000 { fail("--chunk out of range (1-65000)") }
// usleep(UInt32(negative)) does not fail: it traps and aborts the process
if delay < 0 || delay > 60000 { fail("--delay out of range (0-60000 ms)") }
if gap   < 0 || gap   > 60000 { fail("--gap out of range (0-60000 ms)") }

// ---- split into SysEx messages -----------------------------------------
struct Msg { let bytes: [UInt8]; let label: String }

func split(_ data: [UInt8]) -> [Msg] {
    var out: [Msg] = []
    var i = 0
    while i < data.count {
        guard data[i] == 0xF0 else { i += 1; continue }
        var j = i + 1
        while j < data.count && data[j] != 0xF7 { j += 1 }
        if j >= data.count { break }
        let m = Array(data[i...j])
        let label = String(format: "F0 %02X", m.count > 1 ? m[1] : 0)
        out.append(Msg(bytes: m, label: label))
        i = j + 1
    }
    return out
}

var msgs: [Msg] = []
for f in files {
    guard let d = FileManager.default.contents(atPath: f) else { fail("cannot read \(f)") }
    let m = split([UInt8](d))
    if m.isEmpty { fail("\(f): contains no SysEx at all (F0 ... F7)") }
    msgs += m
}

let total = msgs.reduce(0) { $0 + $1.bytes.count }
// with delay 0 the division yields infinity and prints "throughput inf B/s"
let rate = delay > 0 ? Double(chunk) / (Double(delay) / 1000.0) : Double.infinity
let secs = Double(total) / rate + Double(msgs.count - 1) * Double(gap) / 1000.0

print("\(msgs.count) message(s), \(total) bytes")
for m in msgs { print(String(format: "  %-22@ %6d bytes", m.label as NSString, m.bytes.count)) }
if rate.isInfinite {
    print("throughput: no pause between blocks (as fast as possible)")
} else {
    print(String(format: "throughput %.0f B/s (DIN limit 3125) -> %.0f s", rate, secs))
}
if rate > 3125 { print("  WARNING: above MIDI cable speed, the receiver may overrun") }
if dryRun { exit(0) }

// ---- sending -----------------------------------------------------------
if portName.isEmpty {
    FileHandle.standardError.write("No port given (-p). Available destinations:\n".data(using: .utf8)!)
    for (i, n, _) in destinations() {
        FileHandle.standardError.write(String(format: "%3d  %@\n", i, n).data(using: .utf8)!)
    }
    exit(1)
}
guard let dst = destinations().first(where: { $0.1 == portName })?.2 else {
    FileHandle.standardError.write("No such port \"\(portName)\". Available:\n".data(using: .utf8)!)
    for (i, n, _) in destinations() {
        FileHandle.standardError.write(String(format: "%3d  %@\n", i, n).data(using: .utf8)!)
    }
    exit(1)
}

var client = MIDIClientRef()
guard MIDIClientCreate("sysexsend" as CFString, nil, nil, &client) == noErr else { fail("MIDIClientCreate failed") }
var port = MIDIPortRef()
guard MIDIOutputPortCreate(client, "out" as CFString, &port) == noErr else { fail("MIDIOutputPortCreate failed") }

var sent = 0
for (n, m) in msgs.enumerated() {
    print("sending \(m.label)...", terminator: "")
    fflush(stdout)
    var off = 0
    while off < m.bytes.count {
        let end = min(off + chunk, m.bytes.count)
        let slice = Array(m.bytes[off..<end])

        // The MIDIPacketList must live in purpose-allocated memory: the stack
        // struct only holds 256 bytes of data and would overflow silently.
        let listSize = slice.count + 128
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize,
                    alignment: MemoryLayout<MIDIPacketList>.alignment)
        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var cur = MIDIPacketListInit(list)
        slice.withUnsafeBufferPointer { buf in
            cur = MIDIPacketListAdd(list, listSize, cur, 0, slice.count, buf.baseAddress!)
        }
        let st = MIDISend(port, dst, list)
        raw.deallocate()
        if st != noErr { fail("\nMIDISend failed with \(st)") }

        sent += slice.count
        off = end
        if off < m.bytes.count { usleep(UInt32(delay) * 1000) }
    }
    print(" \(m.bytes.count) bytes")
    if n < msgs.count - 1 { usleep(UInt32(gap) * 1000) }
}
print("Done: \(sent) bytes to \"\(portName)\"")
