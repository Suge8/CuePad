import Foundation

/// 统一格式的改动（`git diff`、`diff -u` 的输出，.diff 与 .patch 预览，`PreviewDiff` 画它）拆成一行一行：每个文件一行抬头（路径与增删数）、
/// 每段一行段头（`@@ -a,b +c,d @@` 后面的上下文），其余是不变、增加、删去的行，带旧、新两边的行号。
/// 认不出文件抬头的（只贴了几段 `@@`）整份算一个没有路径的文件；`diff --git` 之后、第一段之前的 index、mode 等行不画。
/// 一对 `--- `/`+++ ` 只在段外才是文件抬头（`diff --git` 之后第一段之前、第一个文件之前，或上一段按 `@@` 的行数已经走完——
/// 不带 `diff --git` 的多文件 `diff -u`）：段里删去的一行以 "-- " 开头、接着加的一行以 "++ " 开头时，带上前缀也是这样一对，仍是改动。
nonisolated struct UnifiedDiff: Sendable {
    struct Line: Sendable, Identifiable {
        enum Kind: Sendable { case file(added: Int, removed: Int), hunk, context, added, removed, note }
        let id: Int
        let kind: Kind
        let text: String
        var old: Int?
        var new: Int?
    }

    let lines: [Line]
    /// 最长一行有多少格（汉字等全角字算两格）：行底铺到这么宽，横着滚到哪都连得上。
    let widest: Int

    init(_ source: String) {
        var lines: [Line] = []
        var file: Int?, added = 0, removed = 0, old = 0, new = 0
        // 这一段还剩几行旧、新两边的行没走完（`@@` 里的行数）
        var oldLeft = 0, newLeft = 0
        func add(_ kind: Line.Kind, _ text: String, old: Int? = nil, new: Int? = nil) {
            lines.append(Line(id: lines.count, kind: kind, text: text, old: old, new: new))
        }
        func closeFile() {
            if let file { lines[file] = Line(id: file, kind: .file(added: added, removed: removed), text: lines[file].text) }
            added = 0
            removed = 0
        }
        let rows = source.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        var index = 0
        func startFile(_ path: String) {
            closeFile()
            file = lines.count
            add(.file(added: 0, removed: 0), path)
        }
        while index < rows.count {
            let line = rows[index]
            index += 1
            // 还在文件抬头里（文件那一行之后、第一段之前）
            let inHeader = file.map { $0 == lines.count - 1 } ?? false
            if line.hasPrefix("diff --git ") {
                startFile(Self.path(fromGit: line))
            } else if line.hasPrefix("--- "), index < rows.count, rows[index].hasPrefix("+++ "), file == nil || inHeader || oldLeft <= 0 && newLeft <= 0 {
                let from = Self.path(line.dropFirst(4)), to = Self.path(rows[index].dropFirst(4))
                index += 1
                let shown = to == "/dev/null" ? from : to
                if inHeader, let file { lines[file] = Line(id: file, kind: lines[file].kind, text: shown) } else { startFile(shown) }
            } else if line.hasPrefix("@@") {
                if file == nil { startFile("") }
                (old, oldLeft, new, newLeft) = Self.ranges(line)
                let context = line.split(separator: "@@", maxSplits: 2, omittingEmptySubsequences: false)
                add(.hunk, context.count > 2 ? context[2].trimmingCharacters(in: .whitespaces) : "")
            } else if file == nil || inHeader {
                continue  // 第一段之前的说明，与文件抬头里的 index、mode、similarity 等
            } else if line.hasPrefix("+") {
                add(.added, String(line.dropFirst()), new: new)
                new += 1
                newLeft -= 1
                added += 1
            } else if line.hasPrefix("-") {
                add(.removed, String(line.dropFirst()), old: old)
                old += 1
                oldLeft -= 1
                removed += 1
            } else if line.hasPrefix("\\") {
                add(.note, line.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix(" ") || line.isEmpty {
                add(.context, String(line.dropFirst()), old: old, new: new)
                old += 1
                new += 1
                oldLeft -= 1
                newLeft -= 1
            }
        }
        closeFile()
        // 文件末尾那个换行切出的空行不是改动里的一行
        if let last = lines.last, case .context = last.kind, last.text.isEmpty { lines.removeLast() }
        self.lines = lines
        widest = lines.lazy.map { Self.cells($0.text) }.max() ?? 0
    }

    /// `diff --git a/x b/y` 取 b 那边（改名后的名字）。
    private static func path(fromGit line: String) -> String {
        guard let b = line.range(of: " b/", options: .backwards) else { return String(line.dropFirst("diff --git ".count)) }
        return String(line[b.upperBound...])
    }

    /// `--- a/x	时间` 去掉 a/、b/ 前缀与制表符后的时间。
    private static func path(_ text: Substring) -> String {
        let name = text.split(separator: "\t").first.map(String.init) ?? String(text)
        return name.hasPrefix("a/") || name.hasPrefix("b/") ? String(name.dropFirst(2)) : name
    }

    /// `@@ -12,5 +14,7 @@` 里旧、新两边的起始行号与行数（省掉的行数是 1）。
    private static func ranges(_ line: String) -> (Int, Int, Int, Int) {
        func range(_ marker: Character) -> (Int, Int) {
            guard let at = line.firstIndex(of: marker) else { return (1, 1) }
            let spec = line[line.index(after: at)...].prefix { $0.isNumber || $0 == "," }.split(separator: ",", omittingEmptySubsequences: false)
            return (spec.first.flatMap { Int($0) } ?? 1, spec.count > 1 ? Int(spec[1]) ?? 1 : 1)
        }
        let (old, new) = (range("-"), range("+"))
        return (old.0, old.1, new.0, new.1)
    }

    private static func cells(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.properties.isEmojiPresentation || $1.value >= 0x1100 && $1.properties.generalCategory == .otherLetter ? 2 : 1) }
    }
}
