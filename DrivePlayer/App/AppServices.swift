import Foundation
import Observation

/// App 共用的服務，從 DrivePlayerApp 注入 environment。
@MainActor
@Observable
final class AppServices {
    let auth: GoogleAuthService
    let drive: DriveClient
    let proxy: LocalStreamProxy
    let player: PlayerController

    init() {
        let auth = GoogleAuthService()
        self.auth = auth
        let tokens = auth.tokens!
        drive = DriveClient(tokens: tokens)
        proxy = LocalStreamProxy { force in try await tokens.token(forceRefresh: force) }
        player = PlayerController(proxy: proxy)
    }

    /// App 回到前景：代理被系統關掉的話重開
    func didBecomeActive() {
        let proxy = proxy
        Task { try? await proxy.ensureRunning() }
    }

    func didEnterBackground() {
        player.appDidEnterBackground()
    }
}
