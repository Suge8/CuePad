#if os(iOS)
import SwiftUI

/// Cue 页页顶那一排中间的名牌（手机、iPad 与 iPad 右侧的 Cue 面板同一个，`floatingHeader` 摆它）：一块实底玻璃，铺满两侧页边之间、定宽——
/// 头像、名字与下面那一行（Cue 此刻：珠子接一句，`CueStatusLine`），右端展开的箭头。Cue 页这一排只有它：这一页的焦点就是 Cue，不放搜索钮；
/// 不随字长短变宽：那一行几秒换一句，跟着变宽整颗名牌就一直在动。
/// 点它从顶部长出面板（`GrowPanel`，同一块玻璃长高）：手机上 Cue 的总面板（`CueNowPanel`：大脑、上下文、等你、在做、
/// 全部会话、记忆、设置），手机上 Cue 的这些只有这一个入口（额度在进展页顶栏的额度环里）。
/// 与 Mac 侧栏的 Cue 名片、菜单栏面板是同一套件、同一份数据（`CueWatch`、`Workspace.liveWork`）。
/// 点名牌、点面板外、在名牌上往上划都收起；点面板里的一项先收起再去那里。开合的动效在 `GrowPanel`，箭头跟着转半圈。
/// 名牌浮在对话上，展开不改对话的布局，长大的只有这一块；展开与否只在这里（不进 `CueWatch`：侧栏也读它）。
/// 打开时只读大脑那一行（设置与那台 Mac 的 Agent，`CueConfigControls.read`，当场读）；其余都是已经在订阅的。
struct CueHeader: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = DebugHooks.preset.cuePanelOpen

    /// 面板里行与行之间的空（会话一列的行距），行的底上下各伸进一半。
    static let rowGap: CGFloat = 12
    private static let height = FloatingHeaderLayout.height

    var body: some View {
        GrowPanel(open: $expanded, radius: Self.height / 2, rowGap: Self.rowGap) {
            // 往上划收起只认名牌那一条：面板里放不下时要往上划着滚
            Button(action: toggle) { plate }
                .buttonStyle(.plain)
                .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { drag in
                    if expanded, drag.translation.height < -24 { toggle() }
                })
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(expanded ? "收起" : "换模型，看上下文、在做的会话、等你的事、记忆与设置")
        } panel: {
            CueNowPanel(close: toggle)
        }
        .debugExposesCuePanel(toggle)
    }

    private var plate: some View {
        let cue = workspace.cue
        return HStack(spacing: 8) {
            CueAvatar(mood: cue.mood(composing: !cue.draft.isEmpty(accepting: .images)), presence: cue.presence, size: .row)
                .relaySpot(cue: .header)
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.name).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                CueStatusLine(tally: true, font: .caption).lineLimit(1).truncationMode(.tail)
            }
            // 名牌是定高的一条：字号跟着动态字体放大到这一档为止，再大第二行就被裁掉
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            Spacer(minLength: 8)
            Image(.expand).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        // 头像与名牌的左端同心
        .padding(.leading, (Self.height - CueAvatar.Size.row.box) / 2)
        .padding(.trailing, 16)
        .frame(height: Self.height)
        .contentShape(.rect)
        .animation(HandOff.quick, value: cue.presence)
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: cue.now)
        .accessibilityElement(children: .combine)
    }

    private func toggle() { $expanded.grow(reduceMotion: reduceMotion) }
}

/// 页头展开后的面板，手机上 Cue 的总面板（Mac 上这些分在 Cue 页输入框、"运行情况"、侧栏与设置里）：
/// 第一行左边是它的大脑（Agent、模型与思考强度，`CueConfigControls`；还没选在哪台运行时没有），右边是它在哪台运行与齿轮，点它推入设置
/// （`CueSettingsScreen`：在哪台 Mac 上运行、不用先问的事、工具步骤与名字；放在第一行是因为下面的会话一多，面板就要滚，末尾的入口看不见）；
/// 启用了接着是上下文用量（`CueContextCard`，与 Mac 同一个），然后是等你（卡片就在页面下方，点它收起面板）、在做（前几个，
/// 同 Mac 菜单栏面板；区头写一共几个会话、几个子代理在跑，多出的在列末就地展开）、全部会话（换到进展页的会话段）与记忆。区头随面板一起滚，不钉住：钉住就要让滚过的行在它下面淡去，那是一层遮罩。
/// 放不下时面板里面滚。
private struct CueNowPanel: View {
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    /// 面板只是一瞥：在做的会话最多列这么多，全部在 进展页的会话段里。
    private static let limit = 5
    /// 换一块新的滚动区（`body` 里的注释）。
    @State private var scroll = 0

