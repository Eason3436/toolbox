import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox
import Cinematic

/// APAC（Apple Positional Audio Codec）：iPhone 錄的空間音訊。
let kAudioFormatAPACCode: FourCharCode = 0x6170_6163 // 'apac'

extension FourCharCode {
    /// 'aac ' 這種四字元代碼轉成字串。
    var fourCCString: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .macOSRoman) ?? "????"
        return text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 原片資訊

struct SourceAudioTrack: Sendable, Hashable {
    let trackID: CMPersistentTrackID
    let codec: FourCharCode
    let channels: Int
    let bitrate: Double

    var isSpatial: Bool { codec == kAudioFormatAPACCode }

    var label: String {
        switch codec {
        case kAudioFormatAPACCode: return "空間音訊（APAC）"
        case kAudioFormatMPEG4AAC: return channels > 0 ? "AAC \(channels) 聲道" : "AAC"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatAppleLossless: return "ALAC"
        default: return codec.fourCCString.uppercased()
        }
    }
}

/// 轉換前讀到的原片資訊，加上自動算好的編碼規劃。
struct VideoProbe: Sendable {
    let url: URL
    let name: String
    let fileSize: Int64
    let codedWidth: Int
    let codedHeight: Int
    let displayWidth: Int
    let displayHeight: Int
    let frameRate: Double
    let duration: Double
    let isHDR: Bool
    let isPQ: Bool
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let isSpatialVideo: Bool
    let videoBitrate: Double
    let audioTracks: [SourceAudioTrack]
    let plan: BitratePlan?

    var hasSpatialAudio: Bool { audioTracks.contains(where: \.isSpatial) }
    var audioBitrate: Double { audioTracks.reduce(0) { $0 + $1.bitrate } }

    /// 輸出畫面方向的尺寸（套用 preferredTransform 後）。
    var outputDisplaySize: (width: Int, height: Int)? {
        guard let plan else { return nil }
        let rotated = (displayWidth >= displayHeight) != (codedWidth >= codedHeight)
        return rotated ? (plan.height, plan.width) : (plan.width, plan.height)
    }

    var estimatedOutputSize: Int64 {
        guard let plan else { return 0 }
        return BitrateCalculator.estimatedFileSize(plan: plan, duration: duration, audioBitrate: audioBitrate)
    }

    /// 不支援時的原因；nil 代表可以轉。
    var unsupportedReason: String? {
        if isSpatialVideo { return "這是空間影片（MV-HEVC），目前不支援。" }
        if plan == nil { return "原片已經是 1080p 或更小，不需要轉。" }
        return nil
    }
}

// MARK: - 空間音訊驗證結果

struct AudioCheck: Sendable {
    /// 預期輸出的音軌 codec（排序過）。
    let expectedCodecs: [FourCharCode]
    let outputCodecs: [FourCharCode]
    let sourceHadSpatial: Bool
    /// 系統（Cinematic 框架）判斷原片／輸出是否含空間音訊；無法判斷時是 nil。
    let systemSource: Bool?
    let systemOutput: Bool?

    var tracksMatch: Bool { expectedCodecs == outputCodecs }
    var outputHasAPAC: Bool { outputCodecs.contains(kAudioFormatAPACCode) }

    /// 空間音訊是否保留成功：音軌數量與 codec 一致、有 APAC，而且系統判斷沒有退步。
    var spatialPreserved: Bool {
        guard sourceHadSpatial, outputHasAPAC, tracksMatch else { return false }
        if systemSource == true && systemOutput == false { return false }
        return true
    }
}

enum DownscaleError: LocalizedError {
    /// APAC 空間音訊寫不進去：可以問使用者要不要改成只保留立體聲。
    case spatialAudioWriteFailed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .spatialAudioWriteFailed(let detail): return "空間音訊寫入失敗：\(detail)"
        case .failed(let message): return message
        }
    }
}

// MARK: - 轉檔

enum DownscaleTranscoder {
    // MARK: 讀取原片資訊

