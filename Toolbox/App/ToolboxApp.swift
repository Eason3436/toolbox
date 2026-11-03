import SwiftUI

@main
struct ToolboxApp: App {
    @State private var model = AppModel()

    init() {
        Workspace.cleanUp()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
                .onOpenURL { url in model.add(urls: [url]) }
        }
    }
}

@Observable
@MainActor
final class AppModel {
    var files: [InputFile] = []
    var banner: String?
    var packsVersion = 0

    var kinds: [FileKind] { files.map(\.kind) }

    /// 外部檔案：先複製進 App。功能包（.json）直接安裝。
    func add(urls: [URL]) {
        for url in urls {
            // 看起來像功能包的 JSON 直接安裝，其他 JSON 當一般檔案處理。
            if FileKind.detect(url) == .json, Self.looksLikePack(url) {
                installPack(from: url)
                continue
            }
            do {
                let copy = try Workspace.importCopy(of: url)
                files.append(InputFile(url: copy, kind: FileKind.detect(copy)))
            } catch {
                banner = "無法加入 \(url.lastPathComponent)：\(error.localizedDescription)"
            }
        }
    }

    /// 已經在 App 暫存區裡的檔案。
    func addLocal(_ urls: [URL]) {
        files.append(contentsOf: urls.map { InputFile(url: $0, kind: FileKind.detect($0)) })
    }

    /// 從相簿挑的照片，順便記下識別碼和是不是原況照片。
    func addPhotos(_ items: [(url: URL, assetID: String?, isLive: Bool)]) {
        files.append(contentsOf: items.map {
            InputFile(url: $0.url, kind: FileKind.detect($0.url), assetID: $0.assetID, isLivePhoto: $0.isLive)
        })
    }

    var livePhotoIDs: [String] {
        files.filter(\.isLivePhoto).compactMap(\.assetID)
    }

    func replace(with urls: [URL]) {
        files = urls.map { InputFile(url: $0, kind: FileKind.detect($0)) }
    }

    func remove(at offsets: IndexSet) {
        files.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int) {
        files.move(fromOffsets: source, toOffset: destination)
    }

    func clear() {
        files.removeAll()
    }

    nonisolated static func looksLikePack(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return false }
        return (try? PackStore.decode(data)) != nil
    }

    func installPack(from url: URL) {
        do {
            let pack = try PackStore.install(from: url)
            packsVersion += 1
            banner = "已安裝功能包「\(pack.title)」"
        } catch {
            banner = error.localizedDescription
        }
    }
}