    var body: some View {
        HugHeight {
            ScrollView { content }.scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(DebugHooks.preset.cuePanelEnd ? .bottom : nil)
                .id(scroll)
                // 这块滚动区不设内容边距，左、上有边距就是对话那块的：SwiftUI 在同一次更新里给对话的滚动区上内容边距时，
                // 会把同一份写到这块的 UIScrollView 上（实测四边各 16，自己写的 `contentMargins` 也被盖掉），整块内容右下移 16、右边被裁，
                // 之后不再改回。换一块新的，它按自己的环境排。底边不看：键盘盖住的那截是系统给的安全区。
                .onScrollGeometryChange(for: Bool.self) { $0.contentInsets.leading != 0 || $0.contentInsets.top != 0 } action: { _, foreign in
                    if foreign { scroll += 1 }
                }
        }
    }

    private var content: some View {
        let cue = workspace.cue
        return VStack(alignment: .leading, spacing: 16) {
            // 胶囊先排（Agent、模型、强度不被挤成省略号；窄处思考强度只写档名），右端拿剩下的宽：放得下写在哪台运行，放不下只留齿轮
            HStack(spacing: 8) {
                if cue.hostID != nil { CueConfigControls(fail: workspace.fail).layoutPriority(1) }
                settings(cue).frame(maxWidth: .infinity, alignment: .trailing)
            }
            if cue.canHear { CueContextCard(context: cue.context) }
            if cue.waiting > 0 { waiting(cue.waiting) }
            sessions
            link("记忆", icon: .memory) {
                close()
                cue.showsMemory = true
            }
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
    }

    /// 大脑那一行的右端：它在哪台运行与齿轮，窄屏放不下名字时只留齿轮（名字在设置页的顶栏里看得到），点它推入设置。
    private func settings(_ cue: CueWatch) -> some View {
        let home = cue.home
        return Button {
            close()
            workspace.push(.cueSettings)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    if let home { Text(home).lineLimit(1) }
                    Image(.settings)
                }
                Image(.settings)
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(palette.ink2)
            // 贴右对齐：与下面各行右端的字落在同一条竖线上
            .frame(minWidth: 44, minHeight: 44, alignment: .trailing).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel("\(cue.name) 的设置")
        .accessibilityValue(home ?? "")
    }

    private func waiting(_ count: Int) -> some View {
        Button(action: close) {
            HStack(spacing: 8) {
                Image(.waiting).foregroundStyle(palette.waiting).accessibilityHidden(true)
                WaitingCount(count: count)
                Spacer(minLength: 8)
                Image(.expand).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .font(.subheadline)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .accessibilityHint("收起面板，看下面等你的事")
    }

    private var sessions: some View {
        let live = services.liveSessions, work = workspace.liveWork
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("在做").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if !work.rows.isEmpty { LiveWorkCount(work: work, font: .footnote) }
            }
            .accessibilityElement(children: .combine)
            sessionRows(work, live: live)
        }
    }

    @ViewBuilder private func sessionRows(_ work: LiveWork, live: LiveSessions) -> some View {
        if work.rows.isEmpty {
            Text("没有在跑的会话").font(.subheadline).foregroundStyle(palette.ink3)
        } else {
            LiveSessionList(sessions: work.rows, limit: Self.limit, spacing: CueHeader.rowGap) { session in
                Button {
                    close()
                    workspace.openSession(session.id, sessionID: session.sessionID)
                } label: {
                    PiSessionRow(
                        session: session, project: workspace.catalog?.project(session.projectID), delivery: live.deliveries[session.sessionID],
                        rename: live.renames[session.sessionID], undelivered: live.undelivered[session.sessionID] ?? 0
                    ).equatable()
                        .contentShape(.rect)
                }
                .buttonStyle(.row)
            }
        }
        link("全部会话", count: live.total) {
            close()
            workspace.showSessions()
        }
    }

    private func link(_ title: String, icon: Icon? = nil, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(icon).foregroundStyle(palette.ink2).frame(width: 20).accessibilityHidden(true) }
                Text(title).foregroundStyle(palette.ink)
                if let count, count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(palette.ink3) }
                Spacer(minLength: 8)
                Image(.forward).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
    }
}

#endif
