#if canImport(Vision)
import CoreGraphics
import Foundation
import ImageIO
import OCRCore
import Vision

// macOS Vision 文字识别。参数与输出顺序和 python-final:src/vision_ocr.swift保持一致，
// Phase 2 门槛是两者逐行相同；Vision 由系统自行调度 ANE / GPU。
//
// 注意：Vision 的置信度只有 0.3 / 0.5 / 1.0 三档，与对错无关，不能当错误信号（CLAUDE.md 不变量）。

public struct VisionOptions: Sendable {
    public var languages: [String] = ["zh-Hans", "zh-Hant", "en-US"]
    public var languageCorrection = true
    public init() {}
}

public enum VisionEngineError: Error, CustomStringConvertible {
    case cannotLoad(String)

    public var description: String {
        switch self {
        case .cannotLoad(let p): return "cannot load image: \(p)"
        }
    }
}

public enum VisionEngine {
    public static func loadImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw VisionEngineError.cannotLoad(url.path)
        }
        return img
    }

    /// 识别一张图，返回像素坐标（原点左上）的行，顺序与 bin/vision-ocr 相同：
    /// 中心 y 相差超过 0.008（归一化）按上到下，否则按左到右。
    public static func recognize(_ image: CGImage, options: VisionOptions = VisionOptions()) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = options.languages
        request.usesLanguageCorrection = options.languageCorrection
        request.revision = VNRecognizeTextRequestRevision3
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let obs = (request.results ?? []).sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.008 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        let pxW = Double(image.width), pxH = Double(image.height)
        return obs.compactMap { o in
            guard let c = o.topCandidates(1).first else { return nil }
            let b = o.boundingBox
            return Line(x: b.minX * pxW, y: (1.0 - b.maxY) * pxH,
                        w: b.width * pxW, h: b.height * pxH,
                        conf: Double(c.confidence), text: c.string)
        }
    }
}
#endif
