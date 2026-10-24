import CoreGraphics
import Foundation

/// 组装后的一行文本。
public struct OCRLine: Sendable, Equatable {
    public let text: String
    /// 行内所有片段的外接矩形，归一化，原点左上。
    public let box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// 把 OCR 片段组装为按从上到下排列的行（R6.3、R6.4、R6.5、R4.8）。
public struct LineAssembler: Sendable {
    public var confidenceThreshold: Float
    /// 垂直重叠占较矮一方高度的比例达到该值时归入同一行。
    public var overlapRatio: CGFloat

    public init(confidenceThreshold: Double = 0.3, overlapRatio: CGFloat = 0.5) {
        self.confidenceThreshold = Float(confidenceThreshold)
        self.overlapRatio = overlapRatio
    }

    public func assemble(_ fragments: [OCRFragment], ignoring rules: IgnoreRules = IgnoreRules(patterns: [])) -> [OCRLine] {
        let kept = fragments
            .filter { $0.confidence >= confidenceThreshold && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.box.midY < $1.box.midY }

        var groups: [(box: CGRect, fragments: [OCRFragment])] = []
        for fragment in kept {
            if let index = groups.indices.last, belongsToLine(fragment.box, line: groups[index].box) {
                groups[index].box = groups[index].box.union(fragment.box)
                groups[index].fragments.append(fragment)
            } else {
                groups.append((fragment.box, [fragment]))
            }
        }

        return groups.compactMap { group in
            let joined = group.fragments
                .sorted { $0.box.minX < $1.box.minX }
                .map(\.text)
                .joined(separator: " ")
            let text = rules.apply(to: TextNormalizer.normalize(joined))
            return text.isEmpty ? nil : OCRLine(text: text, box: group.box)
        }
    }

    private func belongsToLine(_ box: CGRect, line: CGRect) -> Bool {
        let overlap = min(box.maxY, line.maxY) - max(box.minY, line.minY)
        let shorter = min(box.height, line.height)
        guard shorter > 0 else { return false }
        return overlap >= shorter * overlapRatio
    }
}
