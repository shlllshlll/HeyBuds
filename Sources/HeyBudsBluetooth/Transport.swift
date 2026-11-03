import Foundation
import IOBluetooth
import CoreBluetooth
import HeyBudsProtocol

public enum TransportEvent { case data(Data), closed(String?) }
public enum TransportFailure: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let reason)=self { return reason }; return nil }
}
@MainActor public protocol EarbudTransport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    var label: String { get }
    func open() async throws
    func send(_ bytes: Data) async throws
    func close()
}
public struct DeviceCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let audioConnected: Bool
    public let classicAddress: String?
    public let family: EarbudFamily?
    public let controlServiceUUID:String?
    public init(id: String, name: String, audioConnected: Bool, classicAddress: String?, family:EarbudFamily?=nil,controlServiceUUID:String?=nil) {
        self.id=id; self.name=name; self.audioConnected=audioConnected; self.classicAddress=classicAddress;self.family=family;self.controlServiceUUID=controlServiceUUID
    }
}
@MainActor public enum Discovery {
    public static let service = "0000079A-D102-11E1-9B23-00025B00A5A5"
    public static let write = "0100079A-D102-11E1-9B23-00025B00A5A5"
    public static let notify = "0200079A-D102-11E1-9B23-00025B00A5A5"
    public nonisolated static func uuid(_ string:String="0000079A-D102-11E1-9B23-00025B00A5A5") -> IOBluetoothSDPUUID {
        var value=UUID(uuidString:string)!.uuid
        let bytes=withUnsafeBytes(of:&value) { Array($0) }
        return IOBluetoothSDPUUID(bytes:bytes,length:16)
    }
    /// A2DP Sink and Hands-Free: the two profiles an earbud exposes as the audio
    /// receiver. Phones expose the source/AG side instead, which is not evidence.
    public nonisolated static let audioSinkServices=["0000110B-0000-1000-8000-00805F9B34FB",
                                         "0000111E-0000-1000-8000-00805F9B34FB"]
    /// Three-state identity decision for a paired device.
    /// A known Audio/Video class is enough; a class that names a computer, phone
    /// or peripheral never is. The cached class is often 0 for Bluetooth LE
    /// peripherals, so an unknown class falls back to the audio sink records:
    /// a mouse, keyboard or iPad has none, an earbud normally does. The result is
    /// only a first pass — the app can add back or hide any device by hand.
    public nonisolated static func admits(classOfDevice:UInt32,hasAudioSink:Bool) -> Bool {
        switch (classOfDevice >> 8) & 0x1F {
        case 0x04: return true
        case 0x00, 0x1F: return hasAudioSink
        default: return false
        }
    }
    public struct Result: Sendable, Equatable {
        public let admitted:[DeviceCandidate]
        /// Paired devices with a detectable protocol family that failed the
        /// identity check. They are the candidates a manual override can add back.
        public let rejected:[DeviceCandidate]
        public init(admitted:[DeviceCandidate]=[],rejected:[DeviceCandidate]=[]) {
            self.admitted=admitted; self.rejected=rejected
        }
    }
    public static func pairedDevices(catalog:ModelCatalog?=nil) async -> Result {
        // IOBluetooth may wait for its CoreBluetooth coordinator to initialize.
        // Keep that synchronous wait off the main actor so AppKit remains responsive.
        await Task.detached(priority:.utility) {
            let catalog=catalog ?? (try? ModelCatalog())
            var admitted:[DeviceCandidate]=[], rejected:[DeviceCandidate]=[]
            for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []) {
                let name=device.name ?? "Earbuds"
                guard let address=device.addressString else { continue }
                let services=Set(EarbudFamily.allCases.filter { family in
                    family != .huawei && family.classicServiceUUIDs.contains { device.getServiceRecord(for:uuid($0)) != nil }
                })
                // A device with no recognizable control family cannot be driven at
                // all, so it is neither a candidate nor a manual choice.
                guard let family=catalog?.routingFamily(name:name,services:services) else { continue }
                let available=family.classicServiceUUIDs.filter { device.getServiceRecord(for:uuid($0)) != nil }
                let preferred=family.serviceUUID(for:name)
                let service=preferred.flatMap { available.contains($0) ? $0 : nil } ?? (available.count == 1 ? available.first : nil)
                let sink=audioSinkServices.contains { device.getServiceRecord(for:uuid($0)) != nil }
                let candidate=DeviceCandidate(id:address,name:name,audioConnected:device.isConnected(),classicAddress:address,family:family,controlServiceUUID:service)
                if admits(classOfDevice:device.classOfDevice,hasAudioSink:sink) { admitted.append(candidate) }
                else { rejected.append(candidate) }
            }
            return Result(admitted:admitted.sorted { $0.audioConnected == $1.audioConnected ? $0.name < $1.name : $0.audioConnected },
                          rejected:rejected.sorted { $0.name < $1.name })
        }.value
    }
    /// Automatic candidates only. Manual overrides are applied by the app.
    public static func paired(catalog:ModelCatalog?=nil) async -> [DeviceCandidate] {
        await pairedDevices(catalog:catalog).admitted
    }
}
