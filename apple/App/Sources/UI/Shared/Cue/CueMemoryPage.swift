import CueStore
import SwiftUI

/// "Cue 记得什么"（Cue 页上打开的弹层，入口见 `CuePage`；手机与 Mac 同一张列表）：没忘掉的记忆，"一直记着"（钉住的）一组在前，其余按记下的时间分段
/// （今天、昨天、本周、本月、更早，同会话历史 `TimeSection`），组内从新到旧。顶上不写标题，一条只剩正文：时间在组头，
/// 来源（"你记的"）与确切日期只在长按（右键）菜单的抬头与读屏里——一屏要看得到十来条。
/// 记一条是浮在底部的玻璃胶囊，列表从它后面透过；记下的算你记的，一条超过 `CueMemoryLine.maxBytes` 字节时在胶囊里说明、不写。
/// 钉住与忘掉（另有复制）按平台惯例收起：手机右滑钉住、左滑忘掉、长按出菜单；Mac 右键出菜单，指针停在一行时铺行的淡底（`RowStyle`）、右下角露出两颗小钮。
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

    private var title: String { String(localized: "\(workspace.cue.name) 记得什么") }
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
            LazyVStack(alignment: .leading, spacing: 0) {
                if !pinned.isEmpty {
                    groupTitle(String(localized: "一直记着"), icon: .pin)
                    ForEach(pinned) { row($0).transition(Motion.item) }
                }
                ForEach(TimeSection.split(others, date: \.createdAt, now: .now), id: \.section) { run in
                    groupTitle(run.section.title)
                    ForEach(run.items) { row($0).transition(Motion.item) }
                }
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.bottom, 12)
        }
        .scrollEdgeEffectHidden()
        .overlay {
            if memory != nil, kept.isEmpty {
                EmptyState(mascot: .empty, title: "还没记住什么", message: "你说过的要紧事，它会自己记下").padding(20)
            }
        }
        // 滚动区止于胶囊半高处，胶囊下半截伸出滚动区：内容只从胶囊背后滚过，不在它下面与圆角外露出被面板下沿切掉的半行
        .safeAreaInset(edge: .bottom, spacing: 0) { field.padding(.bottom, -Metrics.field / 2) }
        .padding(.bottom, Metrics.fieldBottom + Metrics.field / 2)
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: kept)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(.add).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink2).accessibilityHidden(true)
                TextField(String(localized: "记一条"), text: $text, palette: palette).textFieldStyle(.plain).font(Typography.body)
                    .focused($adding)
                    .onSubmit(add)
                    .accessibilityLabel("记一条")
            }
            .frame(minHeight: Metrics.field)
            if tooLong {
                Text("一条最多 \(CueMemoryLine.maxBytes) 字节，拆成几条记").font(Typography.meta).foregroundStyle(palette.failure)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 18)
        .glass(in: .rect(cornerRadius: Metrics.field / 2, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func groupTitle(_ title: String, icon: Icon? = nil) -> some View {
        SectionLabel(text: Dotted(title), icon: icon).padding(.horizontal, Metrics.inset).padding(.top, 20).padding(.bottom, 2)
    }

    private func row(_ line: CueMemoryLine) -> MemoryRow {
        let id = line.id, pinned = line.pinned, text = line.text
        return MemoryRow(
            line: line,
            copy: RowAction(.verbatim(MessageMenu.Item.copy.title), icon: MessageMenu.Item.copy.icon) { workspace.copy(text) },
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
        list
            .safeAreaPadding(.top, 14)
            .contentMargins(.top, -14, for: .scrollIndicators)
            .overlay(alignment: .topTrailing) { PanelCloseButton().padding(12) }
            .frame(width: 480).frame(maxHeight: 600)
            .background(palette.desk)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
    }
    #else
    private var content: some View {
        NavigationStack {
            list
                .background(palette.desk)
                .navigationTitle(title)
                // 标题只给读屏与多任务，顶上不写：移除标题项只去掉小标题，大标题还要靠 inline 才不出现
                .toolbar(removing: .title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", icon: .close, role: .cancel) { close() } }
                }
        }
        .presentationDetents([.large])
    }
    #endif
}

/// 一组记忆的组头：小号、第三档墨，"一直记着"带一枚钉；上面空出一段把组分开。
/// 记忆的一行：只有正文，占满宽度。手机上钉住在右滑、忘掉在左滑；菜单与读屏是全部三项，菜单抬头与读屏另说什么时候、是不是你记的。
private struct MemoryRow: View {
    let line: CueMemoryLine
    let copy: RowAction
    let pin: RowAction
    let forget: RowAction
    @Environment(\.palette) private var palette

    private var meta: Dotted { Dotted(DateLabel.short(line.createdAt), line.source == .known(.you) ? String(localized: "你记的") : nil) }
    private var menu: some View {
        Section(meta.visible) { RowActionButtons(actions: [copy, pin, forget]) }
    }

    var body: some View {
        Text(line.text).foregroundStyle(palette.ink)
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
            // 长按抬起的预览与左右滑时露出的缝是这一行的快照：没有底色时抬起来是透明的一条。形状要写明：不写时 iOS 26 按所在容器取同心圆角
            .background(palette.desk, in: .rect)
            .contentShape(.contextMenuPreview, .rect(cornerRadius: Metrics.radius, style: .continuous))
            .contextMenu { menu }
            .rowSwipes(RowSwipes(leading: [pin], trailing: [forget]))
            #else
            .hoverReveal(.bottomTrailing) { MemoryHoverActions(actions: [pin, forget]) }
            .row()
            .contextMenu { menu }
            .accessibilityActions { RowActionButtons(actions: [copy, pin, forget]) }
            #endif
    }
}

#if os(macOS)
/// 指针停在行上时右下角浮出的钉住与忘掉（`hoverReveal`）。
private struct MemoryHoverActions: View {
    let actions: [RowAction]
    @Environment(\.palette) private var palette

    var body: some View {
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
        .padding(.leading, 4)
    }
}
#endif

/// 页边距（Mac 的行底向两边伸出 `RowMetrics.bleed`，边距要盖住它）、行的内边距、手机长按预览的圆角、记一条的高与离底：Mac 是 480 宽的浮层，手机是整屏 sheet。
private enum Metrics {
    #if os(macOS)
    static let margin: CGFloat = 20
    static let inset: CGFloat = 0
    static let vertical: CGFloat = 7
    static let field: CGFloat = 44
    static let fieldBottom: CGFloat = 16
    #else
    static let margin: CGFloat = 4
    static let inset: CGFloat = 16
    static let vertical: CGFloat = 9
    static let radius: CGFloat = 16
    static let field: CGFloat = 50
    static let fieldBottom: CGFloat = 8
    #endif
}
