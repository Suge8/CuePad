import SwiftUI

/// 短代码片段作为一个排版单元，仍然是真实文字；不向复制内容塞入不换行空格或零宽字符。
struct MarkdownInlineText: View {
    let text: AttributedString

    var body: some View {
        if text.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) {
            InlineFlow(lineSpacing: Typography.readingLineSpacing) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                    Text(piece)
                        .layoutValue(key: InlineBreak.self, value: piece.characters.contains("\n"))
                        .layoutValue(key: InlineSpace.self, value: piece.characters.allSatisfy(\.isWhitespace))
                }
            }
        } else { Text(text) }
    }

    private var pieces: [AttributedString] {
        var result: [AttributedString] = []
        for run in text.runs {
            let fragment = AttributedString(text[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true { result.append(fragment); continue }
            let source = String(fragment.characters)
            var cursor = source.startIndex
            func append(_ range: Range<String.Index>) {
                guard !range.isEmpty else { return }
                let start = source[..<range.lowerBound].utf16.count
                let length = source[range].utf16.count
                if let range = Range(NSRange(location: start, length: length), in: fragment) { result.append(AttributedString(fragment[range])) }
            }
            source.enumerateSubstrings(in: source.startIndex..., options: .byWords) { _, range, _, _ in
                for index in source[cursor..<range.lowerBound].indices {
                    append(index..<source.index(after: index))
                }
                append(range)
                cursor = range.upperBound
            }
            for index in source[cursor...].indices { append(index..<source.index(after: index)) }
        }
        return result
    }
}

nonisolated private struct InlineBreak: LayoutValueKey { static let defaultValue = false }
nonisolated private struct InlineSpace: LayoutValueKey { static let defaultValue = false }

private struct InlineFlow: Layout {
    let lineSpacing: CGFloat
    struct Placement { let point: CGPoint; let size: CGSize }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let positions = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: positions.map { $0.point.x + $0.size.width }.max() ?? 0,
                      height: positions.map { $0.point.y + $0.size.height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, placement) in zip(subviews, arrange(width: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + placement.point.x, y: bounds.minY + placement.point.y),
                       proposal: ProposedViewSize(placement.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Placement] {
        var result: [Placement] = []
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, baseline: CGFloat = 0
        var start = 0
        func finishLine() {
            for index in start..<result.count {
                guard result[index].size != .zero else { continue }
                let dimensions = subviews[index].dimensions(in: ProposedViewSize(result[index].size))
                result[index] = Placement(point: CGPoint(x: result[index].point.x, y: y + baseline - dimensions[.firstTextBaseline]), size: result[index].size)
            }
            y += height + lineSpacing
            x = 0; height = 0; baseline = 0; start = result.count
        }
        for view in subviews {
            if view[InlineBreak.self] { finishLine(); result.append(Placement(point: CGPoint(x: 0, y: y), size: .zero)); start = result.count; continue }
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0, x + size.width > width { finishLine() }
            if x == 0, view[InlineSpace.self] { result.append(Placement(point: CGPoint(x: 0, y: y), size: .zero)); continue }
            let dimensions = view.dimensions(in: ProposedViewSize(size))
            baseline = max(baseline, dimensions[.firstTextBaseline])
            height = max(height, size.height)
            result.append(Placement(point: CGPoint(x: x, y: y), size: size))
            x += size.width
        }
        finishLine()
        return result
    }
}
