import Foundation
import Network
import Observation

/// 目前有沒有網路（斷網時顯示中文提示，不讓請求一直失敗）
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    /// 行動網路（或熱點）
    private(set) var isExpensive = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.usesInterfaceType(.cellular)
            Task { @MainActor in
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
                if self.isExpensive != expensive { self.isExpensive = expensive }
            }
        }
        monitor.start(queue: DispatchQueue(label: "DrivePlayer.NetworkMonitor"))
    }
}
