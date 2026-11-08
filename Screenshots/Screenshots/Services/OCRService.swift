import UIKit
import Vision

/// Vision 文字辨識（繁體中文＋英文）。
enum OCRService {
    static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hant"),
            Locale.Language(identifier: "en-US"),
        ]
        let observations = try await request.perform(on: cgImage)
        // 依畫面由上到下排列，每個區塊一行
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
