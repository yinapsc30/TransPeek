// Vision OCR 验证脚本：对图片跑识别，输出文字、置信度和耗时
// 用法：swift verify/vision_ocr.swift <图片路径>... [--fast] [--runs N]
import Foundation
import Vision
import AppKit

var paths: [String] = []
var level: VNRequestTextRecognitionLevel = .accurate
var runs = 5
var it = CommandLine.arguments.dropFirst().makeIterator()
while let arg = it.next() {
    switch arg {
    case "--fast": level = .fast
    case "--runs": runs = Int(it.next() ?? "5") ?? 5
    default: paths.append(arg)
    }
}

func loadCGImage(_ path: String) -> CGImage? {
    guard let img = NSImage(contentsOfFile: path) else { return nil }
    var rect = CGRect(origin: .zero, size: img.size)
    return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

func recognize(_ image: CGImage) throws -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    return request.results ?? []
}

for path in paths {
    guard let image = loadCGImage(path) else { print("无法读取: \(path)"); continue }
    print("== \((path as NSString).lastPathComponent)  \(image.width)x\(image.height)  level=\(level == .fast ? "fast" : "accurate")")

    _ = try recognize(image) // 预热，首次调用包含模型加载
    var times: [Double] = []
    var results: [VNRecognizedTextObservation] = []
    for _ in 0..<runs {
        let t0 = CFAbsoluteTimeGetCurrent()
        results = try recognize(image)
        times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }
    // Vision 坐标原点在左下角，按 y 从上到下排序
    for obs in results.sorted(by: { $0.boundingBox.maxY > $1.boundingBox.maxY }) {
        guard let top = obs.topCandidates(1).first else { continue }
        print(String(format: "  [%.2f] %@", top.confidence, top.string))
    }
    let avg = times.reduce(0, +) / Double(times.count)
    print(String(format: "  耗时: 平均 %.1f ms, 最小 %.1f ms (%d 次)\n", avg, times.min() ?? 0, runs))
}
