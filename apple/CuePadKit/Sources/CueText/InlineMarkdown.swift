import Foundation

extension AttributedString {
    /// 行内 Markdown（强调、代码、链接）解析成带属性的文字，所有显示与取纯文字的地方都走这里；强调按 markdown-cjk-friendly
    /// 的规则认，`**额度：**已用` 与 `中**「引」**文` 也加粗。
    ///
    /// 系统解析器（cmark）的定界规则改不了，只能改它看到的字：按该规则，`*` 串两边都不是空白、至少一边是 CJK 字时
    /// 既能开也能收；cmark 只在两边同为标点或同为非标点时这么认，所以一边是标点、一边不是时，在标点那一侧塞一个
    /// 不算标点也不算空白的占位字，解析完删掉。`_` 不用补：两套规则在 CJK 旁的结果本来一样。
    public init(inlineMarkdown text: String) {
        let (source, padded) = InlineMarkdown.pad(text)
        var string = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        if padded {
            while let i = string.unicodeScalars.firstIndex(of: InlineMarkdown.filler) { string.unicodeScalars.remove(at: i) }
        }
        self = string
    }
}

enum InlineMarkdown {
    /// 私用区字符：cmark 眼里既不是标点也不是空白，回复里也不会出现。
    static let filler: Unicode.Scalar = "\u{E000}"

    static func pad(_ text: String) -> (String, Bool) {
        guard text.contains("*") else { return (text, false) }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var padded = false
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "\\", i + 1 < scalars.count {
                out.append(contentsOf: scalars[i...i + 1])
                i += 2
                continue
            }
            guard scalar == "*" else {
                out.append(scalar)
                i += 1
                continue
            }
            var end = i
            while end < scalars.count, scalars[end] == "*" { end += 1 }
            let before = i > 0 ? scalars[i - 1] : nil
            let after = end < scalars.count ? scalars[end] : nil
            let side = fillSide(before: before, after: after)
            if side == .before { out.append(filler) }
            out.append(contentsOf: scalars[i..<end])
            if side == .after { out.append(filler) }
            padded = padded || side != nil
            i = end
        }
        return (String(out), padded)
    }

    /// 装饰源文时只淡化系统解析器实际移除的强调符号；转义星号与代码里的符号仍是正文。
    /// 源位置以 UTF-8 列计数，映回编辑器的 UTF-16 范围时跳过 CJK 适配占位字。
    static func emphasisMarkers(in text: String) -> [NSRange] {
        guard text.contains("*") || text.contains("_") else { return [] }
        let (source, _) = pad(text)
        guard let parsed = try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, appliesSourcePositionAttributes: true)) else { return [] }
        var content = IndexSet()
        for run in parsed.runs {
            if let position = run.markdownSourcePosition {
                content.insert(integersIn: (position.startColumn - 1)..<position.endColumn)
            }
        }
        var ranges: [NSRange] = [], byte = 0, offset = 0
        for scalar in source.unicodeScalars {
            defer { byte += scalar.utf8.count }
            guard scalar != filler else { continue }
            if (scalar == "*" || scalar == "_"), !content.contains(byte) {
                ranges.append(NSRange(location: offset, length: 1))
            }
            offset += scalar.utf16.count
        }
        return ranges
    }

    private enum Side { case before, after }

    /// 该在 `*` 串的哪一侧塞占位字：两边都不是空白（行首行尾算空白）、至少一边是 CJK 字、恰好一边是 cmark 认的标点时，塞在标点那侧。
    private static func fillSide(before: Unicode.Scalar?, after: Unicode.Scalar?) -> Side? {
        guard let before, let after, !before.properties.isWhitespace, !after.properties.isWhitespace,
              isCJK(before) || isCJK(after) else { return nil }
        switch (isPunctuation(before), isPunctuation(after)) {
        case (true, false): return .before
        case (false, true): return .after
        default: return nil
        }
    }

    /// cmark 认的标点：ASCII 标点与 Unicode P 类（不含 `€` 这类符号，与 CommonMark 0.31 不同）。
    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return asciiPunctuation.contains { $0.contains(scalar.value) } }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    private static let asciiPunctuation: [ClosedRange<UInt32>] = [0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E]

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return cjkRanges.contains { $0.contains(value) }
    }

    /// markdown-cjk-friendly 的「CJK 字」（Unicode 18，东亚宽度 W/F/H 且非默认 emoji，或谚文），取自它的 ranges.md。
    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x1100...0x11FF, 0x20A9...0x20A9, 0x2329...0x232A, 0x2630...0x2637, 0x268A...0x268F, 0x2E80...0x2E99, 0x2E9B...0x2EF3,
        0x2F00...0x2FD5, 0x2FF0...0x303E, 0x3041...0x3096, 0x3099...0x30FF, 0x3105...0x312F, 0x3131...0x318E, 0x3190...0x31E5,
        0x31EF...0x321E, 0x3220...0x3247, 0x3250...0xA48C, 0xA490...0xA4C6, 0xA960...0xA97C, 0xAC00...0xD7A3, 0xD7B0...0xD7C6,
        0xD7CB...0xD7FB, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE52, 0xFE54...0xFE66, 0xFE68...0xFE6B, 0xFF01...0xFFBE,
        0xFFC2...0xFFC7, 0xFFCA...0xFFCF, 0xFFD2...0xFFD7, 0xFFDA...0xFFDC, 0xFFE0...0xFFE6, 0xFFE8...0xFFEE,
        0x16FE0...0x16FE4, 0x16FF0...0x16FF6, 0x17000...0x18CDA, 0x18CFF...0x18D20, 0x18D80...0x18DF2, 0x18E00...0x19191,
        0x191A0...0x191D2, 0x1AFF0...0x1AFF3, 0x1AFF5...0x1AFFB, 0x1AFFD...0x1AFFE, 0x1B000...0x1B128, 0x1B132...0x1B132,
        0x1B150...0x1B152, 0x1B155...0x1B155, 0x1B164...0x1B168, 0x1B170...0x1B2FB, 0x1D300...0x1D356, 0x1D360...0x1D376,
        0x1F1AE...0x1F1AE, 0x1F200...0x1F200, 0x1F202...0x1F202, 0x1F210...0x1F219, 0x1F21B...0x1F22E, 0x1F230...0x1F231,
        0x1F237...0x1F237, 0x1F23B...0x1F23B, 0x1F240...0x1F248, 0x1F260...0x1F265, 0x1F7DA...0x1F7DA, 0x20000...0x3FFFD,
    ]
}
