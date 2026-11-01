// Xiaomi RCSP SPP routes. The vendor Android SDK (XiaomiTWS) tries the
// Fast Connect service first and falls back to the XiaoAi service.
// Channels still come from each service's own SDP record, never a fixed port.
import Foundation

public enum XiaomiProtocol {
    /// MIUI / Fast Connect SPP service. Current Xiaomi and Redmi earbuds expose this.
    public static let fastConnectService = "0000FD2D-0000-1000-8000-00805F9B34FB"
    /// XiaoAi SPP service used by XiaoAi-branded models.
    public static let xiaoAiService = "00001101-0000-1000-8000-008584D01810"
    public static let services = [fastConnectService, xiaoAiService]
}
