import SwiftUI
import HeyBudsBluetooth

/// Manual fallback for the automatic device filter. The identity check is a
/// heuristic, so a rejected earbud can be added back and a misdetected device
/// can be hidden; both choices are persisted by `AppModel`.
struct ManualDeviceSheet: View {
    @Bindable var app:AppModel
    @Environment(\.dismiss) private var dismiss

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(L("手动选择设备","Choose devices")).font(.system(size:14,weight:.semibold))
                Spacer()
                Button(L("完成","Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(L("列表按蓝牙类型自动筛选。被误判的耳机可以加回来，误识别的设备可以隐藏；选择会被记住。",
                   "The list is filtered by Bluetooth type. Add back an earbud that was misjudged, or hide a device that was misdetected; choices are remembered."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    section(L("已显示","Shown"),devices:app.candidates,visible:true)
                    section(L("未显示","Hidden"),devices:app.hiddenDevices,visible:false)
                }.padding(.vertical,2)
            }
            .frame(maxHeight:300)
        }
        .padding(16)
        .frame(width:380)
    }
    @ViewBuilder private func section(_ title:String,devices:[DeviceCandidate],visible:Bool) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
            if devices.isEmpty {
                Text(visible ? L("没有可用的设备","No devices") : L("没有被过滤的设备","Nothing was filtered"))
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(devices) { device in row(device,visible:visible) }
            }
        }
    }
    private func row(_ device:DeviceCandidate,visible:Bool) -> some View {
        HStack(spacing:8) {
            VStack(alignment:.leading,spacing:1) {
                HStack(spacing:6) {
                    Text(device.name).font(.system(size:12)).lineLimit(1).truncationMode(.middle)
                    if visible ? app.isManuallyVisible(device.id) : app.isManuallyHidden(device.id) {
                        Text(L("手动","Manual"))
                            .font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal,4).padding(.vertical,1)
                            .background(.quaternary,in:Capsule())
                    }
                }
                if let address=device.classicAddress {
                    Text(address).font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength:6)
            Button { app.setManualVisibility(device.id,visible:!visible) } label: {
                Text(visible ? L("隐藏","Hide") : L("显示","Show")).font(.system(size:11))
            }
            .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal,9).padding(.vertical,6)
        .background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:9))
    }
}
