import SwiftUI
import PDFKit

/// PDF 頁面縮圖格：點一下選或取消。結果寫成頁碼字串（例如「1-3, 5」），全選時是空字串。
struct PDFPagePicker: View {
    let url: URL
    @Binding var pages: ParamValue

    @State private var thumbnails: [Int: UIImage] = [:]
    @State private var pageCount = 0
    @State private var selected: Set<Int> = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 10)]

    var body: some View {
        Section {
            if pageCount == 0 {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .frame(height: 120)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(1...pageCount, id: \.self) { number in
                            cell(number)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: pageCount > 6 ? 380 : 220)
            }
        } header: {
            HStack {
                Text("頁面")
                Spacer()
                if pageCount > 0 {
                    Button(selected.count == pageCount ? "全不選" : "全選") {
                        selected = selected.count == pageCount ? [] : Set(1...pageCount)
                        sync()
                    }
                    .font(.footnote)
                    .textCase(nil)
                }
            }
        } footer: {
            if pageCount > 0 {
                Text("已選 \(selected.count) / \(pageCount) 頁")
            }
        }
        .task(id: url) { await load() }
    }

    private func cell(_ number: Int) -> some View {
        let isOn = selected.contains(number)
        return Button {
            if isOn { selected.remove(number) } else { selected.insert(number) }
            sync()
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image = thumbnails[number] {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Rectangle().fill(.quaternary)
                                .aspectRatio(0.75, contentMode: .fit)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 120)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isOn ? Color.accentColor : Color.secondary.opacity(0.3),
                                          lineWidth: isOn ? 3 : 1)
                    )
                    .opacity(isOn ? 1 : 0.55)

                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isOn ? Color.white : Color.secondary, isOn ? Color.accentColor : Color.clear)
                        .background(Circle().fill(.background).padding(2))
                        .padding(4)
                }
                Text("\(number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(number) 頁")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func load() async {
        guard !loaded, let doc = PDFDocument(url: url) else { return }
        loaded = true
        let count = doc.pageCount
        pageCount = count
        guard count > 0 else { return }
        selected = Set(1...count)
        sync()
        for index in 0..<count {
            guard let page = doc.page(at: index) else { continue }
            let image = page.thumbnail(of: CGSize(width: 180, height: 240), for: .cropBox)
            thumbnails[index + 1] = image
            await Task.yield()
        }
    }

    /// 把選取的頁碼壓縮成「1-3, 5」這種寫法。
    private func sync() {
        guard pageCount > 0 else { return }
        if selected.count == pageCount { pages = .string(""); return }
        if selected.isEmpty { pages = .string("0"); return }
        var parts: [String] = []
        var runStart = 0
        var runEnd = 0
        for n in selected.sorted() {
            if runStart > 0 && n == runEnd + 1 { runEnd = n; continue }
            if runStart > 0 { parts.append(runStart == runEnd ? "\(runStart)" : "\(runStart)-\(runEnd)") }
            runStart = n
            runEnd = n
        }
        if runStart > 0 { parts.append(runStart == runEnd ? "\(runStart)" : "\(runStart)-\(runEnd)") }
        pages = .string(parts.joined(separator: ", "))
    }
}
