import Foundation

/// 功能包：用 JSON 描述「哪些積木、用什麼參數、照什麼順序」。
/// 匯入後會出現在動作清單和捷徑裡，不用重新打包 App。
struct FeaturePack: Codable, Identifiable, Hashable, Sendable {
    struct Step: Codable, Hashable, Sendable {
        var op: String
        var params: [String: ParamValue]?
    }

    var id: String
    var title: String
    var subtitle: String?
    var systemImage: String?
    var accepts: [FileKind]
    var minInputs: Int?
    var parameters: [ParameterSpec]?
    var steps: [Step]
}

struct RecipeOperation: ToolOperation {
    let pack: FeaturePack

    var id: String { "pack." + pack.id }
    var title: String { pack.title }
    var subtitle: String { pack.subtitle ?? "功能包・\(pack.steps.count) 個步驟" }
    var systemImage: String { pack.systemImage ?? "puzzlepiece.extension" }
    var accepts: Set<FileKind> { Set(pack.accepts) }
    var minInputs: Int { pack.minInputs ?? 1 }
    var parameters: [ParameterSpec] { pack.parameters ?? [] }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        var current = inputs
        for (index, step) in pack.steps.enumerated() {
            guard let op = Registry.builtIn(id: step.op) else {
                throw ToolError("功能包用到不存在的積木：\(step.op)")
            }
            var values = Params.defaults(for: op.parameters)
            for (key, value) in step.params ?? [:] {
                if case .string(let text) = value, text.hasPrefix("$") {
                    let name = String(text.dropFirst())
                    if let provided = params.values[name] { values[key] = provided }
                } else {
                    values[key] = value
                }
            }
            context.report("步驟 \(index + 1)/\(pack.steps.count)：\(op.title)")
            let isLast = index == pack.steps.count - 1
            let dir = try isLast ? context.outputDirectory : Workspace.newDirectory("Steps")
            let stepContext = RunContext(outputDirectory: dir, report: context.report)
            current = try await op.run(inputs: current, params: Params(values: values), context: stepContext)
        }
        return current
    }
}

enum PackStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Packs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func loadAll() -> [FeaturePack] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(FeaturePack.self, from: data)
            }
            .sorted { $0.title < $1.title }
    }

    static func decode(_ data: Data) throws -> FeaturePack {
        let pack: FeaturePack
        do {
            pack = try JSONDecoder().decode(FeaturePack.self, from: data)
        } catch {
            throw ToolError("功能包格式不正確：\(error.localizedDescription)")
        }
        guard !pack.steps.isEmpty else { throw ToolError("功能包沒有任何步驟") }
        for step in pack.steps where Registry.builtIn(id: step.op) == nil {
            throw ToolError("功能包用到不存在的積木：\(step.op)。可能需要更新 App。")
        }
        return pack
    }

    @discardableResult
    static func install(from url: URL) throws -> FeaturePack {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try install(data: data)
    }

    @discardableResult
    static func install(data: Data) throws -> FeaturePack {
        let pack = try decode(data)
        let safeID = pack.id.replacingOccurrences(of: "/", with: "-")
        try data.write(to: folder.appendingPathComponent(safeID).appendingPathExtension("json"), options: .atomic)
        return pack
    }

    static func delete(_ pack: FeaturePack) {
        let safeID = pack.id.replacingOccurrences(of: "/", with: "-")
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(safeID).appendingPathExtension("json"))
    }

    static let sampleJSON = """
    {
      "id": "xpan-share",
      "title": "XPan 分享用",
      "subtitle": "裁成 XPan 比例、縮到 2048px、轉 JPG、移除位置",
      "systemImage": "pano",
      "accepts": ["image"],
      "parameters": [
        { "key": "quality", "title": "品質", "kind": "number",
          "min": 50, "max": 100, "step": 5, "unit": "%", "default": 85 }
      ],
      "steps": [
        { "op": "image.crop", "params": { "ratio": "65:24" } },
        { "op": "image.resize", "params": { "mode": "long", "longEdge": 2048, "format": "jpg", "quality": "$quality" } },
        { "op": "image.stripMetadata", "params": { "mode": "gps" } }
      ]
    }
    """
}
