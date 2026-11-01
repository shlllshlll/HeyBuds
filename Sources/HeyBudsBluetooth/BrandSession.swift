// Per-brand sessions ported from OppoPodsManager (GPL-3.0-or-later).
// Command.* values below are shared UI capability keys; only BrandFrameCodec
// produces wire packets. No OPPO framing or handshake reaches another brand.
import Foundation
import HeyBudsProtocol

@MainActor final class BrandSession {
    private(set) var state=DeviceState()
    private(set) var model:DeviceModel
    /// Only the verified Buds 4 Pro profile uses the newer MMA frame/battery layout.
    private var xiaomiMMA:Bool { model.isXiaomiMMA }
    private(set) var ready=false
    var onChange:(()->Void)?
    var onClose:((String?)->Void)?
    var onDiagnostic:((String)->Void)?
    var interactive=false
    let transport:EarbudTransport
    let family:EarbudFamily
    private let catalog:ModelCatalog
    private let name:String
    private var codec:BrandFrameCodec
    private let gate=RequestGate()
    private var generation=UUID()
    private var poll:Task<Void,Never>?
    private struct Pending {
        let accepts:(BrandFrame)->Bool
        let exchange:AsyncExchange<BrandFrame>
    }
    private var pending:Pending?
    private var huaweiRows:[Int:RemoteHost]=[:]
    private var huaweiExpected:Int?
    private var collectingHosts=false
    private var spatialScene:UInt8?
    private var sequence:UInt8=0x90
    private let localHostAddress:[UInt8]?
    init(transport:EarbudTransport,name:String,catalog:ModelCatalog,family:EarbudFamily,overrideID:String?,localHostAddress:[UInt8]?=nil) {
        self.transport=transport;self.name=name;self.catalog=catalog;self.family=family;self.localHostAddress=localHostAddress
        model=catalog.model(productID:nil,name:name,override:overrideID)
            ?? catalog.models.first(where:{$0.family == family && $0.raw["familyOnly"].enabled})
            ?? .readOnly(name:name,family:family)
        if model.family != family { model = .readOnly(name:name,family:family) }
        codec=BrandFrameCodec(family:family,gaiaVersion:UInt8(model.raw["gaiaVersion"].int ?? 4),xiaomiMMA:model.isXiaomiMMA)
    }
    func open() async throws {
        let token=generation
        transport.onEvent={ [weak self] event in
            guard let self,self.generation == token else { return }
            switch event { case .data(let data):self.receive(data);case .closed(let reason):self.close();self.onClose?(reason) }
        }
        try await transport.open()
        try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
        switch family {
        case .vivo:
            let handshake=try await request(0x0300)
            guard handshake.payload.isEmpty || handshake.payload.first == 0 else { throw ProtocolError.invalidPayload }
            for c in UInt16(0x0202)...0x0206 { try await send(c) }
            try await read(Command.battery)
        case .huawei:
            guard model.raw["route"].text != nil else { throw ProtocolError.unsupported }
            if model.raw["sourceCapabilities"]["SupportsRfcommBattery"].enabled { _ = try? await read(Command.battery) }
            if state.observedQueries.isEmpty,model.raw["sourceCapabilities"]["SupportsAncStateReadback"].enabled { _ = try? await read(Command.noise) }
            guard !state.observedQueries.isEmpty else { throw ProtocolError.invalidPayload }
        case .edifier:
            _ = try? await read(Command.battery)
            if state.observedQueries.isEmpty { _ = try? await read(Command.noise) }
            guard !state.observedQueries.isEmpty else { throw ProtocolError.invalidPayload }
        case .xiaomi:
            // Optional upstream probe retained as a read-only DeviceInfo request. Some
            // firmware answers the documented auth opcode with a result that does not
            // match XiaomiAuth, so only send the auth result when this probe verifies.
            // MMA firmware may answer with a full DeviceInfo payload, so accept its
            // sequence instead of waiting out the probe timeout on every connection.
            let random=(0..<16).map { _ in UInt8.random(in:0...255) }
            let authAccepts:(BrandFrame)->Bool = xiaomiMMA
                ? { $0.command == 2 && $0.sequence == 0x50 }
                : { $0.payload.count == 17 }
            if let response=try? await request(2,payload:[1]+random,sequence:0x50,timeout:1.2,accepts:authAccepts),
               response.payload.count == 17,
               Array(response.payload.dropFirst()) == (try XiaomiAuth.response(random)) {
                try await send(0x51,payload:[3,1],sequence:0,kind:4)
            }
            try await read(Command.battery)
            if xiaomiMMA {
                if canQuery(Command.noise) { _ = try? await read(Command.noise) }
                if canQuery(Command.equalizer) { _ = try? await read(Command.equalizer) }
                if model.function["multiDevicesConnect"].enabled { _ = try? await readXiaomiFlag(0x0004) }
                if model.function["autoAnswerCalls"].enabled { _ = try? await readXiaomiFlag(0x0003) }
                if model.function["findDevice"].enabled { _ = try? await readXiaomiFlag(0x0009) }
                if canQuery(Command.gestures) { _ = try? await read(Command.gestures) }
                if model.function["spatialSound"].enabled { _ = try? await readXiaomiFlag(0x001E) }
                if canQuery(Command.wear) { _ = try? await read(Command.wear) }
            }
        default:throw ProtocolError.unsupported
        }
        try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
        guard !state.observedQueries.isEmpty else { throw ProtocolError.invalidPayload }
        ready=true;onChange?()
    }
    func initialize() async {
        await refresh()
        guard ready,!Task.isCancelled else { return }
        poll=Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for:.seconds(self.interactive ? 15 : 45))
                guard !Task.isCancelled,self.ready else { return }
                await self.refresh()
            }
        }
    }
    func refresh() async {
        guard ready else { return }
        let token=generation
        for command in [Command.battery,Command.noise,Command.equalizer,Command.spatial,Command.gestures,Command.switches,Command.wear,Command.firmware,Command.hosts] where canQuery(command) {
            guard !Task.isCancelled,ready,generation == token else { return }
            _ = try? await read(command)
        }
        if xiaomiMMA {
            if model.function["multiDevicesConnect"].enabled { _ = try? await readXiaomiFlag(0x0004) }
            if model.function["autoAnswerCalls"].enabled { _ = try? await readXiaomiFlag(0x0003) }
            if model.function["findDevice"].enabled { _ = try? await readXiaomiFlag(0x0009) }
            if model.function["spatialSound"].enabled { _ = try? await readXiaomiFlag(0x001E) }
        }
        let stale=state.batteries.filter { Date().timeIntervalSince($0.value.updatedAt) >= 120 }.map(\.key)
        for slot in stale { state.batteries[slot]=nil }
        if !stale.isEmpty { onChange?() }
    }
    var availableFeatures:[FeatureDefinition] {
        var features=model.features
        if model.function["hearingProtection"].enabled { features.append(FeatureDefinition("hearingProtection",0x70)) }
        return features
    }
    var gameFeature:FeatureDefinition? {
        (model.supportsGame || family == .xiaomi) && state.switches[6] != nil ? FeatureDefinition("game",6) : nil
    }
    var supportsSpatialAudio:Bool { !model.spatialModes.isEmpty && state.spatial != nil }
    func canQuery(_ command:UInt16) -> Bool {
        switch command {
        case Command.battery:return family != .huawei || model.raw["sourceCapabilities"]["SupportsRfcommBattery"].enabled
        case Command.noise:return !model.noiseOptions.isEmpty && (family != .huawei || model.raw["sourceCapabilities"]["SupportsAncStateReadback"].enabled)
        case Command.equalizer:return !model.presets.isEmpty || !model.customEQFrequencies.isEmpty
        case Command.customEQ:return !model.customEQFrequencies.isEmpty
        case Command.spatial:return !model.spatialModes.isEmpty
        case Command.gestures:return family == .xiaomi && model.function["control"].enabled
        case Command.switches:
            if family == .xiaomi { return xiaomiMMA ? (model.supportsGame || model.function["lowLatency"].enabled) : true }
            return !availableFeatures.isEmpty || model.supportsGame
        // Xiaomi has no host-list command: expose the dual-connection toggle only,
        // instead of advertising a query that can never be answered.
        case Command.hosts:return family != .xiaomi && model.hasMultiDevice
        case Command.wear:return family == .vivo || (family == .xiaomi && model.function["inEarState"].enabled)
        case Command.firmware:return family == .vivo
        default:return false
        }
    }
    func canWrite(_ command:UInt16,reading:UInt16?) -> Bool {
        guard ready else { return false }
        switch command {
        case Command.setNoise:return !model.noiseOptions.isEmpty && (state.noise != nil || (family == .huawei && model.raw["route"].text == "FreeBuds3"))
        case Command.setEQ:return (!model.presets.isEmpty || !state.customEQ.isEmpty) && state.eq != nil
        case Command.setSpatial:return supportsSpatialAudio
        case Command.setSwitch:return availableFeatures.contains(where:canSetFeature) || gameFeature != nil
        case Command.setCustomEQ:return !model.customEQFrequencies.isEmpty && state.observedQueries.contains(Command.customEQ)
        case Command.operateHost:return model.hasMultiDevice && state.observedQueries.contains(Command.hosts)
        case Command.find:
            if family == .xiaomi { return model.function["findDevice"].enabled && state.finding != nil }
            return family == .vivo && model.function["findDevice"].enabled
        case Command.setGestures:return family == .xiaomi && !state.gestures.isEmpty
        default:return false
        }
    }
    func canSetFeature(_ feature:FeatureDefinition) -> Bool {
        guard ready,state.switches[feature.switchID] != nil else { return false }
        if feature.key == "game" { return gameFeature == feature }
        // vivo has no confirmed readable dual-enable state. Do not claim a switch value from a host list.
        if family == .vivo,feature.key == "dual" { return false }
        return availableFeatures.contains(feature)
    }
    @discardableResult private func read(_ command:UInt16) async throws -> DeviceState {
        var sample=DeviceState()
        switch family {
        case .vivo:
            switch command {
            case Command.battery:sample = try await readRequest(0x0207)
            case Command.noise:sample = try await readRequest(0x0230,payload:model.raw["gaiaVersion"].int == 3 ? [] : [0])
            case Command.equalizer:sample = try await readRequest(0x0218)
            case Command.spatial:sample = try await readRequest(0x0239)
            case Command.wear:sample = try await readRequest(0x020D)
            case Command.firmware:sample = try await readRequest(0x021C)
            case Command.hosts:sample = try await readRequest(0x0249)
            case Command.switches:
                if model.function["wearDetection"].enabled { _ = try? await readRequest(0x0203) }
                if model.supportsGame { _ = try? await readRequest(0x0251) }
                if model.function["hearingProtection"].enabled { _ = try? await readRequest(0x0252) }
            default:throw ProtocolError.unsupported
            }
        case .huawei:
            switch command {
            case Command.battery:sample = try await readRequest(0x0108,payload:[1,0,2,0,3,0])
            case Command.noise:sample = try await readRequest(0x2B2A,payload:[1,0])
            case Command.equalizer,Command.customEQ:sample = try await readRequest(0x2B4A,payload:(UInt8(1)...8).flatMap { [$0,0] })
            case Command.switches:
                if model.function["wearDetection"].enabled { _ = try? await readRequest(0x2B11,payload:[1,0]) }
                if model.supportsGame { _ = try? await readRequest(0x2B6C,payload:[2,0]) }
                if model.hasMultiDevice { _ = try? await readRequest(0x2B2F,payload:[1,0]) }
            case Command.hosts:
                try await collectHuaweiHosts();sample.hosts=state.hosts;sample.priorityAddress=state.priorityAddress;sample.observedQueries.insert(Command.hosts)
            default:throw ProtocolError.unsupported
            }
        case .edifier:sample = try await readRequest(command == Command.battery ? 0xD0 : 0xCC)
        case .xiaomi:
            // DeviceInfo request: [0,0,0,1<<7] asks for the battery mask only.
            // The reply data is [length=4][mask=7][left][right][case].
            if command == Command.battery {
                if xiaomiMMA {
                    sample = try await readRequest(2,payload:[0,0,0,0x80],sequence:0x0B,accepts:{$0.command == 2 && $0.sequence == 0x0B})
                } else {
                    sample = try await readRequest(2,payload:[255,255,255,255],sequence:0x0B,accepts:{$0.sequence == 0x0B && $0.payload.starts(with:[2,2,4,7])})
                }
            } else if xiaomiMMA,command == Command.noise {
                let seq=nextSequence()
                sample = try await readRequest(0xF3,payload:[0x00,0x0B],sequence:seq,accepts:{$0.command == 0xF3 && $0.sequence == seq})
            } else if xiaomiMMA,command == Command.equalizer {
                let seq=nextSequence()
                sample = try await readRequest(0xF3,payload:[0x00,0x07],sequence:seq,accepts:{$0.command == 0xF3 && $0.sequence == seq})
            } else if xiaomiMMA,command == Command.gestures {
                let seq=nextSequence()
                sample = try await readRequest(0xF3,payload:[0x00,0x02],sequence:seq,accepts:{$0.command == 0xF3 && $0.sequence == seq})
            } else if xiaomiMMA,command == Command.wear {
                let seq=nextSequence()
                sample = try await readRequest(0xF3,payload:[0x00,0x0C],sequence:seq,accepts:{$0.command == 0xF3 && $0.sequence == seq})
            } else if command == Command.switches {
                let seq=nextSequence()
                if xiaomiMMA {
                    sample = try await readRequest(0xF3,payload:[0x00,0x2F],sequence:seq,accepts:{$0.command == 0xF3 && $0.sequence == seq})
                } else {
                    sample = try await readRequest(0xF3,payload:[2,0,47],sequence:seq,accepts:{$0.command == 0xF3 && $0.sequence == seq && $0.payload.starts(with:[3,0,47])})
                }
            } else { throw ProtocolError.unsupported }
        default:throw ProtocolError.unsupported
        }
        guard sample.observedQueries.contains(command) || command == Command.switches else { throw ProtocolError.invalidPayload }
        return sample
    }
    private func readRequest(_ command:UInt16,payload:[UInt8]=[],sequence:UInt8=0,accepts:((BrandFrame)->Bool)?=nil) async throws -> DeviceState {
        let frame=try await request(command,payload:payload,sequence:sequence,accepts:accepts)
        var sample=DeviceState()
        guard BrandState.apply(frame,model:model,to:&sample) else { throw ProtocolError.invalidPayload }
        return sample
    }
    private func nextSequence() -> UInt8 { let s=sequence;sequence=sequence == 255 ? 0x90 : sequence+1;return s }
    private func request(_ command:UInt16,payload:[UInt8]=[],sequence:UInt8=0,timeout:Double=2,accepts:((BrandFrame)->Bool)?=nil) async throws -> BrandFrame {
        let token=generation
        try await gate.acquire();defer { gate.release() }
        try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
        let exchange=AsyncExchange<BrandFrame>()
        let bytes=try codec.encode(BrandFrame(command,payload,sequence:sequence))
        let expected=family == .vivo ? command | 0x8000 : command
        pending=Pending(accepts:accepts ?? { $0.command == expected },exchange:exchange)
        defer { if pending?.exchange === exchange { pending=nil } }
        return try await exchange.run(timeout:timeout,timeoutError:ProtocolError.timeout(command),abortSend:{ [weak self] in
            self?.close();self?.onClose?("Bluetooth write did not complete")
        },send:{ [transport] in try await transport.send(bytes) })
    }
    private func send(_ command:UInt16,payload:[UInt8]=[],sequence:UInt8=0,kind:UInt8=0xC4) async throws {
        let token=generation
        try await gate.acquire();defer { gate.release() };try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
        try await transport.send(try codec.encode(BrandFrame(command,payload,sequence:sequence,kind:kind)))
        try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
    }
    private func receive(_ data:Data) {
        for frame in codec.feed(data) {
            onDiagnostic?(String(format:"%@ RX %04X, %d bytes",family.rawValue,frame.command,frame.payload.count))
            if family == .huawei,frame.command == 0x2B31,collectingHosts,let row=BrandState.huaweiHost(frame.payload) {
                huaweiExpected=row.count
                if let host=row.host { huaweiRows[row.index]=host }
            } else {
                if family == .vivo,frame.command == 0x8239,frame.payload.count >= 3 { spatialScene=frame.payload[2] }
                _ = BrandState.apply(frame,model:model,to:&state)
                if family == .vivo,frame.command == 0x8249 {
                    state.hosts=state.hosts.map { host in var value=host;if value.address == localHostAddress { value.flags |= 1 };return value }
                }
            }
            if let p=pending,p.accepts(frame) {
                if family == .vivo,let status=frame.payload.first,status != 0 { p.exchange.receive(.failure(ProtocolError.rejected(status))) }
                else { p.exchange.receive(.success(frame)) }
            }
            if family == .vivo,frame.command == 0x8509 {
                let c=Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second],from:Date())
                let year=c.year ?? 0
                let payload=[year/100,year%100,c.month ?? 1,c.day ?? 1,c.hour ?? 0,c.minute ?? 0,c.second ?? 0].map { UInt8(clamping:$0) }
                Task { [weak self] in try? await self?.send(0x0509,payload:payload) }
            }
            onChange?()
        }
    }
    private func collectHuaweiHosts() async throws {
        let token=generation
        try await gate.acquire();defer { gate.release() }
        try Task.checkCancellation()
        guard generation == token else { throw ProtocolError.disconnected }
        huaweiRows=[:];huaweiExpected=nil;collectingHosts=true
        defer { collectingHosts=false }
        try await transport.send(try codec.encode(BrandFrame(0x2B31,[1,0])))
        let until=Date().addingTimeInterval(2)
        while Date() < until {
            try Task.checkCancellation();guard generation == token else { throw ProtocolError.disconnected }
            if let count=huaweiExpected,huaweiRows.count == count {
                let hosts=huaweiRows.sorted { $0.key < $1.key }.map(\.value)
                guard Set(hosts.map(\.id)).count == hosts.count else { throw ProtocolError.invalidPayload }
                state.hosts=hosts.map { host in var value=host;if value.address == localHostAddress { value.flags |= 1 };return value };state.priorityAddress=hosts.first(where:{$0.preferred})?.address
                // Huawei does not report an automatic-priority switch.
                state.observedQueries.insert(Command.hosts);onChange?();return
            }
            try await Task.sleep(for:.milliseconds(30))
        }
        throw ProtocolError.timeout(0x2B31)
    }
    private func confirmedWrite(command:UInt16,payload:[UInt8],read:UInt16,matches:(DeviceState)->Bool) async throws -> WriteOutcome {
        let token=generation
        // These brand SET ACKs are not proof of applied state. Always query after sending.
        try await send(command,payload:payload)
        try await Task.sleep(for:.milliseconds(family == .vivo && command == 0x0130 ? 2600 : 250))
        let until=Date().addingTimeInterval(3)
        repeat {
            try Task.checkCancellation();guard ready,generation == token else { throw ProtocolError.disconnected }
            let sample:DeviceState
            if read == Command.switches && family != .xiaomi {
                let query:UInt16
                switch command {
                case 0x0103:query=0x0203
                case 0x0151:query=0x0251
                case 0x0152:query=0x0252
                case 0x2B10:query=0x2B11
                case 0x2B6C:query=0x2B6C
                case 0x2B2E:query=0x2B2F
                default:throw ProtocolError.unsupported
                }
                sample = try await readRequest(query,payload:family == .huawei ? [query == 0x2B6C ? 2 : 1,0] : [])
            } else { sample = try await self.read(read) }
            try Task.checkCancellation()
            guard ready,generation == token else { throw ProtocolError.disconnected }
            guard sample.observedQueries.contains(read) else { throw ProtocolError.invalidPayload }
            if matches(sample) { return .confirmed }
            try await Task.sleep(for:.milliseconds(250))
        } while Date() < until
        throw ProtocolError.readbackMismatch
    }
    private func readXiaomiFlag(_ id: UInt16) async throws {
        let seq=nextSequence()
        _ = try await readRequest(0xF3,payload:[UInt8(id>>8),UInt8(id&0xFF)],sequence:seq,accepts:{$0.command == 0xF3 && $0.sequence == seq})
    }
    private func xiaomiSetFlag(_ id: UInt16,switchID: UInt8,enabled: Bool) async throws -> WriteOutcome {
        let seq=nextSequence()
        try await send(0xF2,payload:[0x03,UInt8(id>>8),UInt8(id&0xFF),enabled ? 1 : 0],sequence:seq)
        let token=generation
        let until=Date().addingTimeInterval(3)
        repeat {
            try Task.checkCancellation()
            guard ready,generation == token else { throw ProtocolError.disconnected }
            try await readXiaomiFlag(id)
            if state.switches[switchID] == enabled { return .confirmed }
            try await Task.sleep(for:.milliseconds(250))
        } while Date() < until
        throw ProtocolError.readbackMismatch
    }
    func setNoise(_ mode:NoiseMode) async throws -> WriteOutcome {
        guard canWrite(Command.setNoise,reading:Command.noise),let option=model.noiseOptions.first(where:{$0.mode == mode}) else { throw ProtocolError.unsupported }
        switch family {
        case .vivo:return try await confirmedWrite(command:0x0130,payload:option.writeBytes+model.raw["noiseSuffix"].elements.compactMap { $0.int.flatMap(UInt8.init(exactly:)) },read:Command.noise) { $0.noise == mode }
        case .huawei:
            if model.raw["route"].text == "FreeBuds3" { try await send(0x2B04,payload:[1,1,mode == .off ? 0 : 1]);return .sent }
            return try await confirmedWrite(command:0x2B04,payload:[1,2]+option.writeBytes,read:Command.noise) { $0.noise == mode || (mode == .anc && $0.noise?.group == .anc) }
        case .edifier:return try await confirmedWrite(command:0xC1,payload:option.writeBytes,read:Command.noise) { $0.noise == mode }
        case .xiaomi:
            guard option.writeBytes.count == 2 else { throw ProtocolError.unsupported }
            let seq=nextSequence()
            try await send(0xF2,payload:[0x04,0x00,0x0B,option.writeBytes[0],option.writeBytes[1]],sequence:seq)
            let token=generation
            let until=Date().addingTimeInterval(3)
            repeat {
                try Task.checkCancellation()
                guard ready,generation == token else { throw ProtocolError.disconnected }
                let sample=try await read(Command.noise)
                if sample.noise == mode { return .confirmed }
                try await Task.sleep(for:.milliseconds(250))
            } while Date() < until
            throw ProtocolError.readbackMismatch
        default:throw ProtocolError.unsupported
        }
    }
    func setEQ(_ id:UInt8) async throws -> WriteOutcome {
        guard canWrite(Command.setEQ,reading:Command.equalizer),model.presets.contains(where:{$0.id == id}) || state.customEQ.contains(where:{$0.id == id}) else { throw ProtocolError.unsupported }
        if family == .xiaomi {
            guard model.presets.contains(where:{$0.id == id}) else { throw ProtocolError.unsupported }
            let seq=nextSequence()
            try await send(0xF2,payload:[0x03,0x00,0x07,id],sequence:seq)
            let token=generation
            let until=Date().addingTimeInterval(3)
            repeat {
                try Task.checkCancellation()
                guard ready,generation == token else { throw ProtocolError.disconnected }
                let sample=try await read(Command.equalizer)
                if sample.eq == id { return .confirmed }
                try await Task.sleep(for:.milliseconds(250))
            } while Date() < until
            throw ProtocolError.readbackMismatch
        }
        return try await confirmedWrite(command:family == .vivo ? 0x0118 : 0x2B49,payload:family == .vivo ? [id] : [1,1,id],read:Command.equalizer) { $0.eq == id }
    }
    func setSpatial(_ value:UInt8) async throws -> WriteOutcome {
        guard canWrite(Command.setSpatial,reading:Command.spatial),model.spatialModes.contains(value),family == .vivo else { throw ProtocolError.unsupported }
        return try await confirmedWrite(command:0x0139,payload:[value]+(spatialScene.map { [$0] } ?? []),read:Command.spatial) { $0.spatial == value }
    }
    func gestureActions(_ entry:GestureEntry) -> [UInt8] {
        guard family == .xiaomi,entry.mode == 1 else { return [] }
        switch entry.gesture {
        case 1,2,3:return [8,1,2,3,4,5,9]
        case 4:return [8,0,6]
        case 5:return [8,0x0B]
        default:return []
        }
    }
    func setGesture(_ entry:GestureEntry,action:UInt8) async throws -> WriteOutcome {
        guard canWrite(Command.setGestures,reading:Command.gestures),gestureActions(entry).contains(action) else { throw ProtocolError.unsupported }
        // The SET payload replaces the whole gesture table, so it is rebuilt from
        // the last read. Sides the device reported as unassigned (0xFF) are sent
        // back unchanged instead of being rewritten as "no action".
        let mapping:[UInt8:UInt8]=[1:4,2:1,3:2,4:3,5:5]
        var byType:[UInt8:(left:UInt8,right:UInt8)]=[:]
        for gesture in state.gestures {
            guard let type=mapping[gesture.gesture] else { continue }
            var pair=byType[type] ?? (0xFF,0xFF)
            let value=gesture.id == entry.id ? action : gesture.action
            if gesture.side == 1 { pair.left=value } else if gesture.side == 2 { pair.right=value }
            byType[type]=pair
        }
        let types=byType.keys.sorted()
        guard !types.isEmpty else { throw ProtocolError.unsupported }
        var value:[UInt8]=[]
        for type in types { let pair=byType[type]!;value += [type,pair.left,pair.right] }
        let seq=nextSequence()
        try await send(0xF2,payload:[UInt8(value.count+2),0x00,0x02]+value,sequence:seq)
        let token=generation
        let until=Date().addingTimeInterval(3)
        repeat {
            try Task.checkCancellation()
            guard ready,generation == token else { throw ProtocolError.disconnected }
            let sample=try await read(Command.gestures)
            if sample.gestures.contains(where:{$0.id == entry.id && $0.action == action}) { return .confirmed }
            try await Task.sleep(for:.milliseconds(250))
        } while Date() < until
        throw ProtocolError.readbackMismatch
    }
    func setFeature(_ feature:FeatureDefinition,enabled:Bool) async throws -> WriteOutcome {
        guard canSetFeature(feature) else { throw ProtocolError.unsupported }
        if family == .xiaomi {
            // Legacy family keeps the original config-47 game/low-latency write.
            if feature.key == "game" {
                let seq=nextSequence();try await send(0xF2,payload:[3,0,47,enabled ? 1 : 0],sequence:seq)
                let token=generation
                let sample=try await read(Command.switches)
                try Task.checkCancellation()
                guard ready,generation == token else { throw ProtocolError.disconnected }
                guard sample.switches[6] == enabled else { throw ProtocolError.readbackMismatch };return .confirmed
            }
            guard xiaomiMMA else { throw ProtocolError.unsupported }
            switch feature.key {
            case "dual": return try await xiaomiSetFlag(0x0004,switchID:0x11,enabled:enabled)
            case "autoAnswer": return try await xiaomiSetFlag(0x0003,switchID:0x12,enabled:enabled)
            case "spatialSound":
                let raw=state.spatial ?? 0
                let next=enabled ? (raw | 1) : (raw & 0xFE)
                let seq=nextSequence()
                try await send(0xF2,payload:[0x03,0x00,0x1D,next],sequence:seq)
                let token=generation
                let until=Date().addingTimeInterval(3)
                repeat {
                    try Task.checkCancellation()
                    guard ready,generation == token else { throw ProtocolError.disconnected }
                    try await readXiaomiFlag(0x001E)
                    if state.switches[0x1B] == enabled { return .confirmed }
                    try await Task.sleep(for:.milliseconds(250))
                } while Date() < until
                throw ProtocolError.readbackMismatch
            default:throw ProtocolError.unsupported
            }
        }
        let command:UInt16
        switch (family,feature.key) {
        case (.vivo,"wear"):command=0x0103
        case (.vivo,"game"):command=0x0151
        case (.vivo,"hearingProtection"):command=0x0152
        case (.huawei,"wear"):command=0x2B10
        case (.huawei,"game"):command=0x2B6C
        case (.huawei,"dual"):command=0x2B2E
        default:throw ProtocolError.unsupported
        }
        return try await confirmedWrite(command:command,payload:(family == .huawei ? [1,1] : [])+[enabled ? 1 : 0],read:Command.switches) { $0.switches[feature.switchID] == enabled }
    }
    func saveEQ(_ entry:CustomEQEntry) async throws -> WriteOutcome {
        guard family == .huawei,canWrite(Command.setCustomEQ,reading:Command.customEQ),entry.frequencies == model.customEQFrequencies,entry.gains.count == 10,entry.gains.allSatisfy({(-60...60).contains($0)}),FeatureCodec.validEQName(entry.name),entry.name.utf8.count <= 32 else { throw ProtocolError.unsupported }
        let id:UInt8
        if entry.id == 0 { guard let free=(UInt8(0x64)...0x66).first(where:{id in !state.customEQ.contains(where:{$0.id == id})}) else { throw ProtocolError.unsupported };id=free }
        else { guard (0x64...0x66).contains(entry.id) else { throw ProtocolError.unsupported };id=entry.id }
        let name=Array(entry.name.utf8),route=model.raw["route"].text ?? ""
        let op:UInt8=["FreeBuds6I","FreeBudsPro5","FreeArc"].contains(route) ? 1 : 0
        let payload=[1,1,id,2,1,10,5,1,op,3,10]+entry.gains.map { UInt8(bitPattern:$0) }+[4,UInt8(name.count)]+name
        return try await confirmedWrite(command:0x2B49,payload:payload,read:Command.customEQ) { $0.customEQ.contains { $0.id == id && $0.name == entry.name && $0.gains == entry.gains } }
    }
    func canOperateHost(_ operation:FeatureCodec.HostOperation,host:RemoteHost?) -> Bool {
        guard canWrite(Command.operateHost,reading:Command.hosts),operation != .automatic,let host,let latest=state.hosts.first(where:{$0.id == host.id}),!latest.current,let local=localHostAddress,latest.address != local else { return false }
        if operation == .connect { return !latest.connected }
        if operation == .disconnect { return latest.connected }
        return operation == .priority && family == .huawei && latest.connected
    }
    func operateHost(_ operation:FeatureCodec.HostOperation,host:RemoteHost?) async throws -> WriteOutcome {
        guard canOperateHost(operation,host:host),let host else { throw ProtocolError.unsupported }
        let command:UInt16,payload:[UInt8]
        if family == .vivo {
            command=0x014A;payload=state.hosts.flatMap { Array($0.address.reversed())+[$0.id == host.id ? (operation == .disconnect ? UInt8(0) : 2) : $0.connection] }
        } else if family == .huawei {
            command=operation == .priority ? 0x2B32 : 0x2B33
            payload=[operation == .priority || operation == .connect ? 1 : 2,6]+host.address
        } else { throw ProtocolError.unsupported }
        return try await confirmedWrite(command:command,payload:payload,read:Command.hosts) { sample in
            if operation == .priority { return sample.priorityAddress == host.address }
            let connected=sample.hosts.first(where:{$0.id == host.id})?.connected ?? false
            return operation == .connect ? connected : !connected
        }
    }
    func find(_ enabled:Bool) async throws -> WriteOutcome {
        guard canWrite(Command.find,reading:nil) else { throw ProtocolError.unsupported }
        if family == .xiaomi {
            let seq=nextSequence()
            let positions:UInt8=enabled ? 0x03 : 0x00
            try await send(0xF2,payload:[0x04,0x00,0x09,enabled ? 1 : 0,positions],sequence:seq)
            let token=generation
            let until=Date().addingTimeInterval(3)
            repeat {
                try Task.checkCancellation()
                guard ready,generation == token else { throw ProtocolError.disconnected }
                try await readXiaomiFlag(0x0009)
                if state.finding == enabled { return .confirmed }
                try await Task.sleep(for:.milliseconds(250))
            } while Date() < until
            throw ProtocolError.readbackMismatch
        }
        try await send(0x0120,payload:[enabled ? 1 : 0]);return .sent
    }
    func setModelOverride(_ id:String?) {
        guard let new=catalog.model(productID:state.productID,name:name,override:id),new.family == family else { return }
        model=new
        codec=BrandFrameCodec(family:family,gaiaVersion:UInt8(new.raw["gaiaVersion"].int ?? 4),xiaomiMMA:new.isXiaomiMMA);onChange?()
    }
    func close() {
        generation=UUID();ready=false;poll?.cancel();poll=nil
        pending?.exchange.cancel();pending=nil
        collectingHosts=false;codec=BrandFrameCodec(family:family,gaiaVersion:UInt8(model.raw["gaiaVersion"].int ?? 4),xiaomiMMA:model.isXiaomiMMA);transport.onEvent=nil;transport.close();state=DeviceState();onChange?()
    }
}
