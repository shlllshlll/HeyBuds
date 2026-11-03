import AppKit
import IOBluetooth
import HeyBudsBluetooth
import HeyBudsProtocol

/// System boundaries are injectable so lifecycle tests never discover or open radios.
@MainActor struct AppServices {
    var discover:(ModelCatalog) async -> Discovery.Result = { await Discovery.pairedDevices(catalog:$0) }
    var monitor:BluetoothConnectionMonitor? = BluetoothConnectionMonitor()
    var makeSession:(DeviceCandidate,EarbudFamily,String,String?,ModelCatalog) throws -> DeviceSession = { device,family,kind,override,catalog in
        guard family.transportKinds(for:device.name).contains(kind) else { throw ProtocolError.unsupported }
        let transport:EarbudTransport
        if kind == "RFCOMM",let address=device.classicAddress {
            // The candidate's routes are resolved from the advertised name. When the
            // model (or a manual override) selects the MMA profile, offer both
            // documented routes so the codec and the transport never disagree.
            let mma=catalog.model(productID:nil,name:device.name,override:override)?.isXiaomiMMA == true
            let services = mma
                ? family.controlServiceUUIDs(for:device.name,xiaomiMMA:true)
                : (device.controlServiceUUIDs.isEmpty ? family.controlServiceUUIDs(for:device.name) : device.controlServiceUUIDs)
            guard !services.isEmpty else { throw ProtocolError.unsupported }
            transport=try RFCOMMTransport(address:address,serviceUUIDs:services)
        } else if kind == "BLE",family == .oppo { transport=BLETransport(name:device.name) }
        else if kind == "BLE",family == .bose,BoseProfile.named(device.name)?.prefersBLE == true { transport=BLETransport(name:device.name,profile:.bose) }
        else { throw ProtocolError.unsupported }
        let local=IOBluetoothHostController.default()?.addressAsString().split(whereSeparator:{$0 == ":" || $0 == "-"}).compactMap { UInt8($0,radix:16) }
        return DeviceSession(transport:transport,name:device.name,catalog:catalog,overrideID:override,family:family,localHostAddress:local)
    }
    var openAudio:(String) async -> Void = { address in
        _ = await Task.detached { IOBluetoothDevice(addressString:address)?.openConnection() }.value
    }
    var closeAudio:(String) async -> Void = { address in
        _ = await Task.detached { IOBluetoothDevice(addressString:address)?.closeConnection() }.value
    }
    var hasCompetitor:() -> Bool = {
        ["local.buds.menubar","com.aniketbudhwani.budsbar"].contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier:$0).isEmpty
        }
    }
    var delay:(Duration) async throws -> Void = { try await Task.sleep(for:$0) }
}
