import Foundation

/// 4K → 1080p 的輸出尺寸與碼率規劃。純計算，不碰 AVFoundation，方便單元測試。
struct BitratePlan: Equatable, Sendable {
    /// 輸出的編碼尺寸（跟原片同方向，旋轉交給 preferredTransform）。
    let width: Int
    let height: Int
    /// 平均碼率（bps）。
    let targetBitrate: Int
    /// 峰值碼率（bps），約為平均的 1.5 倍。
    let peakBitrate: Int
    /// 關鍵影格間隔（影格數），對應 2 秒。
    let keyFrameInterval: Int
    /// 關鍵影格間隔（秒）。
    let keyFrameDuration: Double
    /// 有效影格率（高影格率不會線性加碼率）。
    let effectiveFrameRate: Double
    /// 複雜度係數（0.8～1.4）。
    let complexity: Double
}

enum BitrateCalculator {
    /// 每像素每影格的位元數。
    static let sdrBitsPerPixel = 0.14
    static let hdrBitsPerPixel = 0.17
    /// 原片 bpp 除以這個值就是複雜度係數。
    static let referenceSourceBitsPerPixel = 0.09
    static let complexityRange: ClosedRange<Double> = 0.8...1.4
    /// SDR 30fps 的上下限（bps）。其他影格率依有效影格率等比例調整，HDR 再 ×1.25。
    static let sdrFloor30 = 7_000_000.0
    static let sdrCeiling30 = 18_000_000.0
    static let hdrBoundsFactor = 1.25
    /// 輸出影像碼率最多只能是原片的 60%，不然就沒有變小的意義。
    static let maxShareOfSource = 0.6
    static let peakFactor = 1.5
    static let keyFrameSeconds = 2.0
    static let targetShortSide = 1080

    /// 短邊縮到 1080、長邊等比例並取偶數。直拍（寬 < 高）和橫拍都適用。
    /// 原片短邊已經 ≤ 1080 時回傳 nil（不需要轉）。
    static func outputSize(sourceWidth: Int, sourceHeight: Int,
                           shortSide: Int = targetShortSide) -> (width: Int, height: Int)? {
        let short = min(sourceWidth, sourceHeight)
        let long = max(sourceWidth, sourceHeight)
        guard short > shortSide, short > 0 else { return nil }
        let scaledLong = Double(long) * Double(shortSide) / Double(short)
        // 取最接近的偶數：4:2:0 色度取樣要求寬高都是偶數。
        let evenLong = Int((scaledLong / 2).rounded()) * 2
        return sourceWidth >= sourceHeight ? (evenLong, shortSide) : (shortSide, evenLong)
    }

    /// 有效影格率 = 30 × (實際影格率 / 30)^0.75。
    /// 影格率越高，相鄰影格越像，每多一格需要的位元越少，所以不線性增加。
    static func effectiveFrameRate(_ frameRate: Double) -> Double {
        let fps = frameRate > 0 ? frameRate : 30
        return 30 * pow(fps / 30, 0.75)
    }

    /// 複雜度係數：原片每像素每影格用了多少位元。
    /// 原片碼率高（畫面細節多、動作多）就多給一點，低就少給，限制在 0.8～1.4。
    /// 不知道原片碼率時用 1。
    static func complexity(sourceBitrate: Double?, sourceWidth: Int, sourceHeight: Int,
                           frameRate: Double) -> Double {
        guard let sourceBitrate, sourceBitrate > 0, sourceWidth > 0, sourceHeight > 0, frameRate > 0 else {
            return 1
        }
        let sourceBPP = sourceBitrate / (Double(sourceWidth) * Double(sourceHeight) * frameRate)
        let raw = sourceBPP / referenceSourceBitsPerPixel
        return min(max(raw, complexityRange.lowerBound), complexityRange.upperBound)
    }

    /// 依影格率與動態範圍調整後的上下限（bps）。
    static func bounds(frameRate: Double, isHDR: Bool) -> ClosedRange<Double> {
        let scale = effectiveFrameRate(frameRate) / 30 * (isHDR ? hdrBoundsFactor : 1)
        return (sdrFloor30 * scale)...(sdrCeiling30 * scale)
    }

    /// 算出完整的編碼規劃。原片短邊 ≤ 1080 時回傳 nil。
    static func plan(sourceWidth: Int, sourceHeight: Int, frameRate: Double, isHDR: Bool,
                     sourceVideoBitrate: Double?) -> BitratePlan? {
        guard let size = outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight) else { return nil }
        let fps = frameRate > 0 ? frameRate : 30
        let effective = effectiveFrameRate(fps)

        // 1. 基準碼率 = 寬 × 高 × 有效影格率 × bpp
        let bpp = isHDR ? hdrBitsPerPixel : sdrBitsPerPixel
        let base = Double(size.width * size.height) * effective * bpp

        // 2. 依原片複雜度調整
        let factor = complexity(sourceBitrate: sourceVideoBitrate, sourceWidth: sourceWidth,
                                sourceHeight: sourceHeight, frameRate: fps)
        var target = base * factor

        // 3. 上下限，最後再壓在原片的 60% 以內（原片本來就很省時，寧可低於下限也不要變大）
        let range = bounds(frameRate: fps, isHDR: isHDR)
        target = min(max(target, range.lowerBound), range.upperBound)
        if let source = sourceVideoBitrate, source > 0 {
            target = min(target, source * maxShareOfSource)
        }

        let targetBitrate = Int(target.rounded())
        // 4. 關鍵影格每 2 秒一張；峰值約為平均的 1.5 倍
        return BitratePlan(
            width: size.width,
            height: size.height,
            targetBitrate: targetBitrate,
            peakBitrate: Int((target * peakFactor).rounded()),
            keyFrameInterval: max(1, Int((fps * keyFrameSeconds).rounded())),
            keyFrameDuration: keyFrameSeconds,
            effectiveFrameRate: effective,
            complexity: factor
        )
    }

    /// 預估輸出檔案大小（位元組）：影像 + 原封不動的音訊 + 約 1% 封裝額外負擔。
    static func estimatedFileSize(plan: BitratePlan, duration: Double, audioBitrate: Double) -> Int64 {
        guard duration > 0 else { return 0 }
        let bits = (Double(plan.targetBitrate) + max(audioBitrate, 0)) * duration
        return Int64((bits / 8 * 1.01).rounded())
    }
}
