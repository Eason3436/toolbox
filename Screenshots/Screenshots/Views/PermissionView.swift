import SwiftUI

/// 要求完整照片存取權。
struct PermissionView: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 12) {
                Text("讓 Screenshots 讀取你的截圖")
                    .font(.title2.bold())
                Text("需要「完整取用」照片，才能自動找到所有截圖。分析全部在手機上完成，不會上傳任何圖片。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            if library.access == .denied {
                Text("你先前拒絕了照片權限，請到「設定」開啟。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Text("前往設定").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
            } else {
                Button {
                    Task { await library.requestAccess() }
                } label: {
                    Text("允許取用照片").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 24)
    }
}

/// 首次啟動選擇匯入範圍。
struct ImportRangeView: View {
    let onChoose: (ImportRange) -> Void
    @State private var selection: ImportRange = .last90

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 12) {
                Text("要匯入哪些截圖？")
                    .font(.title2.bold())
                Text("截圖越多，第一次分析越久。之後可以在「設定」更改。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            VStack(spacing: 12) {
                ForEach(ImportRange.allCases) { range in
                    Button {
                        selection = range
                    } label: {
                        HStack {
                            Text(range.title)
                            Spacer()
                            if selection == range {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 24)
            Spacer()
            Button {
                onChoose(selection)
            } label: {
                Text("開始").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 24)
    }
}
