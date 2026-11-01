import Foundation
import Testing
@testable import HeyBudsProtocol

private func hex(_ string:String) -> [UInt8] { string.split(separator:" ").map { UInt8($0,radix:16)! } }
@Test func catalogIndexesPreserveLookupPrecedenceAndAliasOrder() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.model(productID:"06c410",name:"FreeBuds Pro 3")?.id == "06C410")
    #expect(catalog.model(productID:"06C410",name:"AirPods Pro",override:"066452")?.id == "066452")
    #expect(catalog.model(productID:"missing",name:"OPPO Enco Air5 Pro",override:"missing")?.id == "06C410")
    for model in catalog.models {
        for name in [model.name]+model.aliases {
            let key=EarbudFamily.normalize(name)
            let first=catalog.models.first { candidate in
                ([candidate.name]+candidate.aliases).contains { EarbudFamily.normalize($0) == key }
            }
            #expect(catalog.model(productID:nil,name:name)?.id == first?.id)
        }
    }
}
@Test func migratedCatalogCoversSourceFamiliesAndDisambiguatesNames() throws {
    let c=try ModelCatalog()
    #expect(c.models.filter { [.oppo,.vivo,.huawei,.xiaomi,.edifier].contains($0.family) }.count == 210)
    #expect(c.models.filter { $0.family == .vivo }.count == 43)
    #expect(c.models.filter { $0.family == .huawei }.count == 24)
    #expect(c.models.filter { $0.family == .vivo }.reduce(0) { $0+$1.raw["sourceEntries"].elements.count } == 87)
    for n in ["FreeBuds Pro 2","FreeBuds Pro 3","FreeBuds Pro 4","FreeBuds Pro 5"] {
        #expect(c.model(productID:nil,name:n+" (test)")?.name == "HUAWEI "+n)
    }
    #expect(c.family(name:"DPD2321A LE") == .vivo)
    #expect(c.family(name:"my Redmi Buds") == .xiaomi)
    #expect(c.family(name:"W820NB Plus") == .edifier)
    #expect(c.family(name:"AirPods Pro") == nil)
    #expect(c.family(name:"Beats Fit Pro") == nil)
    #expect(!c.models.contains { $0.id.hasPrefix("apple:") })
    #expect(c.family(name:"Soundcore Liberty Air") == nil)
    #expect(c.family(name:"Keyboard") == nil)
    let tws3e=try #require(c.model(productID:nil,name:"vivo TWS 3e"))
    #expect(!tws3e.hasMultiDevice)
    #expect(tws3e.function["findDevice"].enabled && tws3e.function["wearDetection"].enabled)
    #expect(!tws3e.supportsGame)
    #expect(tws3e.raw["noiseSuffix"].elements.compactMap(\.int) == [3])
}
@Test func goldenBrandFramesAndEveryStreamSplit() throws {
    let fixtures:[(EarbudFamily,UInt8,Bool,BrandFrame,[UInt8])]=[
        (.vivo,3,false,BrandFrame(0x0300),hex("FF 04 00 00 00 0A 03 00")),
        (.vivo,3,false,BrandFrame(0x0207),hex("FF 04 00 00 00 1B 02 07")),
        (.vivo,3,false,BrandFrame(0x0130,[2,4,0]),hex("FF 03 00 03 00 1B 01 30 02 04 00")),
        (.huawei,4,false,BrandFrame(0x0108,[1,0,2,0,3,0]),hex("5A 00 09 00 01 08 01 00 02 00 03 00 FB B9")),
        (.huawei,4,false,BrandFrame(0x2B2A,[1,0]),hex("5A 00 05 00 2B 2A 01 00 42 7E")),
        (.huawei,4,true,BrandFrame(0x2B49,[1,1,5,2,2,0x10,0x20]),hex("5A 00 0A 00 2B 49 01 01 05 02 02 10 20 B9 D4")),
        (.xiaomi,4,false,BrandFrame(2,[255,255,255,255],sequence:0x0B),hex("FE DC BA C4 02 00 05 0B FF FF FF FF EF")),
        (.xiaomi,4,false,BrandFrame(0xF2,[3,0,47,1],sequence:0x90),hex("FE DC BA C4 F2 00 05 90 03 00 2F 01 EF")),
        (.xiaomi,4,false,BrandFrame(0x51,[3,1],sequence:0,kind:4),hex("FE DC BA 04 51 00 03 00 03 01 EF"))]
    for (family,version,mbb,frame,wire) in fixtures {
        let c=BrandFrameCodec(family:family,gaiaVersion:version,mbb:mbb)
        #expect(Array(try c.encode(frame)) == wire)
        // Xiaomi response frames deliberately encode as request frames (no status);
        // their decode is covered by xiaomiResponseFramesDropStatusAndKeepRequestSequence.
        if family == .xiaomi,frame.kind & 0x80 == 0 { continue }
        for split in 0...wire.count {
            var decoder=c
            let a=decoder.feed(Data([0,1,2])+Data(wire.prefix(split)))
            let b=decoder.feed(Data(wire.dropFirst(split))+Data(wire))
            #expect((a+b).map(\.command) == [frame.command,frame.command])
            #expect((a+b).map(\.payload) == [frame.payload,frame.payload])
        }
    }
}
@Test func xiaomiMMARequestsKeepTheLegacyLayoutAndDecode() throws {
    // Requests are unchanged by the MMA variant: no status byte and the
    // sequence stays at offset 7.
    let wire=hex("FE DC BA C4 02 00 05 0B 00 00 00 80 EF")
    #expect(Array(try BrandFrameCodec(family:.xiaomi,xiaomiMMA:true).encode(BrandFrame(2,[0,0,0,0x80],sequence:0x0B))) == wire)
    // Device-originated request/notification types decode as [SN][payload].
    let request=hex("FE DC BA C4 F2 00 03 91 00 04 EF")
    var decoder=BrandFrameCodec(family:.xiaomi,xiaomiMMA:true)
    #expect(decoder.feed(Data(request)) == [BrandFrame(0xF2,[0,4],sequence:0x91,kind:0xC4)])
}
@Test func xiaomiResponseFramesDropStatusAndKeepRequestSequence() throws {
    let wire=hex("FE DC BA 04 02 00 07 00 0B 04 07 64 64 5B EF")
    let expected=BrandFrame(2,[4,7,100,100,91],sequence:0x0B,kind:4)
    for split in 0...wire.count {
        var decoder=BrandFrameCodec(family:.xiaomi,xiaomiMMA:true)
        let a=decoder.feed(Data([0,1,2])+Data(wire.prefix(split)))
        let b=decoder.feed(Data(wire.dropFirst(split))+Data(wire))
        #expect(a+b == [expected,expected])
    }
}
@Test func xiaomiLegacyFamilyKeepsNoStatusBatteryAndConfig47Layout() throws {
    let model=DeviceModel.readOnly(name:"Xiaomi / Redmi",family:.xiaomi)
    var state=DeviceState()
    var codec=BrandFrameCodec(family:.xiaomi)
    let battery=codec.feed(Data(hex("FE DC BA 04 02 00 08 0B 02 02 04 07 32 3C 46 EF")))
    let batteryFrame=try #require(battery.first)
    #expect(batteryFrame == BrandFrame(2,[2,2,4,7,50,60,70],sequence:0x0B,kind:4))
    #expect(BrandState.apply(batteryFrame,model:model,to:&state))
    #expect(state.batteries[.left]?.percent == 50)
    #expect(state.batteries[.right]?.percent == 60)
    #expect(state.batteries[.enclosure]?.percent == 70)
    let lowLatency=codec.feed(Data(hex("FE DC BA 04 F3 00 05 31 03 00 2F 01 EF")))
    let switchFrame=try #require(lowLatency.first)
    #expect(BrandState.apply(switchFrame,model:model,to:&state))
    #expect(state.switches[6] == true)
}
@Test func xiaomiDeviceInfoBatteryResponseParsesCaptureShape() throws {
    let model=try #require(ModelCatalog().model(productID:nil,name:"Xiaomi Buds 4 Pro"))
    var state=DeviceState()
    // DeviceInfo reply shape observed on a Xiaomi Buds 4 Pro. Battery is TLV
    // tag 7; product, serial and firmware fields are synthetic placeholders.
    var codec=BrandFrameCodec(family:.xiaomi,xiaomiMMA:true)
    let frames=codec.feed(Data(hex(
        "FE DC BA 04 02 00 3F 00 0B 12 00 58 69 61 6F 6D 69 20 42 75 64 73 20 34 20 50 72 6F " +
        "03 01 00 01 05 03 00 00 00 00 02 04 01 02 05 00 04 07 64 64 5B 02 08 00 02 09 00 " +
        "02 0A 01 02 0B 01 02 0D 02 02 0E 03 02 0F 01 EF")))
    let frame=try #require(frames.first)
    #expect(frames.count == 1 && frame.command == 2 && frame.sequence == 0x0B)
    #expect(BrandState.apply(frame,model:model,to:&state))
    #expect(state.batteries[.left]?.percent == 100)
    #expect(state.batteries[.right]?.percent == 100)
    #expect(state.batteries[.enclosure]?.percent == 91)
    #expect(state.observedQueries.contains(Command.battery))
}
@Test func xiaomiInvalidBatteryReadingClearsTheSlot() throws {
    let model=try #require(ModelCatalog().model(productID:nil,name:"Xiaomi Buds 4 Pro"))
    var state=DeviceState()
    state.batteries[.left]=BatteryReading(percent:55)
    state.batteries[.right]=BatteryReading(percent:55)
    var codec=BrandFrameCodec(family:.xiaomi,xiaomiMMA:true)
    let frames=codec.feed(Data(hex("FE DC BA 04 02 00 07 00 0B 04 07 00 00 5B EF")))
    let frame=try #require(frames.first)
    #expect(BrandState.apply(frame,model:model,to:&state))
    // 0 is not a valid MMA reading; the old value must not stay on screen.
    #expect(state.batteries[.left] == nil)
    #expect(state.batteries[.right] == nil)
    #expect(state.batteries[.enclosure]?.percent == 91)
}
@Test func xiaomiBatteryChargingBitsApplyToBudsAndCase() throws {
    let model=try #require(ModelCatalog().model(productID:nil,name:"Xiaomi Buds 4 Pro"))
    var state=DeviceState()
    var codec=BrandFrameCodec(family:.xiaomi,xiaomiMMA:true)
    let frames=codec.feed(Data(hex("FE DC BA 04 02 00 07 00 0B 04 07 E4 E3 DB EF")))
    let frame=try #require(frames.first)
    #expect(BrandState.apply(frame,model:model,to:&state))
    #expect(state.batteries[.left]?.percent == 100 && state.batteries[.left]?.charging == true)
    #expect(state.batteries[.right]?.percent == 99 && state.batteries[.right]?.charging == true)
    #expect(state.batteries[.enclosure]?.percent == 91 && state.batteries[.enclosure]?.charging == true)
}
@Test func xiaomiInEarStateMapsWearAndCaseBits() throws {
    let model=try #require(ModelCatalog().model(productID:nil,name:"Xiaomi Buds 4 Pro"))
    var state=DeviceState()
    var codec=BrandFrameCodec(family:.xiaomi,xiaomiMMA:true)
    let worn=codec.feed(Data(hex("FE DC BA 04 F3 00 06 00 32 03 00 0C 0C EF")))
    let wornFrame=try #require(worn.first)
    #expect(BrandState.apply(wornFrame,model:model,to:&state))
    #expect(state.placement[.left] == 3 && state.placement[.right] == 3)
    let cased=codec.feed(Data(hex("FE DC BA 04 F3 00 06 00 33 03 00 0C 03 EF")))
    let casedFrame=try #require(cased.first)
    #expect(BrandState.apply(casedFrame,model:model,to:&state))
    #expect(state.placement[.left] == 4 && state.placement[.right] == 4)
}
@Test func xiaomiNoiseConfigResponseAndNotificationParse() throws {
    let model=try #require(ModelCatalog().model(productID:nil,name:"Xiaomi Buds 4 Pro"))
    var state=DeviceState()
    var codec=BrandFrameCodec(family:.xiaomi,xiaomiMMA:true)
    let get=codec.feed(Data(hex("FE DC BA 04 F3 00 07 00 21 04 00 0B 01 00 EF")))
    let getFrame=try #require(get.first)
    #expect(getFrame == BrandFrame(0xF3,[4,0,0x0B,1,0],sequence:0x21,kind:4))
    #expect(BrandState.apply(getFrame,model:model,to:&state))
    #expect(state.noise == .anc && state.observedQueries.contains(Command.noise))
    let note=codec.feed(Data(hex("FE DC BA C7 F4 00 06 23 04 00 0B 02 00 EF")))
    let noteFrame=try #require(note.first)
    #expect(noteFrame == BrandFrame(0xF4,[4,0,0x0B,2,0],sequence:0x23,kind:0xC7))
    #expect(BrandState.apply(noteFrame,model:model,to:&state))
    #expect(state.noise == .transparency)
    let deep=codec.feed(Data(hex("FE DC BA 04 F3 00 07 00 24 04 00 0B 01 03 EF")))
    let deepFrame=try #require(deep.first)
    #expect(BrandState.apply(deepFrame,model:model,to:&state))
    #expect(state.noise == .deep)
}
@Test func xiaomiEqualizerConfigResponseAndNotificationParse() throws {
    let catalog=try ModelCatalog()
    let model=try #require(catalog.model(productID:nil,name:"Xiaomi Buds 4 Pro"))
    var state=DeviceState()
    var codec=BrandFrameCodec(family:.xiaomi,xiaomiMMA:true)
    let get=codec.feed(Data(hex("FE DC BA 04 F3 00 06 00 27 03 00 07 0C EF")))
    let getFrame=try #require(get.first)
    #expect(getFrame == BrandFrame(0xF3,[3,0,0x07,12],sequence:0x27,kind:4))
    #expect(BrandState.apply(getFrame,model:model,to:&state))
    #expect(state.eq == 12 && state.observedQueries.contains(Command.equalizer))
    let note=codec.feed(Data(hex("FE DC BA C7 F4 00 05 28 03 00 07 06 EF")))
    let noteFrame=try #require(note.first)
    #expect(noteFrame == BrandFrame(0xF4,[3,0,0x07,6],sequence:0x28,kind:0xC7))
    #expect(BrandState.apply(noteFrame,model:model,to:&state))
    #expect(state.eq == 6)
}
@Test func xiaomiGestureConfigResponseParses() throws {
    let catalog=try ModelCatalog()
    let model=try #require(catalog.model(productID:nil,name:"Xiaomi Buds 4 Pro"))
    var state=DeviceState()
    var codec=BrandFrameCodec(family:.xiaomi,xiaomiMMA:true)
    let frames=codec.feed(Data(hex("FE DC BA 04 F3 00 0E 00 30 0B 00 02 01 03 03 02 02 02 03 06 06 EF")))
    let frame=try #require(frames.first)
    #expect(frame == BrandFrame(0xF3,[0x0B,0x00,0x02,1,3,3,2,2,2,3,6,6],sequence:0x30,kind:4))
    #expect(BrandState.apply(frame,model:model,to:&state))
    #expect(state.gestures.count == 6)
    #expect(state.gestures.contains { $0.side == 1 && $0.gesture == 2 && $0.action == 3 })
    #expect(state.gestures.contains { $0.side == 2 && $0.gesture == 4 && $0.action == 6 })
    #expect(state.observedQueries.contains(Command.gestures))
}
@Test func xiaomiSpatialConfigParsesEnableBit() throws {
    let catalog=try ModelCatalog()
    let model=try #require(catalog.model(productID:nil,name:"Xiaomi Buds 4 Pro"))
    var state=DeviceState()
    var codec=BrandFrameCodec(family:.xiaomi,xiaomiMMA:true)
    let frames=codec.feed(Data(hex("FE DC BA 04 F3 00 06 00 31 03 00 1E 19 EF")))
    let frame=try #require(frames.first)
    #expect(BrandState.apply(frame,model:model,to:&state))
    #expect(state.spatial == 0x19 && state.switches[0x1B] == true)
}
@Test func edifierFrameRetainsCommandAndLastPayloadByte() throws {
    let codec=BrandFrameCodec(family:.edifier)
    let bytes=Array(try codec.encode(BrandFrame(0xC1,[3])))
    #expect(bytes == hex("AA 02 C1 03 21 89"))
    var response:[UInt8]=[0xBB,2,0xCC,3]
    let sum=response.reduce(UInt16(8217)) { $0 &+ UInt16($1) };response += [UInt8(sum>>8),UInt8(truncatingIfNeeded:sum)]
    for split in 0...response.count {
        var c=codec
        let a=c.feed(Data(response.prefix(split))),b=c.feed(Data(response.dropFirst(split)))
        #expect(a+b == [BrandFrame(0xCC,[3])])
    }
}
@Test func brandFramesRejectCorruptionAndRecover() throws {
    let frame=BrandFrame(0x2B2A,[1,2,3,1]),codec=BrandFrameCodec(family:.huawei)
    let good=try codec.encode(frame);var bad=Array(good);bad[bad.count-1] ^= 1
    var decoder=codec
    #expect(decoder.feed(Data(bad)+good) == [frame])
    #expect(BrandFrameCodec.tlv([1,4,2]) == nil)
    #expect(throws:ProtocolError.invalidPayload) { try BrandFrameCodec(family:.vivo).encode(BrandFrame(1,Array(repeating:0,count:255))) }
    #expect(throws:ProtocolError.invalidPayload) { try BrandFrameCodec(family:.edifier).encode(BrandFrame(1,Array(repeating:0,count:255))) }
}
@Test func brandBatteryUnknownZeroAndWearStatesStayDistinct() throws {
    let catalog=try ModelCatalog(),v=try #require(catalog.model(productID:nil,name:"vivo TWS 4")),h=try #require(catalog.model(productID:nil,name:"FreeBuds Studio"))
    var state=DeviceState()
    #expect(BrandState.apply(BrandFrame(0x8207,[0,0,255,80,5]),model:v,to:&state))
    #expect(state.batteries[.left]?.percent == 0 && state.batteries[.left]?.charging == true)
    #expect(state.batteries[.right] == nil)
    #expect(state.batteries[.enclosure]?.percent == 80)
    #expect(!BrandState.apply(BrandFrame(0x8207,[1,50,50,50,0]),model:v,to:&state))
    #expect(BrandState.apply(BrandFrame(0x820D,[0,6]),model:v,to:&state))
    #expect(state.placement[.left] == 3 && state.placement[.right] == 4)
    #expect(BrandState.apply(BrandFrame(0x0108,[2,1,75,3,1,1]),model:h,to:&state))
    #expect(state.batteries[.left]?.percent == 75 && state.batteries[.left]?.charging == true)
    #expect(state.batteries[.right] == nil && state.batteries[.enclosure] == nil)
}
@Test func modelSpecificNoiseAndEQAreNotInterchangeable() throws {
    let c=try ModelCatalog(),pro=try #require(c.model(productID:nil,name:"FreeBuds Pro 3")),air=try #require(c.model(productID:nil,name:"vivo TWS Air3 Pro"))
    #expect(pro.presets.map(\.id) == [5,1,2,9])
    #expect(pro.noiseOptions.first(where:{$0.mode == .deep})?.writeBytes == [1,2])
    #expect(air.raw["gaiaVersion"].int == 3)
    #expect(air.raw["noiseSuffix"].elements.compactMap(\.int) == [4,0])
    var state=DeviceState()
    #expect(BrandState.apply(BrandFrame(0x2B2A,[1,2,2,1]),model:pro,to:&state))
    #expect(state.noise == .deep)
    // A SET echo must not become verified state.
    #expect(!BrandState.apply(BrandFrame(0x8130,[2,4,0]),model:air,to:&state))
    #expect(state.noise == .deep)
    #expect(BrandState.apply(BrandFrame(0x8230,[0,2,1]),model:air,to:&state))
    #expect(state.noise == .transparency)
}
@Test func remoteListsRequireCompleteRowsAndCorrectAddressOrder() {
    let payload:[UInt8]=[0,1,6,5,4,3,2,1,0,0,0,2,3,77,97,99]
    #expect(BrandState.vivoHosts(payload)?.first?.address == [1,2,3,4,5,6])
    #expect(BrandState.vivoHosts(Array(payload.dropLast())) == nil)
    #expect(BrandState.vivoHosts([0,0]) == [])
    let row:[UInt8]=[2,1,1,3,1,0,4,6,1,2,3,4,5,6,5,1,9,7,1,1,9,3,77,97,99]
    let host=BrandState.huaweiHost(row)?.host
    #expect(host?.address == [1,2,3,4,5,6] && host?.preferred == true && host?.audioActive == true)
}
@Test func xiaomiAuthMatchesIndependentUpstreamRoundFunctionVectors() throws {
    #expect(try XiaomiAuth.response([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]) == [224, 205, 103, 156, 132, 213, 183, 32, 79, 23, 165, 217, 35, 67, 90, 104])
    #expect(try XiaomiAuth.response([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) == [215, 170, 85, 59, 84, 215, 123, 176, 201, 219, 112, 252, 201, 89, 164, 5])
    #expect(try XiaomiAuth.response([255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255]) == [149, 177, 97, 196, 26, 182, 62, 95, 90, 132, 6, 21, 75, 9, 249, 76])
    #expect(throws:ProtocolError.invalidPayload) { try XiaomiAuth.response([0]) }
}
