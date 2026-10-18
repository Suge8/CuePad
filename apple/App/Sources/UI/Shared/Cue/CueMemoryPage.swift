import CueStore
import SwiftUI

/// "Cue 记得什么"（Cue 页"⋯"打开的弹层）：没忘掉的记忆分两组，"一直记着"（钉住的）与其他，各按时间从新到旧；
/// 最上面一行你自己记一条（记为你记的）。一条超过 `CueMemoryLine.maxBytes` 字节时就地说明、不写。
/// 每条一行占满宽度，时间与"你记的"是正文后面一小截淡字：一屏要看得到十来条，操作不常驻、不占一列。
/// 钉住与忘掉（另有复制）按平台惯例收起：手机右滑钉住、左滑忘掉、长按出菜单；Mac 右键出菜单，指针停在一行时铺行的淡底（`RowStyle`）、右下角露出两颗小钮。
/// 一组记忆拼成一张纸（`rowPaper`），行铺满纸。
/// 忘掉先确认：库里忘掉是软删、界面上没有拨回去的路。
struct CueMemoryPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var memory: CueMemory?
    @State private var text = ""
    @State private var forgetting: CueMemoryLine?
    @FocusState private var adding: Bool

    private var title: String { "\(workspace.cue.name) 记得什么" }
    private var kept: [CueMemoryLine] { (memory?.lines ?? []).filter { $0.deletedAt == nil }.reversed() }
    /// 有字但记不成一条（`CueMemoryLine.fits`：写入时同一个判断）。
    private var tooLong: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !CueMemoryLine.fits(text) }

    var body: some View {
        content
            .observing(services.store, into: $memory, onError: workspace.fail) { try $0.cueMemory() }
            .dialog("忘掉这一条？", item: $forgetting, message: "\(workspace.cue.name) 之后不再记得它，找不回来") { line in
                [DialogButton(title: "忘掉", role: .destructive) { workspace.forgetCueLine(line.id) }]
            }
    }

    private var list: some View {
        let kept = kept, pinned = kept.filter(\.pinned), others = kept.filter { !$0.pinned }
        return ScrollView {
            VStack(alignment: .leading, spacing: Metrics.groupGap) {
                field
                if !pinned.isEmpty { group("一直记着", pinned) }
                if !others.isEmpty { group(pinned.isEmpty ? nil : "其他", others) }
                if memory != nil, kept.isEmpty {
                    Text("还没记住什么。你说过的要紧事，它会自己记下").font(Typography.secondary).foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
            .padding(Metrics.margin)
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: kept)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(.add).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink2).accessibilityHidden(true)
                TextField("记一条", text: $text, palette: palette).textFieldStyle(.plain).font(Typography.body)
                    .focused($adding)
                    .onSubmit(add)
                    .accessibilityLabel("记一条")
            }
            .padding(.horizontal, Metrics.inset).frame(minHeight: ControlMetrics.height)
            .paper(radius: Metrics.radius)
            if tooLong {
                Text("一条最多 \(CueMemoryLine.maxBytes) 字节，拆成几条记").font(Typography.meta).foregroundStyle(palette.failure)
                    .padding(.leading, 4)
            }
        }
    }

    private func group(_ name: String?, _ lines: [CueMemoryLine]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name { SectionHeader(title: name, count: lines.count) }
            LazyVStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    // 分隔线叠在行上沿、不占一格：行与行的底色才接得上，轻扫时它也不跟着行走
                    row(line)
                        .overlay(alignment: .top) { if index > 0 { Divider().padding(.leading, Metrics.inset) } }
                        .transition(Motion.item)
                }
            }
            .rowPaper(radius: Metrics.radius)
        }
    }

    private func row(_ line: CueMemoryLine) -> MemoryRow {
        let id = line.id, pinned = line.pinned, text = line.text
        return MemoryRow(
            line: line,
            copy: RowAction(MessageMenu.Item.copy.title, icon: MessageMenu.Item.copy.icon) { workspace.copy(text) },
            pin: RowAction(pinned ? "不再一直记着" : "一直记着", icon: pinned ? .unpin : .pin) { workspace.pinCueLine(id, !pinned) },
            forget: RowAction("忘掉", icon: .remove, tone: .destructive) { forgetting = line })
    }

    private func add() {
        guard CueMemoryLine.fits(text) else { return }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.attempt {
            try await workspace.noteCueLine(line)
            text = ""
            adding = true
        }
    }

    #if os(macOS)
    private var content: some View {
        VStack(spacing: 10) {
            PanelHeader(title)
            list
        }
        .padding(.top, 18)
        .frame(width: 480).frame(maxHeight: 600)
        .background(palette.desk)
    }
    #else
    private var content: some View {
        NavigationStack {
            list
                .background(palette.desk)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", icon: .close, role: .cancel) { close() } }
                }
        }
        .presentationDetents([.large])
    }
    #endif
}

