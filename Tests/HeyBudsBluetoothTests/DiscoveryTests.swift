import Testing
import HeyBudsBluetooth

/// The three-state identity check that decides the automatic device list.
/// Values are the ones macOS reports for real hardware; the iPhone case guards
/// against reading the Audio service bit instead of the major device class.
@Test func discoveryAdmissionUsesClassOfDeviceThenAudioSink() {
    // Audio/Video major class is enough, even when the SDP cache is empty.
    for cod:UInt32 in [0x240404,0x240418,0x240410] {
        #expect(Discovery.admits(classOfDevice:cod,hasAudioSink:false), "0x\(String(cod,radix:16))")
        #expect(Discovery.admits(classOfDevice:cod,hasAudioSink:true), "0x\(String(cod,radix:16))")
    }
    // A known non-audio class is never rescued by an audio sink record.
    let nonAudio:[(UInt32,String)] = [
        (0x000580,"mouse"),(0x000540,"keyboard"),(0x5A020C,"Android phone"),
        (0x7A020C,"iPhone: audio service bit is set, major class is still Phone"),
        (0x01010C,"laptop"),(0x000704,"watch"),(0x000300,"LAN"),(0x000680,"printer"),
    ]
    for (cod,label) in nonAudio {
        #expect(!Discovery.admits(classOfDevice:cod,hasAudioSink:true), "0x\(String(cod,radix:16)) \(label)")
    }
    // Unknown and uncategorized classes fall back to the audio sink evidence.
    for cod:UInt32 in [0x000000,0x001F00] {
        #expect(Discovery.admits(classOfDevice:cod,hasAudioSink:true), "0x\(String(cod,radix:16)) with sink")
        #expect(!Discovery.admits(classOfDevice:cod,hasAudioSink:false), "0x\(String(cod,radix:16)) without sink")
    }
}
