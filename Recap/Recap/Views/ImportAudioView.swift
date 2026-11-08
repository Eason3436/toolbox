import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 匯入外部錄音檔（語音備忘錄、其他 App 錄的課），當成一堂課轉文字、整理重點和筆記。
enum AudioImporter {
    static let types: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie, .mpeg4Movie, .quickTimeMovie]
        + [UTType(filenameExtension: "m4a"), UTType(filenameExtension: "aac"), UTType(filenameExtension: "caf")].compactMap { $0 }

    @MainActor
    static func importLecture(from source: URL, name: String, start: Date, locale: String, subject: SchoolSubject?) async throws -> UUID {
        let store = RecapStore.shared
        let settings = AppSettings.shared
        let key = DayKey.key(for: start)
        let relative = "\(key)/import-\(UUID().uuidString).m4a"
        let destination = store.audioURL(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 一律轉成 m4a（影片也只取聲音），語音辨識才讀得了
        let asset = AVURLAsset(url: source)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            do {
                try await export.export(to: destination, as: .m4a)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
            }
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let length = duration.isFinite && duration > 0 ? duration : 60
        let end = start.addingTimeInterval(length)
        var lecture = Lecture(start: start, end: end, sourceLocale: locale, targetLanguage: settings.translationTarget)
        lecture.audioParts = [AudioPart(file: relative, start: start, end: end)]
        lecture.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        lecture.subject = subject
        lecture.recordOnly = true
        store.upsertLecture(lecture)
        AppModel.shared.queue.kick(summaries: true)
        return lecture.id
    }

    /// 檔案的建立時間（拿來當上課時間的預設值）
    static func fileDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}

struct ImportAudioView: View {
    var onImported: (UUID) -> Void = { _ in }
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var file: URL?
    @State private var name = ""
    @State private var start = Date.now
    @State private var locale = "zh-TW"
    @State private var subject: SchoolSubject = .general
    @State private var working = false
    @State private var error: String?

    private static let languages = [("zh-TW", "中文（可中英夾雜）"), ("en-US", "英文"), ("ja-JP", "日文")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        picking = true
                    } label: {
                        Label(file?.lastPathComponent ?? "選擇錄音檔", systemImage: file == nil ? "waveform.badge.plus" : "checkmark.circle.fill")
                    }
                } footer: {
                    Text("可以選語音備忘錄、其他 App 錄的課，或影片（只取聲音）。匯入後會在背景轉成文字，再用 \(AIConfig.engineName) 整理重點、摘要和筆記，跟課堂模式錄的一樣。")
                }
                Section {
                    TextField("課名（選填，留空由 AI 判斷）", text: $name)
                    DatePicker("上課時間", selection: $start)
                    Picker("上課語言", selection: $locale) {
                        ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("科目", selection: $subject) {
                        ForEach(SchoolSubject.allCases) { Text($0 == .general ? "由 AI 判斷" : $0.title).tag($0) }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("匯入錄音檔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("匯入") { Task { await run() } }.disabled(file == nil)
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: AudioImporter.types) { result in
                guard case .success(let url) = result else { return }
                file = url
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let date = AudioImporter.fileDate(url) { start = date }
            }
        }
    }

    private func run() async {
        guard let file else { return }
        working = true
        defer { working = false }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            let id = try await AudioImporter.importLecture(from: file, name: name, start: start, locale: locale,
                                                           subject: subject == .general ? nil : subject)
            Haptics.success()
            dismiss()
            onImported(id)
        } catch {
            self.error = "匯入失敗：\(error.localizedDescription)"
            Haptics.error()
        }
    }
}
