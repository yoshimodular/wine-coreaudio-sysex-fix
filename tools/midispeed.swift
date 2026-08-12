// midispeed - reads and sets kMIDIPropertyMaxSysExSpeed on a CoreMIDI destination.
//
// CoreMIDI uses that property to pace SysEx delivery. The standard MIDI 1.0
// value over DIN is 3125 bytes/s.
//
// CONCLUSION AFTER TESTING IT: it does not fix the dumps. Network ports do not
// even declare it, and even when it is set, **only MIDISendSysex honours it,
// not MIDISend** -- and MIDISend is what Wine and most applications use. The
// program is kept because the measurement is useful to find out which
// interfaces declare their speed.
//
// Build:  swiftc -O midispeed.swift -o midispeed

import Foundation
import CoreMIDI

func name(_ ep: MIDIEndpointRef) -> String {
    var cf: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf)
    return cf?.takeRetainedValue() as String? ?? "?"
}

func speed(_ obj: MIDIObjectRef) -> Int32? {
    var v: Int32 = 0
    return MIDIObjectGetIntegerProperty(obj, kMIDIPropertyMaxSysExSpeed, &v) == noErr ? v : nil
}

var target: String? = nil
var newValue: Int32? = nil

var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "-p", "--port": target = it.next()
    case "-s", "--set":  newValue = Int32(it.next() ?? "")
    case "-h", "--help":
        print("""
        usage: midispeed                       list the destinations and their speed
               midispeed -p "My Port"          show only that one
               midispeed -p "My Port" -s 3125  set it

        3125 B/s is the real speed of MIDI over DIN (31250 baud).
        """)
        exit(0)
    default: break
    }
}

for i in 0..<MIDIGetNumberOfDestinations() {
    let ep = MIDIGetDestination(i)
    let n = name(ep)
    if let t = target, n != t { continue }

    var entity = MIDIEntityRef()
    MIDIEndpointGetEntity(ep, &entity)
    var device = MIDIDeviceRef()
    if entity != 0 { MIDIEntityGetDevice(entity, &device) }

    print(String(format: "%3d  %-28@ endpoint=%@ entity=%@ device=%@", i, n as NSString,
                 speed(ep).map(String.init) as NSString? ?? "-",
                 (entity != 0 ? speed(entity) : nil).map(String.init) as NSString? ?? "-",
                 (device != 0 ? speed(device) : nil).map(String.init) as NSString? ?? "-"))

    if let v = newValue {
        for (obj, label) in [(ep, "endpoint"), (entity, "entity"), (device, "device")]
            where obj != 0 {
            let st = MIDIObjectSetIntegerProperty(obj, kMIDIPropertyMaxSysExSpeed, v)
            print("     \(label): \(st == noErr ? "set to \(v)" : "could not (\(st))")")
        }
        print("     now endpoint=\(speed(ep).map(String.init) ?? "-")")
    }
}
