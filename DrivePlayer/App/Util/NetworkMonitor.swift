import Foundation
import Network
import Observation

/// 目前有沒有網路（斷網時顯示中文提示，不讓請求一直失敗）
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "DrivePlayer.NetworkMonitor"))
    }
}
