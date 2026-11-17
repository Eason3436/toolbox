import SwiftUI
import MapKit
import Photos
import ImageIO

/// 照片詳情：拍攝資訊、檔案、地圖。背景是這張照片的模糊版本。
struct PhotoDetailView: View {
    let asset: PHAsset

    @Environment(\.dismiss) private var dismiss
    @State private var exif: ExifSummary?
    @State private var fileSize: Int64?
    @State private var filename: String?
    @State private var place: PlaceLookup.Place?
    @State private var loadingExif = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    cameraSection
                    fileSection
                    if let location = asset.location {
                        locationSection(location)
                    }
                }
                .padding(20)
            }
            .background {
                AssetImage(asset: asset, targetSize: CGSize(width: 300, height: 300))
                    .blur(radius: 50)
                    .overlay(Color(.systemBackground).opacity(0.55))
                    .ignoresSafeArea()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .task { await load() }
        .task {
            if let location = asset.location {
                place = await PlaceLookup.shared.place(for: location)
            }
        }
    }

    // MARK: - 區塊

    private var header: some View {
        VStack(spacing: 4) {
            Text(RelativeDay.text(for: asset.takenAt))
                .font(.largeTitle.bold())
            Text(asset.takenAt.formatted(.dateTime.year().month().day().weekday(.wide).hour().minute()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var cameraSection: some View {
        DetailCard(title: "拍攝", systemImage: "camera") {
            if let exif {
                if let device = exif.device {
                    Text(device).font(.headline)
                }
                if let lens = exif.lens {
                    Text(lens).font(.footnote).foregroundStyle(.secondary)
                }
                let shown = exif.parameters
                if shown.isEmpty {
                    Text("沒有拍攝參數").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 0) {
                        ForEach(shown) { item in
                            VStack(spacing: 2) {
                                Text(item.value)
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Text(item.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 4)
                }
            } else if loadingExif {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("讀不到拍攝資訊").foregroundStyle(.secondary)
            }
        }
    }

    private var fileSection: some View {
        DetailCard(title: "檔案", systemImage: "doc") {
            InfoRow(label: "檔名", value: filename ?? "—")
            InfoRow(label: "解析度", value: resolution)
            InfoRow(label: "大小", value: fileSize.map { $0.formatted(.byteCount(style: .file)) } ?? "—")
        }
    }

    private func locationSection(_ location: CLLocation) -> some View {
        DetailCard(title: "位置", systemImage: "mappin.and.ellipse") {
            Map(initialPosition: .region(MKCoordinateRegion(center: location.coordinate,
                                                             latitudinalMeters: 800, longitudinalMeters: 800)),
                interactionModes: []) {
                Marker("", coordinate: location.coordinate)
            }
            .frame(height: 160)
            .clipShape(.rect(cornerRadius: 12))

            if let full = place?.full {
                Text(full)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let district = place?.district {
                InfoRow(label: "行政區", value: district)
            }
            if location.verticalAccuracy >= 0 {
                InfoRow(label: "海拔", value: Measurement(value: location.altitude, unit: UnitLength.meters)
                    .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))))
            }
        }
    }

    private var resolution: String {
        let w = asset.pixelWidth
        let h = asset.pixelHeight
        let mp = Double(w * h) / 1_000_000
        return "\(w.formatted(.number.grouping(.never))) × \(h.formatted(.number.grouping(.never)))・\(mp.formatted(.number.precision(.fractionLength(0...1)))) MP"
    }

    // MARK: - 讀取

    private func load() async {
        let asset = asset
        async let info: (Int64, String?) = Task.detached {
            (PhotoLibrary.fileSize(of: asset), PhotoLibrary.originalFilename(of: asset))
        }.value
        let props = await Self.properties(of: asset)
        exif = props.map(ExifSummary.init(properties:))
        loadingExif = false
        let (size, name) = await info
        fileSize = size
        filename = name
    }

    /// 原檔的 ImageIO 屬性（iCloud 上的會先下載）
    private static func properties(of asset: PHAsset) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, _ in
                guard let url = input?.fullSizeImageURL,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: props)
            }
        }
    }
}

/// 詳情頁的一塊卡片
private struct DetailCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
