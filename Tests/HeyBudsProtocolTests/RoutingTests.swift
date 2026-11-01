import Testing
import HeyBudsProtocol

@Test func modelOverrideNeverChangesDetectedWireFamily() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.family(name:"FreeBuds Pro 3",override:"06EC10") == .huawei)
    #expect(catalog.validOverride("06EC10",family:.huawei) == nil)
    #expect(catalog.validOverride("06EC10",family:.oppo) == "06EC10")
    #expect(catalog.validOverride("06EC10",family:nil) == nil)
}

@Test func routingUsesServiceEvidenceWithoutGuessingUnknownDevices() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.routingFamily(name:"Personal headphones",services:[.oppo]) == .oppo)
    #expect(catalog.routingFamily(name:"Personal headphones",services:[.huawei]) == nil)
    #expect(catalog.routingFamily(name:"FreeBuds Pro 3",services:[.huawei]) == .huawei)
    #expect(catalog.routingFamily(name:"FreeBuds Pro 3",services:[.vivo]) == .vivo)
    #expect(catalog.routingFamily(name:"Personal headphones",services:[.oppo,.vivo]) == nil)
}

@Test func xiaomiResolvesBothDocumentedSppServices() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.family(name:"Xiaomi Buds 4 Pro") == .xiaomi)
    let familyModel=try #require(catalog.models.first { $0.id == "xiaomi:family" })
    #expect(familyModel.noiseOptions.isEmpty)
    let buds=try #require(catalog.model(productID:nil,name:"Xiaomi Buds 4 Pro"))
    #expect(buds.id == "xiaomi:buds4pro")
    #expect(buds.noiseOptions.map(\.mode) == [.off,.anc,.light,.medium,.deep,.transparency])
    #expect(buds.presets.map(\.id) == [0,1,5,6,11,12])
    #expect(buds.function["multiDevicesConnect"].enabled && buds.function["autoAnswerCalls"].enabled && buds.function["findDevice"].enabled)
    #expect(Set(buds.features.map(\.key)).isSuperset(of:["dual","autoAnswer"]))
    #expect(buds.features.contains { $0.key == "spatialSound" })
    #expect(EarbudFamily.xiaomi.serviceUUID == XiaomiProtocol.xiaoAiService)
    #expect(EarbudFamily.xiaomi.classicServiceUUIDs == [XiaomiProtocol.xiaoAiService])
    #expect(buds.raw["protocolVariant"].text == "mma")
    #expect(buds.isXiaomiMMA)
    #expect(EarbudFamily.xiaomi.controlServiceUUIDs(for:"Xiaomi Buds 4 Pro",xiaomiMMA:true) == XiaomiProtocol.services)
    #expect(EarbudFamily.xiaomi.controlServiceUUIDs(for:"Redmi Buds 6") == [XiaomiProtocol.xiaoAiService])
    // The verified MMA profile always offers every documented route, even when
    // the SDP cache is empty at discovery time; the transport resolves the
    // records itself and retires a route that fails or times out.
    for cached in [[], [XiaomiProtocol.fastConnectService], [XiaomiProtocol.xiaoAiService], XiaomiProtocol.services] {
        #expect(EarbudFamily.xiaomi.resolvedControlServiceUUIDs(for:"Xiaomi Buds 4 Pro",
            available:cached,xiaomiMMA:true) == XiaomiProtocol.services)
    }
    // Legacy Xiaomi/Redmi keeps the single XiaoAi route and the old fallback.
    #expect(EarbudFamily.xiaomi.resolvedControlServiceUUIDs(for:"Redmi Buds 6",
        available:[XiaomiProtocol.xiaoAiService]) == [XiaomiProtocol.xiaoAiService])
    #expect(EarbudFamily.xiaomi.resolvedControlServiceUUIDs(for:"Redmi Buds 6",
        available:[]) == [])
    // Sony must keep the generation selected by the model, even if both records are cached.
    #expect(EarbudFamily.sony.controlServiceUUIDs(for:"WH-1000XM4") == [SonyProtocol.serviceV1])
    #expect(EarbudFamily.sony.resolvedControlServiceUUIDs(for:"WH-1000XM4",
        available:[SonyProtocol.serviceV1,SonyProtocol.serviceV2]) == [SonyProtocol.serviceV1])
    // If only the other generation is cached, the original single-service
    // fallback still applies instead of failing the connection outright.
    #expect(EarbudFamily.sony.resolvedControlServiceUUIDs(for:"WH-1000XM4",
        available:[SonyProtocol.serviceV2]) == [SonyProtocol.serviceV2])
    #expect(EarbudFamily.sony.resolvedControlServiceUUIDs(for:"WH-1000XM4",
        available:[]) == [])
    #expect(EarbudFamily.sony.resolvedControlServiceUUIDs(for:"WH-1000XM5",
        available:[SonyProtocol.serviceV2]) == [SonyProtocol.serviceV2])
}

@Test func expansionUsesOnlyModelSpecificControlRoutes() throws {
    let catalog=try ModelCatalog()
    #expect(catalog.models.count == 229)
    #expect(EarbudFamily.oppo.transportKinds(for:"OPPO Enco X4") == ["RFCOMM","BLE"])
    #expect(EarbudFamily.bose.transportKinds(for:"Bose QuietComfort Ultra Earbuds (2nd Gen)") == ["BLE"])
    #expect(EarbudFamily.bose.transportKinds(for:"Bose QuietComfort 45") == ["RFCOMM"])
    for name in ["WH-1000XM3","Sony WH-1000XM4"] {
        #expect(EarbudFamily.sony.serviceUUID(for:name) == SonyProtocol.serviceV1)
    }
    for name in ["WH-1000XM5","WH-XB910N","ULT WEAR","WH-ULT900N"] {
        #expect(EarbudFamily.sony.serviceUUID(for:name) == SonyProtocol.serviceV2)
    }
    let added=catalog.models.filter { [.samsung,.google,.bose,.nothing].contains($0.family) }
    #expect(added.count == 12)
    for model in added {
        #expect(catalog.validOverride(model.id,family:model.family) == nil)
        for name in [model.name]+model.aliases {
            #expect(catalog.family(name:name) == model.family)
            if model.family == .bose { #expect(BoseProfile.named(name)?.modelID == model.id) }
            if model.family == .nothing { #expect(NothingProfile.named(name)?.modelID == model.id) }
            if model.family == .samsung { #expect(SamsungProfile.named(name)?.modelID == model.id) }
        }
    }
    for name in ["Galaxy Buds2 FE","Pixel Buds A-Series","Bose QuietComfort Ultra Earbuds","Nothing Ear (2)","CMF Buds 2 Plus"] {
        #expect(catalog.model(productID:nil,name:name) == nil)
        #expect(catalog.family(name:name) == nil)
    }
}
