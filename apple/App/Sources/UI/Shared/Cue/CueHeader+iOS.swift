#if os(iOS)
import CueStore
import SwiftUI

/// 手机与 iPad 的 Cue 页头：一块玻璃，平时是 56 点高的一条——头像、名字、此刻在做什么、"等你 N"、展开的箭头；
/// 点它从顶部长出面板（同一块玻璃长高、变宽；iPhone 上页头在导航栏那一排里，左边让着系统的返回）：手机上 Cue 的总面板（`CueNowPanel`：大脑、上下文、等你、在做、
/// 全部会话、额度、记忆、设置），手机上 Cue 的这些只有这一个入口。
/// 与 Mac 侧栏的 Cue 行与 Agent 区、菜单栏面板是同一套件、同一份数据（`CueWatch`、`Workspace.liveWork`）。
/// 点页头、点面板外、在页头上往上划都收起；点面板里的一项先收起再去那里。
/// 动效：玻璃随无回弹弹簧（`Motion.panel`，0.25 秒）长大，面板的几行只淡入、下移 6 点，箭头转半圈；减弱动态效果时直接到终态。
/// 页头浮在对话上（对话让出固定的 `reserve`），展开不改对话的布局，长大的只有这一小块；展开与否只在这里（不进 `CueWatch`：侧栏也读它）。
/// 打开时只读大脑那一行（设置与那台 Mac 的 Agent，`CueBrainMenu`，当场读）；其余都是已经在订阅的。
struct CueHeader: View {
    /// 页头在导航栏那一排里、左边让着系统的返回（iPhone，`inNavigationBarRow`）。
    let inBar: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = DebugHooks.preset.cuePanelOpen

    static let height: CGFloat = 56
    private static let radius: CGFloat = 28
    /// 离页面两侧与上安全区的距离（同 `RootBar`）。
    private static let edge: CGFloat = 16
    private static let top: CGFloat = 4
    /// 对话在顶上让出的高度：页头一条加上下的空。页头在导航栏那一排里时只让出它比导航栏多出的那一点与下面的空。
    static func reserve(inBar: Bool) -> CGFloat { inBar ? 12 : top + height + 8 }

    var body: some View {
        ZStack(alignment: .top) {
            if expanded {
                // 面板外点一下收起；背后的页面不压色（同浮起的输入框）
                Color.clear.contentShape(.rect).ignoresSafeArea()
                    .onTapGesture(perform: toggle)
                    .accessibilityHidden(true)
            }
            glass
                .inNavigationBarRow(inBar, height: Self.height, tap: toggle)
                .padding(.horizontal, Self.edge).padding(.top, inBar ? 0 : Self.top)
        }
        .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil, alignment: .top)
        .sensoryFeedback(.impact(weight: .light), trigger: expanded)
        .onDisappear { expanded = false }
        .debugExposesCuePanel(toggle)
    }

    private var glass: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 往上划收起只认页头那一条：面板里放不下时要往上划着滚
            Button(action: toggle) { head }
                .buttonStyle(.plain)
                .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { drag in
                    if expanded, drag.translation.height < -24 { toggle() }
                })
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(expanded ? "收起" : "换模型，看上下文、在做的会话、等你的事、记忆与设置")
            if expanded {
                CueNowPanel(close: toggle)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 面板的几行按长大后的位置排好、淡入：玻璃还在长的那几帧里不画到玻璃外面
        .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
        .glass(in: .rect(cornerRadius: Self.radius, style: .continuous), ink: .solid)
    }

    private var head: some View {
        let cue = workspace.cue
        return HStack(spacing: 10) {
            CueAvatar(mood: cue.mood(composing: !cue.draft.isEmpty(accepting: .images)), presence: cue.presence, size: .header)
                .relaySpot(cue: .header)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.name).font(.headline).foregroundStyle(palette.ink).lineLimit(1)
                CueStatusLine(fallback: cue.lastSaid, font: .footnote).lineLimit(1)
            }
            Spacer(minLength: 6)
            // 展开时等你那一行在面板里，页头不再重复
            WaitingCount(count: expanded ? 0 : cue.waiting).font(.subheadline)
            Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .padding(.trailing, 18)
                .accessibilityHidden(true)
        }
        .frame(height: Self.height)
        .contentShape(.rect)
        .animation(Motion.quick, value: cue.waiting)
        .animation(Motion.quick, value: cue.lastSaid)
        .animation(Motion.quick, value: cue.presence)
        .accessibilityElement(children: .combine)
    }

    private func toggle() {
        withAnimation(Motion.spatial(Motion.panel, reduceMotion: reduceMotion)) { expanded.toggle() }
    }
}

