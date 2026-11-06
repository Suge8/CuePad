import SwiftUI

/// 全屏页里的改动（diff、patch，两端同一个）：每个文件一行抬头（路径、增删数），每段一行段头，下面是旧、新两列行号与一行一行的改动——
/// 增加的垫淡石绿、删去的垫淡胭脂，不变的不垫。行不折、整块横着滚（代码折了行就认不出缩进），行底铺到最长那一行（`UnifiedDiff.widest`），
/// 滚到哪颜色都连得上；只排看得见的那些行，几万行的改动也照样打开。
struct PreviewDiff: View {
    let file: URL
    @State private var diff: UnifiedDiff?
    @State private var viewport: CGFloat = 0

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let diff {
                let layout = DiffLayout(diff, viewport: viewport)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { DiffRow(line: $0, layout: layout) }
                }
                .padding(.vertical, Spacing.block)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        .task(id: file) { diff = await Self.read(file) }
    }

    @concurrent private static func read(_ file: URL) async -> UnifiedDiff {
        UnifiedDiff((try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }
}

/// 一份改动的版面：行号那两列多宽（最大的行号几位），一行铺多宽（至少看得见的宽，最长一行更宽时按它）。
struct DiffLayout {
    let number: CGFloat
    let width: CGFloat

    init(_ diff: UnifiedDiff, viewport: CGFloat) {
        let largest = diff.lines.lazy.compactMap { max($0.old ?? 0, $0.new ?? 0) }.max() ?? 0
        number = CGFloat(max(String(largest).count, 2)) * Typography.diffCell + 2 * Spacing.item
        let text = CGFloat(diff.widest + 2) * Typography.diffCell
        width = max(viewport, 2 * number + text + 2 * Spacing.group)
    }
}

/// 改动的一行（全屏页与缩略图同一个）。
struct DiffRow: View {
    let line: UnifiedDiff.Line
    let layout: DiffLayout
    @Environment(\.palette) private var palette

    var body: some View {
        switch line.kind {
        case .file(let added, let removed):
            HStack(spacing: Spacing.item) {
                Text(line.text.isEmpty ? String(localized: "改动") : line.text).font(Typography.diffStrong).foregroundStyle(palette.ink)
                Text(verbatim: "+\(added)").font(Typography.diff).foregroundStyle(palette.replied)
                Text(verbatim: "−\(removed)").font(Typography.diff).foregroundStyle(palette.failure)
            }
            .padding(.horizontal, Spacing.group).padding(.vertical, Spacing.item)
            .frame(width: layout.width, alignment: .leading)
            .background(palette.fill)
            .padding(.top, line.id == 0 ? 0 : Spacing.block)
            .accessibilityElement(children: .combine)
        case .hunk:
            Text(verbatim: line.text.isEmpty ? "⋯" : "⋯ \(line.text)").font(Typography.diff).foregroundStyle(palette.ink3).lineLimit(1)
                .padding(.leading, 2 * layout.number + Spacing.group).padding(.vertical, Spacing.tight)
                .frame(width: layout.width, alignment: .leading)
        case .note:
            Text(verbatim: line.text).font(Typography.diff).foregroundStyle(palette.ink3).italic()
                .padding(.leading, 2 * layout.number + Spacing.group)
                .frame(width: layout.width, alignment: .leading)
        case .context, .added, .removed:
            HStack(spacing: 0) {
                number(line.old)
                number(line.new)
                Text(verbatim: sign).foregroundStyle(signColor).frame(width: Spacing.group)
                Text(verbatim: line.text).foregroundStyle(palette.ink).fixedSize()
            }
            .font(Typography.diff)
            .frame(width: layout.width, alignment: .leading)
            .background(wash)
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? "").foregroundStyle(palette.ink3).monospacedDigit()
            .padding(.trailing, Spacing.item)
            .frame(width: layout.number, alignment: .trailing)
            .readerHidden(true)
    }

    private var sign: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var signColor: Color { if case .added = line.kind { palette.replied } else { palette.failure } }

    private var wash: Color {
        switch line.kind {
        case .added: palette.diffAdded
        case .removed: palette.diffRemoved
        default: .clear
        }
    }
}
