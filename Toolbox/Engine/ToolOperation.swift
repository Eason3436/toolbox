import Foundation

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum OperationEditor: Sendable {
    case none
    case crop
}

struct RunContext: Sendable {
    let outputDirectory: URL
    let report: @Sendable (String) -> Void

    func output(for input: URL, suffix: String = "", ext: String) -> URL {
        let base = input.deletingPathExtension().lastPathComponent + suffix
        return Workspace.uniqueURL(in: outputDirectory, base: base, ext: ext)
    }

    func output(named base: String, ext: String) -> URL {
        Workspace.uniqueURL(in: outputDirectory, base: base, ext: ext)
    }
}

/// 一個「積木」：吃一組檔案和參數，吐出一組檔案。
/// 內建功能、捷徑動作、功能包都是用積木組成。
protocol ToolOperation: Sendable {
    var id: String { get }
    var title: String { get }
    var subtitle: String { get }
    var systemImage: String { get }
    var accepts: Set<FileKind> { get }
    var minInputs: Int { get }
    var parameters: [ParameterSpec] { get }
    var editor: OperationEditor { get }
    func isAvailable(for kinds: [FileKind]) -> Bool
    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL]
}

extension ToolOperation {
    var subtitle: String { "" }
    var minInputs: Int { 1 }
    var editor: OperationEditor { .none }

    func isAvailable(for kinds: [FileKind]) -> Bool {
        !kinds.isEmpty && kinds.count >= minInputs && Set(kinds).isSubset(of: accepts)
    }

    /// 一個一個處理，並回報進度。
    func eachInput(_ inputs: [URL], _ context: RunContext,
                   _ body: (URL) async throws -> [URL]) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            if inputs.count > 1 {
                context.report("處理中 \(index + 1)/\(inputs.count)：\(input.lastPathComponent)")
            } else {
                context.report("處理中：\(input.lastPathComponent)")
            }
            let count = Double(inputs.count)
            let produced = try await ProgressScope.slice(start: Double(index) / count, length: 1 / count) {
                try await body(input)
            }
            outputs.append(contentsOf: produced)
        }
        ProgressScope.report?(1)
        return outputs
    }
}

struct OperationBox: Identifiable {
    let op: any ToolOperation
    var id: String { op.id }
}

enum Runner {
    static func run(_ op: any ToolOperation, inputs: [URL], values: [String: ParamValue],
                    progress: (@Sendable (Double) -> Void)? = nil,
                    report: @escaping @Sendable (String) -> Void) async throws -> [URL] {
        let dir = try Workspace.newDirectory("Outputs")
        let context = RunContext(outputDirectory: dir, report: report)
        let params = Params(values: values)
        let work = Task.detached(priority: .userInitiated) {
            try await ProgressScope.$report.withValue(progress) {
                try await op.run(inputs: inputs, params: params, context: context)
            }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