    static func probe(url: URL, name: String) async throws -> VideoProbe {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError("這個檔案沒有影像軌")
        }
        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let nominalRate = try await video.load(.nominalFrameRate)
        let dataRate = try await video.load(.estimatedDataRate)
        let formats = try await video.load(.formatDescriptions)
        let characteristics = try await video.load(.mediaCharacteristics)
        let duration = try await asset.load(.duration).seconds

        // 色彩資訊從格式描述讀：HLG／PQ 就是 HDR。
        var primaries: String?, transfer: String?, matrix: String?
        if let format = formats.first {
            primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        }
        let isPQ = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        let isHLG = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        let isHDR = isPQ || isHLG || characteristics.contains(.containsHDRVideo)
        // 空間影片：MV-HEVC 多視角。
        let isSpatial = characteristics.contains(.containsStereoMultiviewVideo)

        var audio: [SourceAudioTrack] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let trackFormats = try await track.load(.formatDescriptions)
            let rate = try await track.load(.estimatedDataRate)
            guard let format = trackFormats.first else { continue }
            let codec = CMFormatDescriptionGetMediaSubType(format)
            let channels = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame ?? 0
            audio.append(SourceAudioTrack(trackID: track.trackID, codec: codec,
                                          channels: Int(channels), bitrate: Double(rate)))
        }

        let codedWidth = Int(abs(naturalSize.width).rounded())
        let codedHeight = Int(abs(naturalSize.height).rounded())
        let display = naturalSize.applying(transform)
        let fps = nominalRate > 0 ? Double(nominalRate) : 30
        let plan = BitrateCalculator.plan(sourceWidth: codedWidth, sourceHeight: codedHeight, frameRate: fps,
                                          isHDR: isHDR, sourceVideoBitrate: dataRate > 0 ? Double(dataRate) : nil)
        return VideoProbe(
            url: url, name: name, fileSize: Workspace.fileSize(url),
            codedWidth: codedWidth, codedHeight: codedHeight,
            displayWidth: Int(abs(display.width).rounded()), displayHeight: Int(abs(display.height).rounded()),
            frameRate: fps, duration: duration.isFinite ? duration : 0,
            isHDR: isHDR, isPQ: isPQ,
            colorPrimaries: primaries, transferFunction: transfer, yCbCrMatrix: matrix,
            isSpatialVideo: isSpatial, videoBitrate: Double(dataRate),
            audioTracks: audio, plan: plan
        )
    }

    // MARK: 轉檔主流程

    /// 影像重新編碼成 1080p HEVC，音訊與 timed metadata 原封不動複製，封裝成 .mov。
    /// - Parameter keepSpatialAudio: false 時略過 APAC 軌，只保留其他音訊（立體聲）。
    static func transcode(_ probe: VideoProbe, to output: URL, keepSpatialAudio: Bool,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let plan = probe.plan else { throw ToolError(probe.unsupportedReason ?? "不支援這支影片") }
        try? FileManager.default.removeItem(at: output)

        let asset = AVURLAsset(url: probe.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        // 檔案層級 metadata：拍攝日期、地點、機型等（QuickTime 的兩種 key space）。
        let fileMetadata = try await asset.load(.metadata)
        writer.metadata = fileMetadata.filter {
            $0.keySpace == .quickTimeMetadata || $0.keySpace == .quickTimeUserData
        }

        // 軌道的 alternate group 只有 AVMovieTrack 讀得到。
        let alternateGroups = await loadAlternateGroups(url: probe.url)

        var pumps: [Pump] = []
        var inputsBySourceID: [CMPersistentTrackID: AVAssetWriterInput] = [:]

        // ---- 影像 ----
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError("這個檔案沒有影像軌")
        }
        // HDR 讀成 10-bit，SDR 讀成 8-bit，都是 4:2:0 video range，跟編碼器原生格式一致。
        let pixelFormat = probe.isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ToolError("無法讀取影像軌") }
        reader.add(videoOutput)

        let videoSettings = try makeVideoSettings(plan: plan, probe: probe, writer: writer)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        // 保留旋轉方向（直拍）與時間刻度（原始影格率、時間戳記不變）。
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        videoInput.mediaTimeScale = try await videoTrack.load(.naturalTimeScale)
        videoInput.metadata = try await videoTrack.load(.metadata)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: plan.width,
            kCVPixelBufferHeightKey as String: plan.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(videoInput) else { throw ToolError("無法建立 1080p 影像軌") }
        writer.add(videoInput)
        inputsBySourceID[videoTrack.trackID] = videoInput

        let scaler = try PixelScaler()
        let duration = max(probe.duration, 0.001)
        let reporter = ProgressThrottle(report: progress)
        pumps.append(Pump(name: "video", output: videoOutput, input: videoInput, isSpatialAudio: false) { sample in
            guard let source = CMSampleBufferGetImageBuffer(sample) else { return true }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let pool = adaptor.pixelBufferPool else { return false }
            var scaled: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled)
            guard let scaled, scaler.scale(source, into: scaled) else { return false }
            reporter.update(time.seconds / duration)
            return adaptor.append(scaled, withPresentationTime: time)
        })

        // ---- 音訊：每一軌都 passthrough（outputSettings: nil），不重新編碼 ----
        var audioEntries: [(input: AVAssetWriterInput, sourceID: CMPersistentTrackID, enabled: Bool)] = []
        var includesSpatial = false
        for track in try await asset.loadTracks(withMediaType: .audio) {
            guard let format = try await track.load(.formatDescriptions).first else { continue }
            let isSpatial = CMFormatDescriptionGetMediaSubType(format) == kAudioFormatAPACCode
            if isSpatial && !keepSpatialAudio { continue }

            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else {
                if isSpatial { throw DownscaleError.spatialAudioWriteFailed("無法讀取 APAC 音軌") }
                throw ToolError("無法讀取音軌")
            }
            // sourceFormatHint 帶原始格式描述，writer 才知道要原樣寫入。
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            // 音訊軌的時間刻度就是取樣率，不能（也不需要）另外設定 mediaTimeScale。
            input.languageCode = try await track.load(.languageCode)
            input.extendedLanguageTag = try await track.load(.extendedLanguageTag)
            input.metadata = try await track.load(.metadata)
            let enabled = try await track.load(.isEnabled)
            input.marksOutputTrackAsEnabled = enabled
            guard writer.canAdd(input) else {
                if isSpatial { throw DownscaleError.spatialAudioWriteFailed("這台裝置無法原樣寫入 APAC 音軌") }
                throw ToolError("無法寫入音軌（\(CMFormatDescriptionGetMediaSubType(format).fourCCString)）")
            }
            reader.add(out)
            writer.add(input)
            includesSpatial = includesSpatial || isSpatial
            inputsBySourceID[track.trackID] = input
            audioEntries.append((input, track.trackID, enabled))
            pumps.append(Pump(name: "audio-\(track.trackID)", output: out, input: input,
                              isSpatialAudio: isSpatial) { input.append($0) })
        }
        // 只留立體聲時，原本可能是「備用」的那一軌要改成啟用，不然播放時沒聲音。
        if !keepSpatialAudio, !audioEntries.isEmpty, !audioEntries.contains(where: \.enabled) {
            audioEntries[0].input.marksOutputTrackAsEnabled = true
        }

        // ---- Timed metadata：passthrough 複製 ----
        var metadataTracks: [(track: AVAssetTrack, input: AVAssetWriterInput)] = []
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            guard let format = try await track.load(.formatDescriptions).first else { continue }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = try await track.load(.isEnabled)
            // 不支援的 metadata 格式就略過，不影響影片本身。
            guard reader.canAdd(out), writer.canAdd(input) else { continue }
            reader.add(out)
            writer.add(input)
            inputsBySourceID[track.trackID] = input
            metadataTracks.append((track, input))
            pumps.append(Pump(name: "metadata-\(track.trackID)", output: out, input: input,
                              isSpatialAudio: false) { input.append($0) })
        }

        // 保留 track association：metadata 軌描述的是哪一條軌（通常是影像軌）。
        let referent = AVAssetTrack.AssociationType.metadataReferent
        for (track, input) in metadataTracks {
            let targets = (try? await track.loadAssociatedTracks(ofType: referent)) ?? []
            for target in targets {
                guard let targetInput = inputsBySourceID[target.trackID],
                      input.canAddTrackAssociation(withTrackOf: targetInput, type: referent.rawValue) else { continue }
                input.addTrackAssociation(withTrackOf: targetInput, type: referent.rawValue)
            }
        }

        // 保留 alternate group：立體聲與空間音訊互為備用，播放器依裝置挑一條。
        var groups: [Int: [(input: AVAssetWriterInput, enabled: Bool)]] = [:]
        for entry in audioEntries {
            guard let group = alternateGroups[entry.sourceID], group != 0 else { continue }
            groups[group, default: []].append((entry.input, entry.enabled))
        }
        for (_, members) in groups.sorted(by: { $0.key < $1.key }) where members.count > 1 {
            let defaultInput = members.first(where: \.enabled)?.input ?? members[0].input
            let group = AVAssetWriterInputGroup(inputs: members.map(\.input), defaultInput: defaultInput)
            if writer.canAdd(group) { writer.add(group) }
        }

        // ---- 開始 ----
        guard reader.startReading() else {
            throw reader.error ?? ToolError("無法讀取原片")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            let detail = writer.error?.localizedDescription ?? "無法開始寫入"
            try? FileManager.default.removeItem(at: output)
            if includesSpatial { throw DownscaleError.spatialAudioWriteFailed(detail) }
            throw ToolError(detail)
        }
        writer.startSession(atSourceTime: .zero)

        let coordinator = PumpCoordinator(count: pumps.count)
        // 監看 writer：非同步失敗時，等待中的軌道可能不會再被呼叫，要主動收尾避免卡住。
        let watchdog = Task.detached {
            while !Task.isCancelled && !coordinator.isFinished {
                if writer.status == .failed || reader.status == .failed { coordinator.abortAll() }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                coordinator.onFinish { continuation.resume() }
                // 每一軌各自用自己的佇列 requestMediaDataWhenReady，交錯寫入，
                // 這樣某一軌暫時不收資料時，其他軌照樣前進，writer 不會卡住。
                for (index, pump) in pumps.enumerated() {
                    let queue = DispatchQueue(label: "com.eason3436.toolbox.downscale.\(pump.name)")
                    pump.input.requestMediaDataWhenReady(on: queue) {
                        while !coordinator.isDone(index) && pump.input.isReadyForMoreMediaData {
                            if coordinator.isCancelled || writer.status != .writing {
                                coordinator.abortAll()
                                return
                            }
                            guard let sample = pump.output.copyNextSampleBuffer() else {
                                if reader.status == .failed || reader.status == .cancelled {
                                    coordinator.abortAll()
                                } else {
                                    pump.input.markAsFinished()
                                    coordinator.finish(index)
                                }
                                return
                            }
                            if !pump.append(sample) {
                                coordinator.recordFailure(spatial: pump.isSpatialAudio)
                                coordinator.abortAll()
                                return
                            }
                        }
                    }
                }
            }
        } onCancel: {
            coordinator.cancel()
        }
        watchdog.cancel()

        // ---- 收尾 ----
        func discard() {
            reader.cancelReading()
            if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: output)
        }
        if coordinator.isCancelled || Task.isCancelled {
            discard()
            throw CancellationError()
        }
        if coordinator.failed || writer.status == .failed || reader.status == .failed {
            let detail = writer.error?.localizedDescription ?? reader.error?.localizedDescription
                ?? scaler.lastError ?? "轉檔失敗"
            let spatialFailed = coordinator.failedOnSpatial
                || (includesSpatial && writer.status == .failed && scaler.lastError == nil && !coordinator.failedOnOther)
            discard()
            if spatialFailed { throw DownscaleError.spatialAudioWriteFailed(detail) }
            throw DownscaleError.failed("轉檔失敗：\(detail)")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            let detail = writer.error?.localizedDescription ?? "無法完成寫入"
            try? FileManager.default.removeItem(at: output)
            if includesSpatial { throw DownscaleError.spatialAudioWriteFailed(detail) }
            throw DownscaleError.failed("轉檔失敗：\(detail)")
        }
        progress(1)
    }

    // MARK: 影像編碼設定

    /// HEVC、短邊 1080；HDR 用 Main10 + BT.2020/HLG（或 PQ），SDR 用 Main 8-bit 並沿用原片色彩。
    private static func makeVideoSettings(plan: BitratePlan, probe: VideoProbe,
                                          writer: AVAssetWriter) throws -> [String: Any] {
        let colors: [String: Any]
        if probe.isHDR {
            colors = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: probe.isPQ ? AVVideoTransferFunction_SMPTE_ST_2084_PQ
                                                      : AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        } else {
            let primaries = [AVVideoColorPrimaries_ITU_R_709_2, AVVideoColorPrimaries_P3_D65]
            colors = [
                AVVideoColorPrimariesKey: probe.colorPrimaries.flatMap { primaries.contains($0) ? $0 : nil }
                    ?? AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.targetBitrate,
            AVVideoExpectedSourceFrameRateKey: probe.frameRate,
            AVVideoMaxKeyFrameIntervalKey: plan.keyFrameInterval,
            AVVideoMaxKeyFrameIntervalDurationKey: plan.keyFrameDuration,
            AVVideoAllowFrameReorderingKey: true,
            AVVideoProfileLevelKey: probe.isHDR ? (kVTProfileLevel_HEVC_Main10_AutoLevel as String)
                                                : (kVTProfileLevel_HEVC_Main_AutoLevel as String),
        ]
        // 峰值限制：每 1 秒最多 1.5 倍目標碼率（單位是位元組）。
        let peakKey = kVTCompressionPropertyKey_DataRateLimits as String
        compression[peakKey] = [Double(plan.peakBitrate) / 8, 1.0]

        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoColorPropertiesKey: colors,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if writer.canApply(outputSettings: settings, forMediaType: .video) { return settings }
        // 有些系統版本不接受峰值限制，拿掉後再試（只靠平均碼率控制）。
        compression.removeValue(forKey: peakKey)
        settings[AVVideoCompressionPropertiesKey] = compression
        if writer.canApply(outputSettings: settings, forMediaType: .video) { return settings }
        throw ToolError("這台裝置不支援 1080p HEVC\(probe.isHDR ? " 10-bit" : "") 編碼")
    }

    private static func loadAlternateGroups(url: URL) async -> [CMPersistentTrackID: Int] {
        let movie = AVMovie(url: url, options: nil)
        guard let tracks = try? await movie.load(.tracks) else { return [:] }
        var result: [CMPersistentTrackID: Int] = [:]
        for case let track as AVMovieTrack in tracks {
            result[track.trackID] = track.alternateGroupID
        }
        return result
    }

    // MARK: 空間音訊驗證

    /// 比對輸出檔的音軌數量與 codec 是否和預期一致，iOS 26 起再請系統判斷是否含空間音訊。
    static func verifyAudio(source: VideoProbe, output: URL, keptSpatial: Bool) async -> AudioCheck {
        let expected = source.audioTracks
            .filter { keptSpatial || !$0.isSpatial }
            .map(\.codec).sorted()
        let outputAsset = AVURLAsset(url: output)
        var codecs: [FourCharCode] = []
        if let tracks = try? await outputAsset.loadTracks(withMediaType: .audio) {
            for track in tracks {
                if let format = try? await track.load(.formatDescriptions).first {
                    codecs.append(CMFormatDescriptionGetMediaSubType(format))
                }
            }
        }
        var systemSource: Bool?
        var systemOutput: Bool?
        if #available(iOS 26.0, *) {
            systemSource = await systemSpatialCheck(AVURLAsset(url: source.url))
            systemOutput = await systemSpatialCheck(outputAsset)
        }
        return AudioCheck(expectedCodecs: expected, outputCodecs: codecs.sorted(),
                          sourceHadSpatial: source.hasSpatialAudio,
                          systemSource: systemSource, systemOutput: systemOutput)
    }

    @available(iOS 26.0, *)
    private static func systemSpatialCheck(_ asset: AVAsset) async -> Bool? {
        // Cinematic 框架的「音訊混合」判斷：檔案是否含可用的空間音訊。
        try? await CNAssetSpatialAudioInfo.assetContainsSpatialAudio(asset: asset)
    }
}

