import Foundation

/// 播放進度規則（§5）
public enum PlaybackRules {
    /// 看完 95% 以上算看完
    public static let watchedThreshold = 0.95
    /// 播放中多久存一次
    public static let saveInterval: TimeInterval = 10
    /// 自動播下一集的倒數秒數
    public static let nextEpisodeCountdown = 10
    /// 太接近開頭的位置不當成續播點
    public static let minimumResumeSeconds: Double = 15

    public static func isWatched(position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        return position / duration >= watchedThreshold
    }

    /// 回傳要續播的秒數；沒有就是 nil（從頭播）
    public static func resumePosition(position: Double, duration: Double, watched: Bool) -> Double? {
        guard !watched, position >= minimumResumeSeconds else { return nil }
        if duration > 0, isWatched(position: position, duration: duration) { return nil }
        return position
    }

    public static func progress(position: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

/// 00:12:34 / 1:02:03 這種時間碼
public enum Timecode {
    /// 「00:12:34」（固定兩位數小時）
    public static func string(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return pad(h) + ":" + pad(m) + ":" + pad(s)
    }

    /// 時長：「2 小時 14 分」「45 分」
    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        if h > 0 { return m > 0 ? "\(h) 小時 \(m) 分" : "\(h) 小時" }
        return "\(m) 分"
    }

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
