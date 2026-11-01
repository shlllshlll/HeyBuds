// IOBluetooth lifecycle informed by Realme TWS Mac Controller (MIT).
// Rewritten to own asynchronous buffers through write completion and cancel sessions.
import Foundation
import IOBluetooth
import HeyBudsProtocol

@MainActor public final class RFCOMMTransport: NSObject, EarbudTransport, @preconcurrency IOBluetoothRFCOMMChannelDelegate, @preconcurrency IOBluetoothDeviceAsyncCallbacks {
    public var onEvent: ((TransportEvent) -> Void)?
    public let label="RFCOMM"
    private let device: IOBluetoothDevice
    /// Ordered SDP routes. The channel is always taken from the matching record,
    /// never guessed; if one route exists but cannot be opened the next is tried.
    public let serviceUUIDs:[String]
    public var serviceUUID:String { serviceUUIDs[0] }
    private var records:[IOBluetoothSDPServiceRecord]=[]
    private var nextRecord=0
    private var lastOpenError:Error?
    private var channel: IOBluetoothRFCOMMChannel?
    private var opening: CheckedContinuation<Void,Error>?
    private var writing: TransportWrite?
    private var writeSequence:UInt=0
    private var writeRefcon:UnsafeMutableRawPointer?
    private var writeBuffer: NSData?
    private var timeout: Task<Void,Never>?
    private var sdpPoll:Task<Void,Never>?
    private var channelOpening=false
    private var isClosing=false