// MARK: - 交錯寫入的輔助

/// 一條軌道：從 reader output 拿樣本，交給 append 寫進 writer input。
private final class Pump: @unchecked Sendable {
    let name: String
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let isSpatialAudio: Bool
    let append: (CMSampleBuffer) -> Bool

    init(name: String, output: AVAssetReaderOutput, input: AVAssetWriterInput, isSpatialAudio: Bool,
         append: @escaping (CMSampleBuffer) -> Bool) {
        self.name = name
        self.output = output
        self.input = input
        self.isSpatialAudio = isSpatialAudio
        self.append = append
    }
}

/// 追蹤每一軌是否寫完；全部結束（或中止）時只通知一次。
private final class PumpCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var done: [Bool]
    private var remaining: Int
    private var finishHandler: (() -> Void)?
    private var didNotify = false
    private var cancelled = false
    private var failure = (happened: false, spatial: false, other: false)

    init(count: Int) {
        done = Array(repeating: false, count: count)
        remaining = count
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
    var isFinished: Bool { lock.withLock { remaining == 0 } }
    var failed: Bool { lock.withLock { failure.happened } }
    var failedOnSpatial: Bool { lock.withLock { failure.spatial } }
    var failedOnOther: Bool { lock.withLock { failure.other } }

    func isDone(_ index: Int) -> Bool { lock.withLock { done[index] } }

    func onFinish(_ handler: @escaping () -> Void) {
        lock.lock()
        if remaining == 0 && !didNotify {
            didNotify = true
            lock.unlock()
            handler()
            return
        }
        finishHandler = handler
        lock.unlock()
    }

    func finish(_ index: Int) {
        lock.lock()
        guard !done[index] else { lock.unlock(); return }
        done[index] = true
        remaining -= 1
        notifyIfNeededLocked()
    }

    func abortAll() {
        lock.lock()
        for index in done.indices where !done[index] {
            done[index] = true
            remaining -= 1
        }
        notifyIfNeededLocked()
    }

    func cancel() {
        lock.withLock { cancelled = true }
        abortAll()
    }

    func recordFailure(spatial: Bool) {
        lock.withLock {
            failure.happened = true
            if spatial { failure.spatial = true } else { failure.other = true }
        }
    }

    /// 呼叫前要先 lock，這裡負責 unlock。
    private func notifyIfNeededLocked() {
        guard remaining == 0, !didNotify, let handler = finishHandler else {
            lock.unlock()
            return
        }
        didNotify = true
        finishHandler = nil
        lock.unlock()
        handler()
    }
}

/// 用 VTPixelTransferSession 把 4K 影格縮成 1080p（硬體加速），並沿用色彩標記。
private final class PixelScaler: @unchecked Sendable {
    private let session: VTPixelTransferSession
    private(set) var lastError: String?

    init() throws {
        var created: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created)
        guard status == noErr, let created else { throw ToolError("無法建立影像縮放（\(status)）") }
        session = created
        VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
    }

    deinit { VTPixelTransferSessionInvalidate(session) }

    func scale(_ source: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else {
            lastError = "影像縮放失敗（\(status)）"
            return false
        }
        // 只複製色彩相關的標記；尺寸相關的（例如 clean aperture）不能沿用 4K 的值。
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(destination, key, value, .shouldPropagate)
            }
        }
        return true
    }
}

/// 進度每前進 0.5% 才回報一次，避免塞爆主執行緒。
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func update(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        let shouldReport: Bool = lock.withLock {
            guard clamped - last >= 0.005 else { return false }
            last = clamped
            return true
        }
        if shouldReport { report(clamped) }
    }
}
