import AVFoundation
import Foundation
import Observation
import UIKit

/// 錄音的總控：開始／停止、中斷後自動恢復、排程自動停止、即時動態。
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle
        case starting
        case recording
        /// 被來電等打斷，等待恢復
        case interrupted
        /// 使用者按了暫停
        case paused
    }

    enum StartSource { case manual, schedule, shortcut, resume }

    private(set) var state: State = .idle
    private(set) var mode: RecordingMode = .allDay
    private(set) var startedAt: Date?
    /// 自動停止時間
    private(set) var stopAt: Date?
    private(set) var level: Float = 0
    private(set) var segmentsThisSession = 0
    private(set) var lastError: String?
    private(set) var lecture: LectureSession?
    /// 自動省電中（附近沒人說話：人聲加強關閉、位元率降低）
    private(set) var isPowerSaving = false
    /// 多久沒有近距離說話就進入省電
    static let powerSaveAfter: TimeInterval = 3 * 60

    var isActive: Bool { state != .idle }

    private let store: RecapStore
    private let settings: AppSettings
    private let queue: ProcessingQueue
    private let recorder = AudioEngineRecorder()
    private let liveActivity = LiveActivityManager()
    private var writer: SegmentWriter?
    private var detector: SpeechPresenceDetector?
    private var tickTask: Task<Void, Never>?
    /// 使用者在排程時段內手動按了停止 → 這個時段不要再自動開始
    private(set) var manualStopAt: Date?

    init(store: RecapStore, settings: AppSettings, queue: ProcessingQueue) {
        self.store = store
        self.settings = settings
        self.queue = queue
        recorder.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in
                guard let self else { return }
                self.level = value
                self.levelPeak = max(self.levelPeak, value)
            }
        }
    }

    var currentSegmentStart: Date? { writer?.currentSegmentStart }

    /// 把目前錄到一半的段落先存起來（下一個音訊會自動開新段，不會漏錄）。
    func flushCurrentSegment() {
        guard mode == .allDay else { return }
        writer?.flush()
    }

    // MARK: - 開始／停止

    /// - Parameters:
    ///   - duration: 錄多久後自動停止；nil 時若在排程時段內就錄到時段結束
    func start(mode: RecordingMode, duration: TimeInterval? = nil, source: StartSource, subject: SchoolSubject? = nil) async throws {
        if isActive {
            if self.mode == mode { return }
            await stop(manual: false)
        }
        lastError = nil
        state = .starting
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw RecapError.microphoneDenied }
            await SpeechSupport.requestSpeechPermission()
            self.mode = mode
            let now = Date()
            if let duration {
                stopAt = now.addingTimeInterval(duration)
            } else if source != .manual, let active = settings.activeSchedule(at: now) {
                stopAt = active.end
            } else {
                stopAt = nil
            }

            let writer: SegmentWriter
            if mode == .lecture {
                // 科目：Siri 指定 > 課表 > 下課後 AI 判斷
                let entry = settings.timetableEntry(at: now)
                let chosen = subject ?? entry?.subject
                // 非中文授課才開即時字幕與翻譯；中文課只錄音，下課後再轉文字
                let foreign = chosen == .english || (chosen == nil && settings.lectureForeign)
                let locale = foreign ? (settings.lectureSourceLocale.hasPrefix("zh") ? "en-US" : settings.lectureSourceLocale) : settings.transcriptionLocale
                var lecture = Lecture(start: now, sourceLocale: locale, targetLanguage: settings.translationTarget)
                lecture.subject = chosen
                lecture.subjectFromTimetable = subject == nil && entry != nil
                lecture.recordOnly = !foreign
                if let entry, !entry.name.isEmpty { lecture.name = entry.name }
                let session = LectureSession(lecture: lecture, store: store, live: foreign)
                session.onNewTranslation = { [weak self] text in self?.updateActivity(line: text, throttle: true) }
                try await session.start()
                self.lecture = session
                // 課堂錄音每 30 分鐘一個檔
                writer = SegmentWriter(root: store.recordingsDirectory, segmentSeconds: 30 * 60, tag: "lecture")
                if foreign {
                    recorder.setSinks([writer as AudioSink, session.transcriber as AudioSink] + detectorSinks())
                } else {
                    recorder.setSinks([writer as AudioSink] + detectorSinks())
                }
            } else {
                writer = SegmentWriter(root: store.recordingsDirectory, segmentSeconds: Double(settings.segmentMinutes) * 60, tag: "allday")
                recorder.setSinks([writer as AudioSink] + detectorSinks())
            }
            isPowerSaving = false
            writer.onClosed = { [weak self] closed in
                Task { @MainActor in self?.segmentClosed(closed) }
            }
            self.writer = writer
            recorder.voiceProcessing = settings.voiceProcessing
            recorder.keepNaturalLevels = settings.autoPowerSave
            try recorder.start()
            startedAt = now
            segmentsThisSession = 0
            state = .recording
            detector?.reset()
            Haptics.recordStart()
            liveActivity.start(mode: mode, state: activityState())
            startTicking()
        } catch {
            Haptics.error()
            lastError = error.localizedDescription
            recorder.stop()
            recorder.setSinks([])
            if let lecture { _ = await lecture.finish() }
            lecture = nil
            writer = nil
            state = .idle
            stopAt = nil
            throw error
        }
    }

    func stop(manual: Bool = true) async {
        guard isActive else { return }
        if manual, settings.activeSchedule() != nil { manualStopAt = .now }
        tickTask?.cancel()
        meterTask?.cancel()
        Haptics.recordStop()
        recorder.stop()
        recorder.setSinks([])
        writer?.flush()
        writer = nil
        detector = nil
        isPowerSaving = false
        if let lecture {
            let finished = await lecture.finish()
            self.lecture = nil
            appLog.info("課堂結束，共 \(finished.lines.count) 句")
        }
        state = .idle
        startedAt = nil
        stopAt = nil
        level = 0
        liveActivity.end()
        queue.kick(summaries: UIApplication.shared.applicationState == .active)
    }

    /// 是否在這個排程時段裡手動停過
    func wasManuallyStoppedInCurrentWindow() -> Bool {
        guard let manualStopAt, let active = settings.activeSchedule() else { return false }
        // 手動停止的時間落在目前這個時段內
        return active.rule.windowEnd(containing: manualStopAt) == active.end
    }

    // MARK: - 自動省電

    private func detectorSinks() -> [AudioSink] {
        guard settings.autoPowerSave else {
            detector = nil
            return []
        }
        let detector = SpeechPresenceDetector(thresholdDB: settings.nearSpeechThresholdDB)
        detector.onNearSpeech = { [weak self] in
            Task { @MainActor in self?.nearSpeechDetected() }
        }
        self.detector = detector
        return [detector]
    }

    private func nearSpeechDetected() {
        guard isPowerSaving, state == .recording else { return }
        setPowerSaving(false)
    }

    private func checkPowerSave() {
        guard let detector, settings.autoPowerSave, state == .recording, !isPowerSaving else { return }
        detector.setThreshold(db: settings.nearSpeechThresholdDB)
        if detector.secondsSinceNearSpeech >= Self.powerSaveAfter { setPowerSaving(true) }
    }

    /// 切換省電：換一個新檔（新的位元率）並切換人聲處理。不會中斷錄音工作階段。
    private func setPowerSaving(_ on: Bool) {
        guard on != isPowerSaving else { return }
        isPowerSaving = on
        if on { appLog.info("附近沒人說話，進入省電") } else { appLog.info("偵測到近距離說話，恢復完整品質") }
        writer?.lowBitrate = on
        writer?.flush()
        do {
            try recorder.reconfigure(voiceProcessing: settings.voiceProcessing && !on)
        } catch {
            appLog.error("切換人聲處理失敗：\(error.localizedDescription)")
            Task { await resume(after: .milliseconds(300)) }
        }
        if !on { detector?.reset() }
    }

    // MARK: - 段落

    private func segmentClosed(_ closed: SegmentWriter.Closed) {
        segmentsThisSession += 1
        if closed.relativePath.contains("-lecture-") {
            lecture?.addAudioPart(AudioPart(file: closed.relativePath, start: closed.start, end: closed.end))
            // 課堂結束後才 flush 的最後一段：lecture 已經清掉，直接寫入那堂課
            if lecture == nil, let target = store.allLectures.first(where: { abs($0.start.timeIntervalSince(closed.start)) < 4 * 3600 && ($0.end ?? .distantFuture) >= closed.start.addingTimeInterval(-5) }) {
                var updated = target
                if !updated.audioParts.contains(where: { $0.file == closed.relativePath }) {
                    updated.audioParts.append(AudioPart(file: closed.relativePath, start: closed.start, end: closed.end))
                    store.upsertLecture(updated)
                    // 最後一段音檔到了，可以開始轉文字
                    queue.kick(summaries: UIApplication.shared.applicationState == .active)
                }
            }
        } else {
            let silent = settings.skipSilence && closed.voicedSeconds < 3
            var segment = Segment(start: closed.start, end: closed.end, audioFile: closed.relativePath, voicedSeconds: closed.voicedSeconds, status: silent ? .silent : .recorded)
            if silent {
                // 安靜的段落不留音檔
                store.removeAudio(closed.relativePath)
                segment.audioFile = nil
            }
            store.addSegment(segment)
            if !silent { queue.kick(summaries: UIApplication.shared.applicationState == .active) }
        }
        updateActivity()
    }

    // MARK: - 中斷處理

    private func handle(_ event: AudioEngineRecorder.Event) {
        guard isActive else { return }
        switch event {
        case .interruptionBegan:
            guard state != .paused else { return }
            writer?.flush()
            state = .interrupted
            Haptics.warning()
            updateActivity(alert: true)
        case .interruptionEnded:
            // 不管系統建議與否都試著恢復（錄音 App 的預期行為）；別的 App 可能還沒放開麥克風，多試幾次
            guard state != .paused else { return }
            Task {
                for delay in [600, 2_000, 5_000] {
                    await resume(after: .milliseconds(delay), notifyOnFailure: delay == 5_000)
                    if state == .recording { return }
                }
            }
        case .configurationChanged, .mediaServicesReset:
            guard state != .paused else { return }
            writer?.flush()
            Task { await resume(after: .milliseconds(300)) }
        }
    }

    /// 嘗試恢復錄音；在背景失敗時發通知請使用者點一下。
    func resume(after delay: Duration = .zero, notifyOnFailure: Bool = true) async {
        guard isActive, state != .recording else { return }
        if delay > .zero { try? await Task.sleep(for: delay) }
        do {
            try recorder.start()
            state = .recording
            Haptics.toggle()
            updateActivity()
            Notifications.clearResumeReminder()
        } catch {
            appLog.error("恢復錄音失敗：\(error.localizedDescription)")
            state = .interrupted
            updateActivity()
            if notifyOnFailure, UIApplication.shared.applicationState != .active {
                Notifications.postResumeReminder()
            }
        }
    }

    /// 暫停（保留這次錄音與即時動態，之後可繼續）。
    func pause() {
        guard state == .recording || state == .interrupted else { return }
        recorder.stop()
        writer?.flush()
        state = .paused
        level = 0
        Haptics.toggle()
        updateActivity()
    }

    /// App 回到前景：如果還在中斷狀態就再試一次。
    func appDidBecomeActive() {
        if state == .interrupted { Task { await resume() } }
    }

    // MARK: - 定時檢查

    /// 動態島的即時波形：每秒取這一秒的最大音量，留最近 6 格送給即時動態。
    private var levelPeak: Float = 0
    private var levelHistory: [Double] = []
    private var meterTask: Task<Void, Never>?

    private func startMeter() {
        meterTask?.cancel()
        levelHistory = []
        levelPeak = 0
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.state == .recording else { continue }
                // 人聲的音量偏小，開根號讓波形看得出起伏
                let value = Double(min(1, max(0, self.levelPeak))).squareRoot()
                self.levelPeak = 0
                self.levelHistory.append((value * 100).rounded() / 100)
                if self.levelHistory.count > 6 { self.levelHistory.removeFirst(self.levelHistory.count - 6) }
                self.updateActivity(meter: true)
            }
        }
    }

    private func startTicking() {
        startMeter()
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    private func tick() async {
        if let stopAt, Date() >= stopAt {
            await stop(manual: false)
            return
        }
        // 中斷太久（例如通話後沒恢復）就每 15 秒再試
        if state == .interrupted { await resume() }
        checkPowerSave()
    }

    // MARK: - 即時動態

    private func activityState(line: String? = nil) -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(
            startedAt: startedAt ?? .now,
            isPaused: state == .interrupted || state == .paused,
            manualPause: state == .paused,
            line: line ?? lecture?.lastTranslation,
            segmentCount: mode == .lecture ? (lecture?.lecture.lines.count ?? 0) : segmentsThisSession,
            stopAt: stopAt,
            levels: state == .recording ? levelHistory : []
        )
    }

    private func updateActivity(line: String? = nil, throttle: Bool = false, alert: Bool = false, meter: Bool = false) {
        liveActivity.update(activityState(line: line), throttle: throttle, alert: alert, meter: meter)
    }

    func cleanUpStaleActivities() {
        if !isActive { liveActivity.end() }
    }
}
