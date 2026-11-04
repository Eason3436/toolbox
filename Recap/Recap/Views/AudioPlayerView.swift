import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AudioPlayerModel: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    var currentTime: TimeInterval = 0
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    var isLoaded: Bool { player != nil }

    func toggle() {
        guard let player else { return }
        Haptics.toggle()
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord {
                try? session.setCategory(.playback, mode: .spokenAudio)
                try? session.setActive(true)
            }
            player.play()
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.currentTime = self?.player?.currentTime ?? 0 }
            }
        }
    }

    func seek(_ time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func skip(_ delta: TimeInterval) {
        Haptics.soft()
        seek(max(0, min(duration, currentTime + delta)))
    }

    func stop() {
        player?.stop()
        isPlaying = false
        timer?.invalidate()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            isPlaying = false
            timer?.invalidate()
            currentTime = 0
        }
    }
}

struct AudioPlayerView: View {
    let url: URL
    var title: String? = nil
    @State private var model = AudioPlayerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
            if model.isLoaded {
                HStack(spacing: 14) {
                    Button { model.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { model.toggle() } label: {
                        Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 36))
                    }
                    Button { model.skip(15) } label: { Image(systemName: "goforward.15") }
                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { model.currentTime }, set: { model.seek($0) }), in: 0...max(1, model.duration))
                        HStack {
                            Text(Duration.seconds(model.currentTime).formatted(.time(pattern: .minuteSecond)))
                            Spacer()
                            Text(Duration.seconds(model.duration).formatted(.time(pattern: .minuteSecond)))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            } else {
                Label("找不到音檔", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { model.load(url) }
        .onDisappear { model.stop() }
    }
}
