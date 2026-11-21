import Foundation
import Observation

/// App 共用的服務，從 DrivePlayerApp 注入 environment。
@MainActor
@Observable
final class AppServices {
    let auth: GoogleAuthService
    let drive: DriveClient

    init() {
        let auth = GoogleAuthService()
        self.auth = auth
        drive = DriveClient(tokens: auth.tokens)
    }
}
