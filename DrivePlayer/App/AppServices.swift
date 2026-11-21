import Core
import Foundation
import Observation
import SwiftData

/// App 共用的服務，從 DrivePlayerApp 注入 environment。
@MainActor
@Observable
final class AppServices {
    let auth: GoogleAuthService
    let drive: DriveClient
    let proxy: LocalStreamProxy
    let player: PlayerController
    let library: LibraryManager
    let matcher: MetadataMatcher
    let playback: PlaybackStore
    let network = NetworkMonitor()

    enum Keys {
        static let autoPlayNext = "autoPlayNext"
        static let askBeforeResume = "askBeforeResume"
    }

    init() {
        let auth = GoogleAuthService()
        self.auth = auth
        let tokens = auth.tokens!
        let context = AppDatabase.container.mainContext
        drive = DriveClient(tokens: tokens)
        proxy = LocalStreamProxy { force in try await tokens.token(forceRefresh: force) }
        player = PlayerController(proxy: proxy)
        library = LibraryManager(context: context, drive: drive)
        matcher = MetadataMatcher(context: context, tmdb: TMDBClient(apiKey: AppConfig.tmdbAPIKey))
        playback = PlaybackStore(context: context)
        UserDefaults.standard.register(defaults: [Keys.autoPlayNext: true, Keys.askBeforeResume: false])
        wire()
    }

    private func wire() {
        library.onScanFinished = { [weak self] in self?.matcher.matchPending() }
        player.onProgress = { [weak self] request, position, duration, _ in
            self?.playback.record(fileId: request.fileId, position: position, duration: duration)
        }
        player.autoPlayNext = { UserDefaults.standard.bool(forKey: Keys.autoPlayNext) }
        player.nextProvider = { [weak self] request in
            guard let self, let item = self.item(request.fileId), let show = item.show else { return nil }
            let all = show.orderedEpisodes
            guard let i = all.firstIndex(where: { $0.fileId == item.fileId }), i + 1 < all.count else { return nil }
            return self.request(for: all[i + 1], fromBeginning: false)
        }
    }

    // MARK: - 播放

    func request(for item: MediaItem, fromBeginning: Bool) -> PlaybackRequest {
        let start = fromBeginning ? nil : playback.resumePosition(for: item.fileId)
        if item.kind == .episode {
            let showTitle = item.show?.title ?? item.title
            var subtitle = item.episodeLabel ?? ""
            if let t = item.episodeTitle, !t.isEmpty { subtitle += subtitle.isEmpty ? t : "・" + t }
            return PlaybackRequest(fileId: item.fileId, fileName: item.fileName, title: showTitle, subtitle: subtitle.isEmpty ? nil : subtitle, startAt: start)
        }
        return PlaybackRequest(fileId: item.fileId, fileName: item.fileName, title: item.title, subtitle: item.year.map(String.init), startAt: start)
    }

    func play(_ item: MediaItem, fromBeginning: Bool = false) {
        guard network.isOnline else {
            player.errorMessage = "沒有網路連線，請檢查網路後再試一次"
            return
        }
        guard auth.state == .signedIn else {
            player.errorMessage = auth.sessionExpired ? AuthError.expired.localizedDescription : AuthError.notSignedIn.localizedDescription
            return
        }
        let request = request(for: item, fromBeginning: fromBeginning)
        Task { await player.play(request) }
    }

    func item(_ fileId: String) -> MediaItem? {
        try? library.context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.fileId == fileId })).first
    }

    // MARK: - 規格

    /// 第一次開詳細頁：用 AVURLAsset 讀 track 資訊
    func probeSpecs(_ item: MediaItem) async {
        guard !item.specProbed, auth.state == .signedIn else { return }
        do {
            let url = try await proxy.streamURL(fileId: item.fileId, filename: item.fileName)
            let info = try await SpecProbe.probe(url: url)
            if info.duration > 0 { item.duration = info.duration }
            if let w = info.width { item.width = w }
            if let h = info.height { item.height = h }
            item.isHDR = info.isHDR || info.isDolbyVision
            item.isDolbyVision = info.isDolbyVision
            item.audioFormat = info.audioFormat
            item.specProbed = true
            try? library.context.save()
        } catch {
            // 讀不到（離線、沒登入）：下次開詳細頁再試
        }
    }

    // MARK: - App 狀態

    /// App 回到前景：代理被系統關掉的話重開
    func didBecomeActive() {
        let proxy = proxy
        Task { try? await proxy.ensureRunning() }
        // 上次比對時斷網的，回來再試
        if network.isOnline { matcher.matchPending() }
    }

    /// 重新比對所有「未辨識」
    func retryUnmatched() {
        let unmatched = MatchState.unmatched.rawValue
        let context = library.context
        for item in (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.matchStateRaw == unmatched }))) ?? [] {
            item.matchState = .pending
        }
        for show in (try? context.fetch(FetchDescriptor<Show>(predicate: #Predicate { $0.matchStateRaw == unmatched }))) ?? [] {
            show.matchState = .pending
        }
        try? context.save()
        matcher.matchPending()
    }

    func didEnterBackground() {
        player.appDidEnterBackground()
    }
}