/// 记忆的一行：正文占满宽度，后面跟一截淡字（什么时候、你记的）。手机上钉住在右滑、忘掉在左滑；菜单与读屏是全部三项。
private struct MemoryRow: View {
    let line: CueMemoryLine
    let copy: RowAction
    let pin: RowAction
    let forget: RowAction
    @Environment(\.palette) private var palette

    private var meta: Dotted { Dotted(DateLabel.short(line.createdAt), line.source == .known(.you) ? "你记的" : nil) }
    /// 淡字整截不断开（"10/8 · 你记的"断成两行像两件事）：字间垫不换行的连接符，放不下就整截挪到下一行。
    private var unbroken: String {
        meta.visible.replacingOccurrences(of: " ", with: "\u{00A0}").map(String.init).joined(separator: "\u{2060}")
    }

    /// 淡字接在正文末尾一起换行：单独一行每条多占一行高，放右边一列又要从正文里扣出宽度。
    private var label: Text {
        let text = Text(line.text).foregroundStyle(palette.ink)
        let meta = Text(verbatim: unbroken).font(Typography.caption).foregroundStyle(palette.ink3)
        return Text("\(text)\u{2002}\(meta)")
    }

    var body: some View {
        label
            .font(Typography.body)
            #if os(macOS)
            .lineSpacing(Typography.lineSpacing)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.inset)
            .padding(.vertical, Metrics.vertical)
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(line.text)
            .accessibilityValue(meta.spoken)
            #if os(iOS)
            // 长按抬起的预览是这一行的快照：没有底色时抬起来是透明的一条。形状要写明：不写时 iOS 26 按所在容器取同心圆角，行与行之间露出缺口
            .background(palette.paper, in: .rect)
            // 抬起的预览与纸卡同一圆角、同宽（行本来就与纸卡同宽）
            .contentShape(.contextMenuPreview, .rect(cornerRadius: Metrics.radius, style: .continuous))
            .contextMenu { RowActionButtons(actions: [copy, pin, forget]) }
            .rowSwipes(RowSwipes(leading: [pin], trailing: [forget]))
            #else
            .overlay(alignment: .bottomTrailing) { MemoryHoverActions(actions: [pin, forget]) }
            .row(hovers: true)
            .environment(\.rowHoverPreset, DebugHooks.hovers(line.text))
            .contextMenu { RowActionButtons(actions: [copy, pin, forget]) }
            .accessibilityActions { RowActionButtons(actions: [copy, pin, forget]) }
            #endif
    }
}

#if os(macOS)
/// 指针停在行上时（`rowHovered`）右下角的钉住与忘掉：叠在行上、不挤正文，垫一块纸色免得压着最后一行的字。
private struct MemoryHoverActions: View {
    let actions: [RowAction]
    @Environment(\.rowHovered) private var hovered
    @Environment(\.palette) private var palette

    var body: some View {
        if hovered {
            HStack(spacing: 2) {
                ForEach(actions.keyed, id: \.key) { item in
                    Button(item.action.title, icon: item.action.icon, action: item.action.run)
                        .labelStyle(.iconOnly)
                        .font(Typography.meta.weight(.medium))
                        .foregroundStyle(item.action.tone == .destructive ? palette.failure : palette.ink2)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                        .buttonStyle(PressStyle(.button))
                        .help(item.action.title)
                }
            }
            .padding(.horizontal, 4)
            .background(palette.paper, in: .capsule)
            .padding(.trailing, 8).padding(.bottom, 4)
            .transition(.opacity)
        }
    }
}
#endif

/// 页边距、纸与行的内边距、圆角、分组间距：Mac 是 480 宽的浮层，手机是整屏 sheet。
private enum Metrics {
    #if os(macOS)
    static let margin: CGFloat = 20
    static let inset: CGFloat = 14
    static let vertical: CGFloat = 9
    static let radius: CGFloat = 12
    static let groupGap: CGFloat = 20
    #else
    static let margin: CGFloat = 16
    static let inset: CGFloat = 16
    static let vertical: CGFloat = 11
    static let radius: CGFloat = 16
    static let groupGap: CGFloat = 24
    #endif
}