    public init(address: String,serviceUUIDs:[String]) throws {
        guard !serviceUUIDs.isEmpty else { throw TransportFailure.unavailable("No control service UUID") }
        guard let device=IOBluetoothDevice(addressString:address) else { throw ProtocolError.disconnected }
        self.device=device
        self.serviceUUIDs=serviceUUIDs
        super.init()
    }
    public convenience init(address: String,serviceUUID:String="0000079A-D102-11E1-9B23-00025B00A5A5") throws {
        try self.init(address:address,serviceUUIDs:[serviceUUID])
    }
    public func open() async throws {
        guard opening == nil, channel == nil else { throw TransportFailure.unavailable("Control channel already opening") }
        isClosing=false
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                opening=continuation
                startTimeout()
                // Cached records alone are insufficient on some firmware. Refresh using the SDK callback.
                let result=device.performSDPQuery(self)
                if result != kIOReturnSuccess { failOpen(TransportFailure.unavailable("SDP query failed (\(result))")) }
                else {
                    // Some macOS releases refresh the cache without delivering the SDP
                    // callback. Match the same service UUIDs in that cache, never a bare port.
                    sdpPoll=Task { [weak self] in
                        for _ in 0..<40 {
                            try? await Task.sleep(for:.milliseconds(50))
                            guard !Task.isCancelled, let self, self.opening != nil, !self.isClosing, !self.channelOpening else { return }
                            if self.resolveRecords() { self.openNextRecord(); return }
                        }
                    }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.close() } })
    }
    @objc public func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard opening != nil, !isClosing, !channelOpening else { return }
        // A failed refresh can still leave a usable cached record, so inspect both.
        if resolveRecords() { openNextRecord(); return }
        failOpen(TransportFailure.unavailable(status == kIOReturnSuccess ? "Earbud control service not found" : "SDP query failed (\(status))"))
    }
    @objc public func remoteNameRequestComplete(_ device:IOBluetoothDevice!,status:IOReturn) { }
    @objc public func connectionComplete(_ device:IOBluetoothDevice!,status:IOReturn) { }
    /// Resolve every known route from this device's SDP cache, preserving preference order.
    @discardableResult private func resolveRecords() -> Bool {
        var found:[IOBluetoothSDPServiceRecord]=[]
        for service in serviceUUIDs {
            guard let record=device.getServiceRecord(for:Discovery.uuid(service)) else { continue }
            if !found.contains(where:{$0 === record}) { found.append(record) }
        }
        records=found
        nextRecord=0
        return !found.isEmpty
    }
    private func openNextRecord() {
        guard !channelOpening, opening != nil, !isClosing else { return }
        guard nextRecord < records.count else {
            failOpen(lastOpenError ?? TransportFailure.unavailable("Earbud control service not found")); return
        }
        // Each documented route gets its own budget, so a route that never
        // completes cannot use up the time reserved for the next one.
        startTimeout()
        let record=records[nextRecord]; nextRecord += 1
        openRecord(record)
    }
    /// Arm (or re-arm) the per-route open timeout.
    private func startTimeout() {
        timeout?.cancel()
        timeout=Task { [weak self] in
            try? await Task.sleep(for:.seconds(10))
            guard !Task.isCancelled else { return }
            self?.openTimedOut()
        }
    }
    private func openTimedOut() {
        guard opening != nil, !isClosing else { return }
        // Retire the stalled candidate instead of failing the whole connection:
        // the remaining documented routes may still carry the control channel.
        if channelOpening || nextRecord < records.count {
            advanceAfterFailure(TransportFailure.timedOut)
        } else {
            failOpen(TransportFailure.timedOut)
        }
    }
    private func openRecord(_ record:IOBluetoothSDPServiceRecord) {
        guard !channelOpening, opening != nil, !isClosing else { return }
        channelOpening=true
        var id: BluetoothRFCOMMChannelID=0
        guard record.getRFCOMMChannelID(&id) == kIOReturnSuccess, id > 0 else {
            advanceAfterFailure(TransportFailure.unavailable("Control service has no RFCOMM channel")); return
        }
        // Channel is accepted only from this specific service record, never guessed.
        var opened: IOBluetoothRFCOMMChannel?
        let result=self.device.openRFCOMMChannelAsync(&opened,withChannelID:id,delegate:self)
        if result == kIOReturnSuccess,let opened { channel=opened }
        else { advanceAfterFailure(TransportFailure.unavailable(result == kIOReturnSuccess ? "RFCOMM open returned no channel" : "RFCOMM open failed (\(result))")) }
    }
    /// Retire a failed candidate and try the next documented route, if any.
    private func advanceAfterFailure(_ error:Error) {
        lastOpenError=error
        channel?.setDelegate(nil); channel?.close(); channel=nil
        channelOpening=false
        openNextRecord()
    }
    public func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard !isClosing, opening != nil else { channel?.close(); return }
        // A late completion from a candidate that already failed over must be
        // closed, otherwise it can hold the SPP channel for the next attempt.
        guard channel === self.channel else { channel?.close(); return }
        guard error == kIOReturnSuccess else {
            advanceAfterFailure(TransportFailure.unavailable("RFCOMM connection failed (\(error))")); return
        }
        channelOpening=false
        timeout?.cancel(); timeout=nil; sdpPoll?.cancel(); sdpPoll=nil
        self.channel=channel
        let c=opening; opening=nil; c?.resume()
    }
    private func failOpen(_ error: Error) {
        let c=opening; opening=nil; timeout?.cancel(); timeout=nil; sdpPoll?.cancel(); sdpPoll=nil; channelOpening=false
        channel?.setDelegate(nil); channel?.close(); channel=nil
        records=[]; nextRecord=0; lastOpenError=nil
        c?.resume(throwing:error)
    }
    public func send(_ bytes: Data) async throws {
        guard let channel, channel.isOpen(), !isClosing else { throw ProtocolError.disconnected }
        guard writing == nil else { throw TransportFailure.unavailable("Concurrent RFCOMM write") }
        let mtu=max(1,Int(channel.getMTU()))
        for start in stride(from:0,to:bytes.count,by:mtu) {
            try Task.checkCancellation()
            let fragment=bytes.subdata(in:start..<min(bytes.count,start+mtu)) as NSData
            let write=TransportWrite()
            writeSequence = writeSequence == UInt.max ? 1 : writeSequence+1
            let refcon=UnsafeMutableRawPointer(bitPattern:writeSequence)
            writing=write;writeBuffer=fragment;writeRefcon=refcon
            defer { if writing === write { writing=nil;writeBuffer=nil;writeRefcon=nil } }
            try await write.wait(abort:{ [weak self] error in
                self?.close();self?.onEvent?(.closed(error.localizedDescription))
            },start:{
                let result=channel.writeAsync(UnsafeMutableRawPointer(mutating:fragment.bytes),length:UInt16(fragment.length),refcon:refcon)
                if result != kIOReturnSuccess {
                    write.finish(.failure(TransportFailure.unavailable("RFCOMM write failed (\(result))")))
                }
            })
            guard !isClosing, channel === self.channel else { throw ProtocolError.disconnected }
        }
    }
    public func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        guard !isClosing,channel === self.channel,refcon == writeRefcon else { return }
        if error == kIOReturnSuccess { writing?.finish(.success(())) }
        else { writing?.finish(.failure(TransportFailure.unavailable("RFCOMM write completion failed (\(error))"))) }
    }
    public func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard !isClosing, channel === self.channel, let pointer, length > 0 else { return }
        onEvent?(.data(Data(bytes:pointer,count:length)))
    }
    public func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        guard channel === self.channel else { return }
        close(); onEvent?(.closed(nil))
    }
    public func close() {
        isClosing=true; timeout?.cancel(); timeout=nil; sdpPoll?.cancel(); sdpPoll=nil; channelOpening=false
        channel?.setDelegate(nil); channel?.close(); channel=nil
        records=[]; nextRecord=0; lastOpenError=nil
        let o=opening; opening=nil; o?.resume(throwing:ProtocolError.disconnected)
        let w=writing; writing=nil; w?.finish(.failure(ProtocolError.disconnected))
        writeBuffer=nil;writeRefcon=nil
    }
}
