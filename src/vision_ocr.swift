import Foundation
import Vision
import AppKit

// Vision OCR -> TSV: x  y  w  h  confidence  text
// Usage: swift vision_ocr.swift <image> [--nocorrect]

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("usage: vision_ocr.swift <image> [--nocorrect]\n".data(using: .utf8)!)
    exit(2)
}
let path = args[1]
let useCorrection = !args.contains("--nocorrect")

guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot load image: \(path)\n".data(using: .utf8)!)
    exit(1)
}

let pxW = Double(cgImage.width)
let pxH = Double(cgImage.height)
FileHandle.standardError.write("image: \(cgImage.width)x\(cgImage.height)\n".data(using: .utf8)!)

let sem = DispatchSemaphore(value: 0)
var lines: [String] = []

let request = VNRecognizeTextRequest { req, err in
    defer { sem.signal() }
    if let err = err {
        FileHandle.standardError.write("error: \(err)\n".data(using: .utf8)!)
        return
    }
    guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
    // top-to-bottom, then left-to-right (Vision origin is bottom-left)
    let sorted = obs.sorted { a, b in
        if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.008 {
            return a.boundingBox.midY > b.boundingBox.midY
        }
        return a.boundingBox.minX < b.boundingBox.minX
    }
    for o in sorted {
        guard let c = o.topCandidates(1).first else { continue }
        let b = o.boundingBox
        // convert normalized -> pixels, origin top-left
        let x = b.minX * pxW
        let y = (1.0 - b.maxY) * pxH
        let w = b.width * pxW
        let h = b.height * pxH
        let txt = c.string.replacingOccurrences(of: "\t", with: " ")
        lines.append(String(format: "%.1f\t%.1f\t%.1f\t%.1f\t%.4f\t%@", x, y, w, h, c.confidence, txt))
    }
}

request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
request.usesLanguageCorrection = useCorrection
request.revision = VNRecognizeTextRequestRevision3

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
DispatchQueue.global().async {
    do { try handler.perform([request]) }
    catch { FileHandle.standardError.write("perform failed: \(error)\n".data(using: .utf8)!); sem.signal() }
}
sem.wait()

print(lines.joined(separator: "\n"))
FileHandle.standardError.write("lines: \(lines.count)  languageCorrection: \(useCorrection)\n".data(using: .utf8)!)
