import Foundation
import Testing
@testable import HeyBudsBluetooth
import HeyBudsProtocol

@MainActor private final class BrandRadio:EarbudTransport {
    var onEvent:((TransportEvent)->Void)?
    let label="Mock brand transport"
    let family:EarbudFamily
    let xiaomiMMA:Bool
    var decoder:BrandFrameCodec
    var active=false
    var packets:[Data]=[]
    var commands:[BrandFrame]=[]
    var response:((BrandFrame)->BrandFrame?)?
    var ignore=false
    init(_ family:EarbudFamily,version:UInt8=4,xiaomiMMA:Bool=false) {
        self.family=family;self.xiaomiMMA=xiaomiMMA
        decoder=BrandFrameCodec(family:family,gaiaVersion:version,xiaomiMMA:xiaomiMMA)
    }
    func open() async throws { active=true }
    func close() { active=false }
    func send(_ data:Data) async throws {
        guard active else { throw ProtocolError.disconnected }
        packets.append(data)
        if ignore { return }
        // Edifier request headers differ from responses; use its documented request fields.
        let frames:[BrandFrame]
        if family == .edifier {
            let b=Array(data);frames=[BrandFrame(UInt16(b[2]),Array(b[3..<b.count-2]))]
        } else { frames=decoder.feed(data) }
        for frame in frames {
            commands.append(frame)
            let answer:BrandFrame?
            if let response { answer=response(frame) }
            else {
                switch (family,frame.command) {
                case (.vivo,0x0300):answer=BrandFrame(0x8300,[0])
                case (.vivo,0x0207):answer=BrandFrame(0x8207,[0,40,0,255,1])
                case (.vivo,0x0230):answer=BrandFrame(0x8230,[0,1,4])
                case (.vivo,0x0203):answer=BrandFrame(0x8203,[0,1])
                case (.vivo,0x0218):answer=BrandFrame(0x8218,[0,0])
                case (.vivo,0x0239):answer=BrandFrame(0x8239,[0,0,1])
                case (.vivo,0x020D):answer=BrandFrame(0x820D,[0,4])
                case (.vivo,0x0251):answer=BrandFrame(0x8251,[0,0])
                case (.vivo,0x0252):answer=BrandFrame(0x8252,[0,1])
                case (.vivo,0x021C):answer=BrandFrame(0x821C,[0,49,46,50])
                case (.vivo,0x0249):answer=BrandFrame(0x8249,[0,0])
                case (.huawei,0x0108):answer=BrandFrame(0x0108,[2,3,40,0,255])
                case (.huawei,0x2B2A):answer=BrandFrame(0x2B2A,[1,2,2,1])
                case (.huawei,0x2B4A):answer=BrandFrame(0x2B4A,[1,1,1,2,1,5])
                case (.huawei,0x2B11),(.huawei,0x2B2F):answer=BrandFrame(frame.command,[1,1,1])
                case (.huawei,0x2B6C):answer=BrandFrame(0x2B6C,[2,1,0])
                case (.huawei,0x2B31):answer=BrandFrame(0x2B31,[2,1,0])
                case (.edifier,0xD0):answer=BrandFrame(0xD0,[50])
                case (.edifier,0xCC):answer=BrandFrame(0xCC,[1])
                case (.xiaomi,2) where frame.sequence == 0x50:answer=BrandFrame(2,[1]+(try XiaomiAuth.response(Array(frame.payload.dropFirst()))),sequence:0x50)
                case (.xiaomi,2):answer=BrandFrame(2,xiaomiMMA ? [4,7,50,60,70] : [2,2,4,7,50,60,70],sequence:frame.sequence)
                case (.xiaomi,0xF3) where frame.payload == [0x00,0x0B]:answer=BrandFrame(0xF3,[4,0,0x0B,0,0],sequence:frame.sequence)
                default:answer=nil
                }
            }
            if var answer {
                // Real MMA replies carry status before the sequence. The mock starts
                // with request-shaped frames, so convert them for the MMA variant.
                if xiaomiMMA,answer.kind & 0x80 != 0 { answer=BrandFrame(answer.command,answer.payload,sequence:answer.sequence,kind:4) }
                try emit(answer)
            }
        }
    }
    func emit(_ frame:BrandFrame) throws {
        let data:Data
        if family == .edifier {
            var b:[UInt8]=[0xBB,UInt8(frame.payload.count+1),UInt8(frame.command)]+frame.payload
            let sum=b.reduce(UInt16(8217)) { $0 &+ UInt16($1) };b += [UInt8(sum>>8),UInt8(truncatingIfNeeded:sum)];data=Data(b)
        } else { data=try decoder.encode(frame) }
        onEvent?(.data(data))
    }
}
@Test @MainActor func vivoSessionUsesItsOwnHandshakeAndNeverOppoPackets() async throws {
    let t=BrandRadio(.vivo,version:3),c=try ModelCatalog()
    let s=DeviceSession(transport:t,name:"vivo TWS 3e",catalog:c)
    defer { s.close() };try await s.open()
    #expect(s.ready && s.model?.family == .vivo)
    #expect(s.state.batteries[.right]?.percent == 0 && s.state.batteries[.enclosure] == nil)
    #expect(t.commands.first?.command == 0x0300)
    #expect(t.commands.map(\.command) == [0x0300,0x0202,0x0203,0x0204,0x0205,0x0206,0x0207])
    #expect(t.packets.allSatisfy { $0.first == 0xFF })
    #expect(s.canWrite(Command.find))
    #expect(!s.canWrite(Command.setBass))
    #expect(!s.canQuery(Command.priority))
    s.close();#expect(!s.ready && s.state.batteries.isEmpty)
}
@Test @MainActor func huaweiReadbackSelectsItsModelSpecificNoiseLevel() async throws {
    let t=BrandRadio(.huawei),s=DeviceSession(transport:t,name:"FreeBuds Pro 3",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.refresh()
    #expect(s.state.noise == .deep)
    #expect(try await s.setNoise(.deep) == .confirmed)
    let packet=try #require(t.commands.last(where:{$0.command == 0x2B04}))
    #expect(packet.payload == [1,2,1,2])
    #expect(t.packets.allSatisfy { $0.first == 0x5A })
}
@Test @MainActor func malformedReadbackCannotConfirmEvenAnUnchangedRequestedValue() async throws {
    let t=BrandRadio(.edifier),s=DeviceSession(transport:t,name:"W820NB Plus",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.refresh()
    #expect(s.state.noise == .off)
    t.response={ frame in frame.command == 0xCC ? BrandFrame(0xCC,[]) : nil }
    do { _ = try await s.setNoise(.off);Issue.record("Malformed readback confirmed stale state") }
    catch { #expect(error as? ProtocolError == .invalidPayload) }
    #expect(s.state.noise == .off)
}
@Test @MainActor func vivoSetEchoCannotConfirmNoiseWithoutReadback() async throws {
    let t=BrandRadio(.vivo),s=DeviceSession(transport:t,name:"vivo TWS 4",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.refresh()
    t.response={ frame in
        if frame.command == 0x0130 { return BrandFrame(0x8130,frame.payload) }
        if frame.command == 0x0230 { return BrandFrame(0x8230,[0,1,4]) }
        return nil
    }
    let task=Task { try await s.setNoise(.transparency) }
    try await Task.sleep(for:.milliseconds(50))
    #expect(s.state.noise == .off)
    task.cancel()
    do { _ = try await task.value;Issue.record("Cancellation ignored") } catch { #expect(error is CancellationError) }
    #expect(s.state.noise == .off)
}
@Test @MainActor func staleCallbackAndQueuedOperationsCannotRestoreClosedBrandState() async throws {
    let t=BrandRadio(.huawei),s=DeviceSession(transport:t,name:"FreeBuds 6i",catalog:try ModelCatalog())
    try await s.open();let callback=t.onEvent
    s.close();callback?(.data(try BrandFrameCodec(family:.huawei).encode(BrandFrame(0x0108,[2,1,90]))))
    #expect(!s.ready && s.state.batteries.isEmpty)
    #expect(!s.canWrite(Command.setNoise))
}
@Test @MainActor func unsupportedOperationsNeverEmitPacketsInOtherBrands() async throws {
    let t=BrandRadio(.huawei),s=DeviceSession(transport:t,name:"FreeBuds 6i",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();let before=t.packets.count
    do { _ = try await s.setBass(3);Issue.record("OPPO bass sent to Huawei") } catch { #expect(error as? ProtocolError == .unsupported) }
    do { _ = try await s.setGameSound(1);Issue.record("OPPO game sound sent to Huawei") } catch { #expect(error as? ProtocolError == .unsupported) }
    do { _ = try await s.query(Command.battery);Issue.record("Raw OPPO query sent to Huawei") } catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(t.packets.count == before)
}
@Test @MainActor func xiaomiAuthenticationAndBatteryUseSeparateRcspFields() async throws {
    let t=BrandRadio(.xiaomi),s=DeviceSession(transport:t,name:"Redmi Buds 6",catalog:try ModelCatalog())
    defer { s.close() };try await s.open()
    #expect(s.ready && s.state.batteries[.left]?.percent == 50)
    let auth=try #require(t.commands.first(where:{$0.command == 0x51}))
    #expect(auth.kind == 4 && auth.sequence == 0)
    #expect(auth.payload == [3,1])
    #expect(t.packets.allSatisfy { $0.starts(with:[0xFE,0xDC,0xBA]) })
    #expect(!s.canWrite(Command.setNoise) && s.gameFeature == nil)
}
@Test @MainActor func xiaomiNoiseModesUseConfigBAndFreshReadback() async throws {
    let t=BrandRadio(.xiaomi,xiaomiMMA:true)
    var mode:UInt8=0, level:UInt8=0
    t.response={ frame in
        if frame.command == 2, frame.sequence == 0x50 {
            guard let answer=try? XiaomiAuth.response(Array(frame.payload.dropFirst())) else { return nil }
            return BrandFrame(2,[1]+answer,sequence:0x50)
        }
        if frame.command == 2 { return BrandFrame(2,[4,7,50,60,70],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x04] { return BrandFrame(0xF3,[3,0,0x04,1],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x03] { return BrandFrame(0xF3,[3,0,0x03,0],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x09] { return BrandFrame(0xF3,[4,0,0x09,0,0],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x02] { return BrandFrame(0xF3,[0x0B,0x00,0x02,1,3,3,2,2,2,3,6,6],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x0C] { return BrandFrame(0xF3,[3,0,0x0C,0x0C],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x1E] { return BrandFrame(0xF3,[3,0,0x1E,0x18],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x0B] {
            return BrandFrame(0xF3,[4,0,0x0B,mode,level],sequence:frame.sequence)
        }
        if frame.command == 0xF3, frame.payload == [0x00,0x07] {
            return BrandFrame(0xF3,[3,0,0x07,0x0C],sequence:frame.sequence)
        }
        if frame.command == 0xF2, frame.payload.starts(with:[4,0,0x0B]) {
            mode=frame.payload[3]; level=frame.payload[4]
            return BrandFrame(0xF2,[],sequence:frame.sequence)
        }
        return nil
    }
    let s=DeviceSession(transport:t,name:"Xiaomi Buds 4 Pro",catalog:try ModelCatalog())
    defer { s.close() }
    try await s.open()
    #expect(s.state.noise == .off)
    let anc=try await s.setNoise(.anc)
    #expect(anc == .confirmed && s.state.noise == .anc)
    let set=t.commands.first(where:{$0.command == 0xF2})
    #expect(set?.payload == [4,0,0x0B,1,0])
    let deep=try await s.setNoise(.deep)
    #expect(deep == .confirmed && s.state.noise == .deep)
    let transparency=try await s.setNoise(.transparency)
    #expect(transparency == .confirmed && s.state.noise == .transparency)
    let off=try await s.setNoise(.off)
    #expect(off == .confirmed && s.state.noise == .off)
}
@Test @MainActor func xiaomiEqualizerPresetsUseConfig7AndFreshReadback() async throws {
    let t=BrandRadio(.xiaomi,xiaomiMMA:true)
    var eq:UInt8=0x0C
    t.response={ frame in
        if frame.command == 2, frame.sequence == 0x50 {
            guard let answer=try? XiaomiAuth.response(Array(frame.payload.dropFirst())) else { return nil }
            return BrandFrame(2,[1]+answer,sequence:0x50)
        }
        if frame.command == 2 { return BrandFrame(2,[4,7,50,60,70],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x04] { return BrandFrame(0xF3,[3,0,0x04,1],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x03] { return BrandFrame(0xF3,[3,0,0x03,0],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x09] { return BrandFrame(0xF3,[4,0,0x09,0,0],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x02] { return BrandFrame(0xF3,[0x0B,0x00,0x02,1,3,3,2,2,2,3,6,6],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x0C] { return BrandFrame(0xF3,[3,0,0x0C,0x0C],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x1E] { return BrandFrame(0xF3,[3,0,0x1E,0x18],sequence:frame.sequence) }
        if frame.command == 0xF3, frame.payload == [0x00,0x0B] {
            return BrandFrame(0xF3,[4,0,0x0B,0,0],sequence:frame.sequence)
        }
        if frame.command == 0xF3, frame.payload == [0x00,0x07] {
            return BrandFrame(0xF3,[3,0,0x07,eq],sequence:frame.sequence)
        }
        if frame.command == 0xF2, frame.payload.starts(with:[3,0,0x07]) {
            eq=frame.payload[3]
            return BrandFrame(0xF2,[],sequence:frame.sequence)
        }
        return nil
    }
    let s=DeviceSession(transport:t,name:"Xiaomi Buds 4 Pro",catalog:try ModelCatalog())
    defer { s.close() }
    try await s.open()
    #expect(s.state.eq == 0x0C)
    let treble=try await s.setEQ(6)
    #expect(treble == .confirmed && s.state.eq == 6)
    let set=t.commands.first(where:{$0.command == 0xF2})
    #expect(set?.payload == [3,0,0x07,6])
    let restore=try await s.setEQ(0x0C)
    #expect(restore == .confirmed && s.state.eq == 0x0C)
}
@Test @MainActor func xiaomiDualAutoAnswerAndFindUseFreshReadback() async throws {
    let t=BrandRadio(.xiaomi,xiaomiMMA:true)
    var multi=true, auto=false, finding=false
    var groups:[UInt8]=[1,3,3,2,2,2,3,6,6]
    var spatial:UInt8=0x18
    t.response={ frame in
        if frame.command == 2, frame.sequence == 0x50 {
            guard let answer=try? XiaomiAuth.response(Array(frame.payload.dropFirst())) else { return nil }
            return BrandFrame(2,[1]+answer,sequence:0x50)
        }
        if frame.command == 2 { return BrandFrame(2,[4,7,50,60,70],sequence:frame.sequence) }
        if frame.command == 0xF3 {
            if frame.payload == [0x00,0x0B] { return BrandFrame(0xF3,[4,0,0x0B,0,0],sequence:frame.sequence) }
            if frame.payload == [0x00,0x07] { return BrandFrame(0xF3,[3,0,0x07,0x0C],sequence:frame.sequence) }
            if frame.payload == [0x00,0x04] { return BrandFrame(0xF3,[3,0,0x04,multi ? 1 : 0],sequence:frame.sequence) }
            if frame.payload == [0x00,0x03] { return BrandFrame(0xF3,[3,0,0x03,auto ? 1 : 0],sequence:frame.sequence) }
            if frame.payload == [0x00,0x09] { return BrandFrame(0xF3,[4,0,0x09,finding ? 1 : 0,finding ? 3 : 0],sequence:frame.sequence) }
            if frame.payload == [0x00,0x02] { return BrandFrame(0xF3,[0x0B,0x00,0x02]+groups,sequence:frame.sequence) }
            if frame.payload == [0x00,0x1E] { return BrandFrame(0xF3,[3,0,0x1E,spatial],sequence:frame.sequence) }
            if frame.payload == [0x00,0x0C] { return BrandFrame(0xF3,[3,0,0x0C,0x0C],sequence:frame.sequence) }
            return nil
        }
        if frame.command == 0xF2 {
            if frame.payload.starts(with:[3,0,0x04]) { multi=frame.payload[3] == 1; return BrandFrame(0xF2,[],sequence:frame.sequence) }
            if frame.payload.starts(with:[3,0,0x03]) { auto=frame.payload[3] == 1; return BrandFrame(0xF2,[],sequence:frame.sequence) }
            if frame.payload.starts(with:[4,0,0x09]) { finding=frame.payload[3] == 1; return BrandFrame(0xF2,[],sequence:frame.sequence) }
            if frame.payload.starts(with:[0x0B,0x00,0x02]) { groups=Array(frame.payload.dropFirst(3)); return BrandFrame(0xF2,[],sequence:frame.sequence) }
            if frame.payload.starts(with:[3,0,0x1D]) { spatial=frame.payload[3]; return BrandFrame(0xF2,[],sequence:frame.sequence) }
        }
        return nil
    }
    let s=DeviceSession(transport:t,name:"Xiaomi Buds 4 Pro",catalog:try ModelCatalog())
    defer { s.close() }
    try await s.open()
    #expect(s.state.switches[0x11] == true && s.state.switches[0x12] == false && s.state.finding == false)
    // Xiaomi has no host-list command: the dual toggle is exposed without
    // advertising a query the device can never answer.
    #expect(!s.canQuery(Command.hosts))
    #expect(s.availableFeatures.contains { $0.key == "dual" })
    #expect(s.state.placement[.left] == 3 && s.state.placement[.right] == 3)
    let dual=try #require(s.availableFeatures.first { $0.key == "dual" })
    let autoAnswer=try #require(s.availableFeatures.first { $0.key == "autoAnswer" })
    let disableDual=try await s.setFeature(dual,enabled:false)
    #expect(disableDual == .confirmed && s.state.switches[0x11] == false)
    let enableDual=try await s.setFeature(dual,enabled:true)
    #expect(enableDual == .confirmed && s.state.switches[0x11] == true)
    let enableAuto=try await s.setFeature(autoAnswer,enabled:true)
    #expect(enableAuto == .confirmed && s.state.switches[0x12] == true)
    let ring=try await s.find(true)
    #expect(ring == .confirmed && s.state.finding == true)
    let stop=try await s.find(false)
    #expect(stop == .confirmed && s.state.finding == false)
    let entry=try #require(s.state.gestures.first { $0.side == 1 && $0.gesture == 2 })
    let gesture=try await s.setGesture(entry,action:1)
    #expect(gesture == .confirmed && s.state.gestures.first { $0.id == entry.id }?.action == 1)
    #expect(s.state.switches[0x1B] == false)
    let spatialFeature=try #require(s.availableFeatures.first { $0.key == "spatialSound" })
    let spatialOn=try await s.setFeature(spatialFeature,enabled:true)
    #expect(spatialOn == .confirmed && s.state.switches[0x1B] == true)
    let spatialOff=try await s.setFeature(spatialFeature,enabled:false)
    #expect(spatialOff == .confirmed && s.state.switches[0x1B] == false)
}
@Test @MainActor func xiaomiGestureWriteLeavesUnassignedSidesAlone() async throws {
    let t=BrandRadio(.xiaomi,xiaomiMMA:true)
    var groups:[UInt8]=[1,3,0xFF,2,2,2,3,6,6]
    t.response={ frame in
        if frame.command == 2, frame.sequence == 0x50 {
            guard let answer=try? XiaomiAuth.response(Array(frame.payload.dropFirst())) else { return nil }
            return BrandFrame(2,[1]+answer,sequence:0x50)
        }
        if frame.command == 2 { return BrandFrame(2,[4,7,50,60,70],sequence:frame.sequence) }
        if frame.command == 0xF3 {
            if frame.payload == [0x00,0x0B] { return BrandFrame(0xF3,[4,0,0x0B,0,0],sequence:frame.sequence) }
            if frame.payload == [0x00,0x07] { return BrandFrame(0xF3,[3,0,0x07,0x0C],sequence:frame.sequence) }
            if frame.payload == [0x00,0x04] { return BrandFrame(0xF3,[3,0,0x04,1],sequence:frame.sequence) }
            if frame.payload == [0x00,0x03] { return BrandFrame(0xF3,[3,0,0x03,0],sequence:frame.sequence) }
            if frame.payload == [0x00,0x09] { return BrandFrame(0xF3,[4,0,0x09,0,0],sequence:frame.sequence) }
            if frame.payload == [0x00,0x02] { return BrandFrame(0xF3,[0x0B,0x00,0x02]+groups,sequence:frame.sequence) }
            if frame.payload == [0x00,0x1E] { return BrandFrame(0xF3,[3,0,0x1E,0x18],sequence:frame.sequence) }
            if frame.payload == [0x00,0x0C] { return BrandFrame(0xF3,[3,0,0x0C,0x0C],sequence:frame.sequence) }
            return nil
        }
        if frame.command == 0xF2, frame.payload.starts(with:[0x0B,0x00,0x02]) {
            groups=Array(frame.payload.dropFirst(3)); return BrandFrame(0xF2,[],sequence:frame.sequence)
        }
        return nil
    }
    let s=DeviceSession(transport:t,name:"Xiaomi Buds 4 Pro",catalog:try ModelCatalog())
    defer { s.close() }
    try await s.open()
    // The device reports the right side of the double press as unassigned (0xFF).
    #expect(s.state.gestures.first { $0.side == 1 && $0.gesture == 2 }?.action == 3)
    #expect(!s.state.gestures.contains { $0.side == 2 && $0.gesture == 2 })
    let entry=try #require(s.state.gestures.first { $0.side == 1 && $0.gesture == 2 })
    let outcome=try await s.setGesture(entry,action:1)
    #expect(outcome == .confirmed)
    // The rebuilt table keeps 0xFF instead of inventing a "no action" assignment.
    let write=t.commands.first { $0.command == 0xF2 && $0.payload.starts(with:[0x0B,0x00,0x02]) }
    #expect(write?.payload == [0x0B,0x00,0x02,1,1,0xFF,2,2,2,3,6,6])
}
@Test @MainActor func modelOverrideCannotConvertExistingWireProtocol() async throws {
    let t=BrandRadio(.vivo),s=DeviceSession(transport:t,name:"vivo TWS 4",catalog:try ModelCatalog())
    defer { s.close() };try await s.open()
    s.setModelOverride("huawei:FreeBudsPro3")
    #expect(s.model?.family == .vivo)
    #expect(!s.canWrite(Command.setCustomEQ))
}

@Test @MainActor func completeHuaweiHostListsProtectThisMacAndConfirmTargetOnly() async throws {
    let t=BrandRadio(.huawei),local:[UInt8]=[1,2,3,4,5,6]
    let s=DeviceSession(transport:t,name:"FreeBuds Pro",catalog:try ModelCatalog(),localHostAddress:local)
    defer { s.close() };try await s.open()
    t.response={ frame in
        if frame.command == 0x2B31 { return BrandFrame(0x2B31,[2,1,1,3,1,0,4,6,1,2,3,4,5,6,5,1,1,9,3,77,97,99]) }
        if frame.command == 0x0108 { return BrandFrame(0x0108,[2,1,80]) }
        if frame.command == 0x2B2A { return BrandFrame(0x2B2A,[1,2,0,0]) }
        if frame.command == 0x2B11 || frame.command == 0x2B2F { return BrandFrame(frame.command,[1,1,1]) }
        return nil
    }
    await s.refresh()
    let host=try #require(s.state.hosts.first)
    #expect(host.current && host.address == local)
    #expect(!s.canOperateHost(.disconnect,host:host))
    #expect(!s.canOperateHost(.automatic))
    let before=t.packets.count
    do { _ = try await s.operateHost(.disconnect,host:host);Issue.record("Current Mac was disconnected") }
    catch { #expect(error as? ProtocolError == .unsupported) }
    #expect(t.packets.count == before)
}
@Test @MainActor func closeCancelsPendingBrandReadAndClearsAllState() async throws {
    let t=BrandRadio(.huawei),s=DeviceSession(transport:t,name:"FreeBuds Studio",catalog:try ModelCatalog())
    try await s.open();t.ignore=true
    let task=Task { await s.refresh() }
    try await Task.sleep(for:.milliseconds(30));s.close();await task.value
    #expect(!s.ready && s.state.batteries.isEmpty && s.state.observedQueries.isEmpty)
}

@Test @MainActor func huaweiCustomEQRequiresCompleteFreshCustomField() async throws {
    let radio=BrandRadio(.huawei),s=DeviceSession(transport:radio,name:"FreeBuds Pro 3",catalog:try ModelCatalog())
    defer { s.close() };try await s.open();await s.refresh()
    #expect(!s.canWrite(Command.setCustomEQ))
    let row:[UInt8]=[100,10]+Array(repeating:0,count:10)+Array("Test".utf8)+Array(repeating:0,count:20)
    var custom:[UInt8]?=row
    radio.response={ frame in
        switch frame.command {
        case 0x0108:return BrandFrame(0x0108,[2,1,50])
        case 0x2B2A:return BrandFrame(0x2B2A,[1,2,0,0])
        case 0x2B4A:return BrandFrame(0x2B4A,[1,1,1,2,1,100]+(custom.map { [8,UInt8($0.count)]+$0 } ?? []))
        case 0x2B11,0x2B2F:return BrandFrame(frame.command,[1,1,1])
        case 0x2B6C:return BrandFrame(frame.command,[2,1,0])
        case 0x2B31:return BrandFrame(frame.command,[2,1,0])
        default:return nil
        }
    }
    await s.refresh()
    let entry=try #require(s.state.customEQ.first)
    #expect(s.canWrite(Command.setCustomEQ))
    #expect(try await s.saveEQ(entry) == .confirmed)
    var invalidGain=row;invalidGain[2]=61
    for malformed in [nil,Array(row.dropLast()),invalidGain] as [[UInt8]?] {
        custom=malformed
        do { _ = try await s.saveEQ(entry);Issue.record("Missing or damaged field confirmed cached EQ") }
        catch { #expect(error as? ProtocolError == .invalidPayload) }
        #expect(s.state.customEQ == [entry])
    }
    custom=[];await s.refresh()
    #expect(s.state.customEQ.isEmpty)
}

@Test @MainActor func crossFamilyOverrideIsIgnoredBeforeOpeningBrandSession() async throws {
    let radio=BrandRadio(.huawei),s=DeviceSession(transport:radio,name:"FreeBuds Pro 3",catalog:try ModelCatalog(),overrideID:"06EC10")
    defer { s.close() };try await s.open()
    #expect(s.model?.family == .huawei && s.model?.name.contains("Pro 3") == true)
    #expect(radio.packets.allSatisfy { $0.first == 0x5A })
}
