import Foundation
import IOBluetooth
import CoreBluetooth
import HeyBudsProtocol

public enum TransportEvent { case data(Data), closed(String?) }
public enum TransportFailure: Error, LocalizedError, Equatable {
    case unavailable(String)
    /// A control-channel open did not finish in time. Kept distinct from
    /// `unavailable` so callers can describe the usual causes instead of
    /// matching an English message.
    case timedOut
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):return reason
        case .timedOut:return "Control service connection timed out"
        }
    }
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
    public let controlServiceUUIDs:[String]
    public var controlServiceUUID:String? { controlServiceUUIDs.first }
    public init(id: String, name: String, audioConnected: Bool, classicAddress: String?, family:EarbudFamily?=nil,controlServiceUUIDs:[String]=[]) {
        self.id=id; self.name=name; self.audioConnected=audioConnected; self.classicAddress=classicAddress;self.family=family;self.controlServiceUUIDs=controlServiceUUIDs
    }
    /// Source-compatible single-service initializer for callers outside the app.
    public init(id: String, name: String, audioConnected: Bool, classicAddress: String?, family:EarbudFamily?=nil,controlServiceUUID:String?) {
        self.init(id:id,name:name,audioConnected:audioConnected,classicAddress:classicAddress,family:family,controlServiceUUIDs:controlServiceUUID.map { [$0] } ?? [])
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
    public static func paired(catalog:ModelCatalog?=nil) async -> [DeviceCandidate] {
        // IOBluetooth may wait for its CoreBluetooth coordinator to initialize.
        // Keep that synchronous wait off the main actor so AppKit remains responsive.
        await Task.detached(priority:.utility) {
            let catalog=catalog ?? (try? ModelCatalog())
            return (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device in
                let name=device.name ?? "Earbuds"
                guard let address=device.addressString else { return nil }
                let services=Set(EarbudFamily.allCases.filter { family in
                    family != .huawei && family.classicServiceUUIDs.contains { device.getServiceRecord(for:uuid($0)) != nil }
                })
                let family=catalog?.routingFamily(name:name,services:services)
                guard let family else { return nil }
                let mma=catalog?.model(productID:nil,name:name,override:nil)?.isXiaomiMMA == true
                // Probe the family-wide cache so the original single-service
                // fallback still applies to Sony and the other families. The MMA
                // profile reports every documented route instead: the channel and
                // its fallback are resolved again from SDP when it opens.
                let cached=family.classicServiceUUIDs.filter { device.getServiceRecord(for:uuid($0)) != nil }
                let service=family.resolvedControlServiceUUIDs(for:name,available:cached,xiaomiMMA:mma)
                return DeviceCandidate(id:address,name:name,audioConnected:device.isConnected(),classicAddress:address,family:family,controlServiceUUIDs:service)
            }.sorted { $0.audioConnected == $1.audioConnected ? $0.name < $1.name : $0.audioConnected }
        }.value
    }
}
