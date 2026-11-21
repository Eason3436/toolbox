import Core
import SwiftUI

/// 設定 → 字幕和音軌
struct SubtitleSettingsView: View {
    @AppStorage(Prefs.externalSubtitles) private var externalSubtitles = true
    @AppStorage(Prefs.autoEmbeddedSubtitles) private var autoEmbedded = true
    @AppStorage(Prefs.subtitleLanguage) private var subtitleLanguage = MediaLanguage.traditionalChinese.rawValue
    @AppStorage(Prefs.audioLanguage) private var audioLanguage = ""
    @AppStorage(Prefs.subtitleColor) private var color = "FFFFFF"
    @AppStorage(Prefs.subtitleEdgeColor) private var edgeColor = "000000"
    @AppStorage(Prefs.subtitleBold) private var bold = false
    @AppStorage(Prefs.subtitleItalic) private var italic = false
    @AppStorage(Prefs.subtitleScale) private var scale = 1.0

    var body: some View {
        Form {
            Section {
                Picker("自動載入外部字幕規則", selection: $externalSubtitles) {
                    Text("同資料夾下同名字幕").tag(true)
                    Text("關閉").tag(false)
                }
                Toggle("自動載入內嵌字幕", isOn: $autoEmbedded)
                Picker("字幕語言", selection: $subtitleLanguage) {
                    ForEach(MediaLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            } footer: {
                Text("外部字幕：影片旁邊同檔名的 .srt、.vtt、.ass（例如「電影.zh-TW.srt」），有好幾個就挑符合字幕語言的。內嵌字幕：影片檔裡的字幕軌，播放時也可以在播放器的字幕選單換。")
            }

            Section {
                Picker("預設音軌語言", selection: $audioLanguage) {
                    Text("檔案預設").tag("")
                    ForEach(MediaLanguage.allCases.filter { $0 != .simplifiedChinese }) { language in
                        Text(language == .traditionalChinese ? "中文" : language.displayName).tag(language.rawValue)
                    }
                }
            }

            Section {
                ColorPicker("字體顏色", selection: HexColor.binding($color), supportsOpacity: false)
                ColorPicker("邊框顏色", selection: HexColor.binding($edgeColor), supportsOpacity: false)
                Toggle("粗體文字", isOn: $bold)
                Toggle("斜體文字", isOn: $italic)
                VStack(alignment: .leading) {
                    LabeledContent("字體大小", value: scale.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $scale, in: 0.6...1.8, step: 0.1)
                }
                preview
            } header: {
                Text("字幕樣式")
            } footer: {
                Text("外部字幕完全照這裡的樣式；內嵌字幕只套用顏色、粗斜體與大小，也會受到 iPhone「設定 → 輔助使用 → 字幕與隱藏式字幕」影響。")
            }
        }
        .navigationTitle("字幕和音軌")
        .navigationBarTitleDisplayMode(.inline)
        .softScrollEdges()
    }

    private var preview: some View {
        Text("這是字幕預覽 Subtitle")
            .font(.system(size: 20 * scale, weight: bold ? .bold : .semibold))
            .italic(italic)
            .foregroundStyle(Color(uiColor: HexColor.uiColor(color)))
            .shadow(color: Color(uiColor: HexColor.uiColor(edgeColor)), radius: 1)
            .shadow(color: Color(uiColor: HexColor.uiColor(edgeColor)), radius: 2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color(white: 0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}
