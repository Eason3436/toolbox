import SwiftUI

/// 取得／開啟／更新／下載中（圓形進度）
struct GetButton: View {
    let status: PackStatus
    let action: () -> Void

    private var title: String {
        switch status {
        case .notDownloaded: "取得"
        case .downloaded: "開啟"
        case .updateAvailable: "更新"
        case .downloading: ""
        }
    }

    var body: some View {
        switch status {
        case .downloading(let progress):
            ProgressRing(progress: progress, lineWidth: 2.5)
                .frame(width: 28, height: 28)
                .frame(minWidth: 64, minHeight: 32)
        default:
            Button(action: action) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
    }
}

/// 商店橫向捲動的小卡（寬 140）
struct PackCard: View {
    let pack: StorePack
    let status: PackStatus
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IconTile(label: pack.tileLabel, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                    .lineLimit(2, reservesSpace: true)
                Text(pack.countLabel)
                    .font(.caption)
                    .foregroundStyle(Color.er.textSecondary)
            }
            GetButton(status: status, action: action)
        }
        .frame(width: 140, alignment: .leading)
    }
}

/// 商店直式列表的一列
struct PackRow: View {
    let pack: StorePack
    let status: PackStatus
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            IconTile(label: pack.tileLabel, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                Text([pack.subtitle, pack.countLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color.er.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            GetButton(status: status, action: action)
        }
        .contentShape(Rectangle())
    }
}

#Preview("淺色") {
    let packs = PreviewData.packs
    VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 12) {
            PackCard(pack: packs[0], status: .downloaded) {}
            PackCard(pack: packs[1], status: .downloading(0.4)) {}
        }
        PackRow(pack: packs[6], status: .notDownloaded) {}
            .erCard()
        PackRow(pack: packs[3], status: .updateAvailable) {}
            .erCard()
    }
    .padding(Theme.Spacing.page)
    .erPageBackground()
}

#Preview("深色") {
    let packs = PreviewData.packs
    VStack(alignment: .leading, spacing: 16) {
        PackCard(pack: packs[0], status: .notDownloaded) {}
        PackRow(pack: packs[6], status: .downloaded) {}
            .erCard()
    }
    .padding(Theme.Spacing.page)
    .erPageBackground()
    .preferredColorScheme(.dark)
}
