import SwiftUI

/// 行不折、整块横着滚（代码折了行就认不出缩进），行底铺到最长那一行（`UnifiedDiff.widest`），滚到哪颜色都连得上；只排看得见的那些行，几万行的改动也照样打开。
struct PreviewDiff: View {
    let file: URL
    @State private var viewport: CGFloat = 0

    var body: some View {
        PreviewTextFile(file: file, parse: UnifiedDiff.init) { diff in
            ScrollView([.horizontal, .vertical]) {
                let layout = DiffLayout(diff, viewport: viewport)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { DiffRow(line: $0, layout: layout) }
                }
                .padding(.vertical, Spacing.block)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
    }
}

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
                Text(verbatim: line.kind.sign).foregroundStyle(signColor).frame(width: Spacing.group)
                Text(verbatim: line.text).foregroundStyle(palette.ink).fixedSize()
            }
            .font(Typography.diff)
            .frame(width: layout.width, alignment: .leading)
            .background(line.kind.wash(palette))
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? "").foregroundStyle(palette.ink3).monospacedDigit()
            .padding(.trailing, Spacing.item)
            .frame(width: layout.number, alignment: .trailing)
            .readerHidden(true)
    }

    private var signColor: Color { if case .added = line.kind { palette.replied } else { palette.failure } }
}

/// 改动的符号与底色只在这里：全屏的改动与一步的详情共用。
extension UnifiedDiff.Line.Kind {
    var changed: Bool {
        switch self {
        case .added, .removed: true
        default: false
        }
    }

    var sign: String {
        switch self {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    func wash(_ palette: Palette) -> Color {
        switch self {
        case .added: palette.diffAdded
        case .removed: palette.diffRemoved
        default: .clear
        }
    }
}
