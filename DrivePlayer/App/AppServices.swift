import Core
import Foundation
import Observation
import SwiftData
import UIKit

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

    /// 有續播進度、設定是「每次詢問」時等使用者選
    var pendingResume: MediaItem?
    /// 行動網路提醒：等使用者確認
    var pendingCellular: PendingPlay?
    /// 這次打開 App 已經同意用行動網路播放
    @ObservationIgnored private var cellularApproved = false

    struct PendingPlay: Identifiable {
        let item: MediaItem
        let fromBeginning: Bool
        var id: String { item.fileId }
    }

    init() {
        Prefs.register()
        let auth = GoogleAuthService()
        self.auth = auth
        let tokens = auth.tokens!
        let context = AppDatabase.container.mainContext
        drive = DriveClient(tokens: tokens)
        proxy = LocalStreamProxy { force in try await tokens.token(forceRefresh: force) }
        player = PlayerController(proxy: proxy, drive: drive)
        library = LibraryManager(context: context, drive: drive)
        matcher = MetadataMatcher(context: context, tmdb: TMDBClient(apiKey: AppConfig.tmdbAPIKey))
        playback = PlaybackStore(context: context)
        wire()
    }

    private func wire() {
        let proxy = proxy
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            proxy.purgeCache()
        }
        library.onScanFinished = { [weak self] in self?.matcher.matchPending() }
        player.onProgress = { [weak self] request, position, duration, reason in
            self?.playback.record(fileId: request.fileId, position: position, duration: duration,
                                  finished: reason == .finished, autoMark: Prefs.bool(Prefs.autoMarkWatched))
        }
        player.autoPlayNext = { Prefs.bool(Prefs.autoPlayNext) }
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
        var request: PlaybackRequest
        if item.kind == .episode {
            let showTitle = item.show?.title ?? item.title
            var subtitle = item.episodeLabel ?? ""
            if let t = EpisodeTitle.meaningful(item.episodeTitle) { subtitle += subtitle.isEmpty ? t : "・" + t }
            request = PlaybackRequest(fileId: item.fileId, fileName: item.fileName, title: showTitle, subtitle: subtitle.isEmpty ? nil : subtitle, startAt: start)
            if Prefs.bool(Prefs.skipIntroOutro), let show = item.show {
                request.introEnd = show.introSeconds
                request.outroLength = show.outroSeconds
            }
            request.audioKey = item.show?.audioKey
            request.backdropURL = TMDB.imageURL(item.stillPath, size: .backdrop) ?? item.backdropURL
        } else {
            request = PlaybackRequest(fileId: item.fileId, fileName: item.fileName, title: item.title, subtitle: item.year.map(String.init), startAt: start)
            request.audioChoice = item.audioTrackChoice
            request.backdropURL = item.backdropURL
        }
        request.logoURL = TMDB.imageURL(item.logoPath ?? item.show?.logoPath, size: .logo)
        request.parentId = item.parentId
        return request
    }

    /// 播放。有續播進度時照「繼續播放」設定；行動網路時先問
    func play(_ item: MediaItem, fromBeginning: Bool = false, resumeDecided: Bool = false) {
        guard network.isOnline else {
            player.errorMessage = "沒有網路連線，請檢查網路後再試一次"
            return
        }
        guard auth.state == .signedIn else {
            player.errorMessage = auth.sessionExpired ? AuthError.expired.localizedDescription : AuthError.notSignedIn.localizedDescription
            return
        }
        var fromBeginning = fromBeginning
        if !fromBeginning, !resumeDecided, playback.resumePosition(for: item.fileId) != nil {
            switch Prefs.resume {
            case .resume: break
            case .beginning: fromBeginning = true
            case .ask:
                pendingResume = item
                return
            }
        }
        if Prefs.bool(Prefs.cellularWarning), network.isExpensive, !cellularApproved {
            pendingCellular = PendingPlay(item: item, fromBeginning: fromBeginning)
            return
        }
        let request = request(for: item, fromBeginning: fromBeginning)
        Task { await player.play(request) }
    }

    /// 行動網路提醒按「播放」
    func approveCellular(_ pending: PendingPlay) {
        cellularApproved = true
        pendingCellular = nil
        play(pending.item, fromBeginning: pending.fromBeginning, resumeDecided: true)
    }

    func item(_ fileId: String) -> MediaItem? {
        try? library.context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.fileId == fileId })).first
    }

    // MARK: - 規格

    /// 第一次開詳細頁：用 AVURLAsset 讀 track 資訊
    func probeSpecs(_ item: MediaItem) async {
        guard !item.specProbed || item.specVersion < SpecProbe.version, auth.state == .signedIn else { return }
        do {
            let url = try await proxy.streamURL(fileId: item.fileId, filename: item.fileName)
            let info = try await SpecProbe.probe(url: url, truehd: await proxy.remuxedAudio(fileId: item.fileId))
            if info.duration > 0 { item.duration = info.duration }
            if let w = info.width { item.width = w }
            if let h = info.height { item.height = h }
            item.isHDR = info.isHDR || info.isDolbyVision
            item.isDolbyVision = info.isDolbyVision
            item.hdrFormat = info.hdrFormat
            item.audioFormat = info.audioFormat
            item.audioChannels = info.audioChannels
            item.isAtmos = info.isAtmos
            item.unsupportedVideo = info.unsupportedVideo
            item.unsupportedAudio = info.unsupportedAudio
            item.audioTracks = info.audioTracks
            item.specProbed = true
            item.specVersion = SpecProbe.version
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