/// 页头展开后的面板，手机上 Cue 的总面板（Mac 上这些分在 Cue 页输入框、"运行情况"、侧栏与设置里）：
/// 第一行左边是它的大脑（Agent、模型与思考强度，`CueConfigControls`；还没选住哪台时没有），右边是它住在哪与齿轮，点它推入设置
/// （`CueSettingsScreen`：名字、住在哪台 Mac、允许清单；放在第一行是因为下面的会话一多，面板就要滚，末尾的入口看不见）；
/// 启用了接着是上下文用量（`CueContextCard`，与 Mac 同一个），然后是等你（卡片就在页面下方，点它收起面板）、在做（前几个，
/// 同 Mac 侧栏的 Agent 区；区头写一共几个会话、几个子代理在跑，多出的在列末就地展开）、全部会话（推入 Agent 整页）、额度与记忆。
/// 放不下时面板里面滚。
private struct CueNowPanel: View {
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    /// 面板只是一瞥：在做的会话最多列这么多，全部在 Agent 整页里。
    private static let limit = 5

    var body: some View {
        HugHeight {
            ScrollView { content }.scrollBounceBehavior(.basedOnSize)
        }
        .refreshesQuota()
    }

    private var content: some View {
        let cue = workspace.cue
        return VStack(alignment: .leading, spacing: 16) {
            // 胶囊先排（模型、强度不被挤成省略号），右端拿剩下的宽：放得下写住在哪，放不下只留齿轮
            HStack(spacing: 8) {
                if cue.hostID != nil { CueConfigControls().fixedSize(horizontal: true, vertical: false) }
                settings(cue).frame(maxWidth: .infinity, alignment: .trailing)
            }
            if cue.canHear { CueContextCard(context: cue.context) }
            if cue.waiting > 0 { waiting(cue.waiting) }
            sessions
            QuotaStrip()
            link("记忆", symbol: "brain") {
                close()
                cue.showsMemory = true
            }
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
    }

    /// 大脑那一行的右端：它住在哪与齿轮，窄屏放不下名字时只留齿轮（名字在设置页的顶栏里看得到），点它推入设置。
    private func settings(_ cue: CueWatch) -> some View {
        let home = cue.canHear ? cue.hostName : "没启用"
        return Button {
            close()
            navigation.push(.cueSettings)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    if let home { Text(home).lineLimit(1) }
                    Image(systemName: "gearshape")
                }
                Image(systemName: "gearshape")
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
                Image(systemName: Waiting.symbol).foregroundStyle(palette.waiting).accessibilityHidden(true)
                WaitingCount(count: count)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .font(.subheadline)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .accessibilityHint("收起面板，看下面等你的事")
    }

    private var sessions: some View {
        let live = services.liveSessions, work = workspace.liveWork
        // 区头钉在面板顶上：展开后一屏放不下，往下翻会话时还看得到有几个在跑
        return LazyVStack(alignment: .leading, spacing: 10, pinnedViews: .sectionHeaders) {
            Section {
                sessionRows(work, live: live)
            } header: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("在做").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if !work.rows.isEmpty { LiveWorkCount(work: work, font: .footnote) }
                }
                .padding(.vertical, 6)
                // 面板的底色（`GlassInk.solid` 垫的页面底色），实的：钉住时下面滚过的行不透上来
                .background(palette.desk)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func sessionRows(_ work: LiveWork, live: LiveSessions) -> some View {
        if work.rows.isEmpty {
            Text("没有在跑的会话").font(.subheadline).foregroundStyle(palette.ink3)
        } else {
            LiveSessionList(sessions: work.rows, limit: Self.limit, spacing: 12) { session in
                Button {
                    close()
                    navigation.openSession(session.id, sessionID: session.sessionID, store: services.store)
                } label: {
                    PiSessionRow(
                        session: session, project: workspace.catalog?.project(session.projectID), delivery: live.deliveries[session.sessionID],
                        rename: live.renames[session.sessionID], undelivered: live.undelivered[session.sessionID] ?? 0
                    ).equatable()
                        .contentShape(.rect)
                }
                .buttonStyle(RowPressStyle())
            } fold: { count, expanded in
                PiReloadFold(count: count, expanded: expanded)
            }
        }
        link("全部会话", count: live.total) {
            close()
            navigation.push(.agent)
        }
    }

    private func link(_ title: String, symbol: String? = nil, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).foregroundStyle(palette.ink2).frame(width: 20).accessibilityHidden(true) }
                Text(title).foregroundStyle(palette.ink)
                if let count, count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(palette.ink3) }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
    }
}
#endif
