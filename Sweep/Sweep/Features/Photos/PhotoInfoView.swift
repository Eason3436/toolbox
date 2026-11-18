import SwiftUI
import MapKit
import Photos
import ImageIO

/// 照片背面：拍攝資訊、檔案、地圖。點一下照片翻過來就是這一面，背景是這張照片的模糊版本。
struct PhotoInfoView: View {
    let asset: PHAsset
    /// 翻到這一面了：這時才允許從 iCloud 下載原檔讀 EXIF（平常只先讀手機上有的）
    var isActive = false

    @State private var exif: ExifSummary?
    @State private var fileSize: Int64?
    @State private var filename: String?
    @State private var place: PlaceLookup.Place?
    @State private var loadingExif = true

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                cameraSection
                fileSection
                if let location = asset.location {
                    locationSection(location)
                }
                Label("點一下翻回照片", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background {
            ZStack {
                Color.black
                AssetImage(asset: asset, targetSize: CGSize(width: 200, height: 200), showsProgress: false)
                    .scaleEffect(1.3)
                    .blur(radius: 40)
                    .opacity(0.8)
                Color.black.opacity(0.35)
            }
        }
        // 卡片一到最上面就先在背景讀好，翻面時不用等、也不會卡
        .task(id: isActive) { await load(network: isActive) }
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
                .font(.title.bold())
            Text(asset.takenAt.formatted(.dateTime.year().month().day().weekday(.wide).hour().minute()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
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
            // 用靜態截圖，不放即時地圖：翻轉時才不會卡
            MapSnapshot(coordinate: location.coordinate)

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

    private func load(network: Bool) async {
        let asset = asset
        if fileSize == nil {
            let (size, name) = await Task.detached(priority: .utility) {
                (PhotoLibrary.fileSize(of: asset), PhotoLibrary.originalFilename(of: asset))
            }.value
            fileSize = size
            filename = name
        }
        guard exif == nil else { return }
        if network { loadingExif = true }
        if let props = await Self.properties(of: asset, network: network) {
            exif = props
        }
        // 沒下載過的 iCloud 照片：翻到背面才去下載
        loadingExif = exif == nil && !network
    }

    /// 原檔的 ImageIO 屬性。讀檔、解析都在背景，不佔主執行緒
    private static func properties(of asset: PHAsset, network: Bool) async -> ExifSummary? {
        await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = network
            asset.requestContentEditingInput(with: options) { input, _ in
                let url = input?.fullSizeImageURL
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let url,
                          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: ExifSummary(properties: props))
                }
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
        // 不用毛玻璃：翻轉動畫每一格都要重算模糊，會卡
        .background(.white.opacity(0.1), in: .rect(cornerRadius: 18))
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

/// 地圖截圖：中間放一根大頭針
private struct MapSnapshot: View {
    let coordinate: CLLocationCoordinate2D

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
                Image(systemName: "mappin.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .shadow(color: .black.opacity(0.3), radius: 3)
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 12))
        .task {
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)
            options.size = CGSize(width: 420, height: 150)
            options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            let shot = try? await MKMapSnapshotter(options: options).start()
            withAnimation(.easeOut(duration: 0.2)) { image = shot?.image }
        }
    }
}
