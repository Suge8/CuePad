#if os(iOS)
import CueStore
import SwiftUI

/// 手机与 iPad 的 Cue 页头：一块实底玻璃，平时是左右各离屏边 21 点、56 点高的一条——头像、名字、"在管 N · 等你 M"（`CueStatusLine` 的 tally）、展开的箭头；
/// 点它从顶部长出面板（同一块玻璃长高）：手机上 Cue 的总面板（`CueNowPanel`：大脑、上下文、等你、在做、
/// 全部会话、额度、记忆、设置），手机上 Cue 的这些只有这一个入口。
/// 与 Mac 侧栏的 Cue 名片、菜单栏面板是同一套件、同一份数据（`CueWatch`、`Workspace.liveWork`）。
/// 点页头、点面板外、在页头上往上划都收起；点面板里的一项先收起再去那里。
/// 动效：玻璃随无回弹弹簧（`Motion.panel`，0.25 秒）长大，面板的几行只淡入、下移 6 点，箭头转半圈；减弱动态效果时直接到终态。
/// 页头浮在对话上（对话让出固定的 `reserve`），展开不改对话的布局，长大的只有这一小块；展开与否只在这里（不进 `CueWatch`：侧栏也读它）。
/// 打开时只读大脑那一行（设置与那台 Mac 的 Agent，`CueConfigControls.read`，当场读）；其余都是已经在订阅的。
struct CueHeader: View {
    /// 窄屏：提示横幅盖在页头这一排上（`NoticeBanner`），页头让开。
    let underBanner: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = DebugHooks.preset.cuePanelOpen

    static let height: CGFloat = 56
    private static let radius: CGFloat = height / 2
    /// 面板里行与行之间的空（会话一列的行距），行的底上下各伸进一半。
    static let rowGap: CGFloat = 12
    /// 离页面两侧（同底部那一排，`Dock.margin`）与上安全区的距离。
    private static let edge = Dock.margin
    private static let top: CGFloat = 4
    /// 对话在顶上让出的高度：页头一条加上下的空。
    static let reserve = top + height + 10

    var body: some View {
        ZStack(alignment: .top) {
            if expanded {
                // 面板外点一下收起；背后的页面不压色（同浮起的输入框）
                Color.clear.contentShape(.rect).ignoresSafeArea()
                    .onTapGesture(perform: toggle)
                    .accessibilityHidden(true)
            }
            glass
                // 提示横幅暂时盖住这一排：页头让开，不与横幅叠成两层玻璃、露出半个头像
                .opacity(underBanner && workspace.notice != nil && !expanded ? 0 : 1)
                .animation(NoticeBanner.giveWay(workspace.notice), value: workspace.notice != nil)
                .padding(.horizontal, Self.edge).padding(.top, Self.top)
        }
        .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil, alignment: .top)
        .sensoryFeedback(.impact(weight: .light), trigger: expanded)
        .onDisappear { expanded = false }
        .debugExposesCuePanel(toggle)
    }

    private var glass: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 往上划收起只认页头那一条：面板里放不下时要往上划着滚
            Button(action: toggle) {
                // 面板开着时横幅只盖住头那一排：这一排让开，面板照常
                head.opacity(underBanner && workspace.notice != nil ? 0 : 1).animation(NoticeBanner.giveWay(workspace.notice), value: workspace.notice != nil)
            }
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
        .rowContainer(.rect(cornerRadius: Self.radius, style: .continuous), gap: Self.rowGap)
        .glass(in: .rect(cornerRadius: Self.radius, style: .continuous))
    }

    private var head: some View {
        let cue = workspace.cue
        return HStack(spacing: 10) {
            CueAvatar(mood: cue.mood(composing: !cue.draft.isEmpty(accepting: .images)), presence: cue.presence, size: .header)
                .relaySpot(cue: .header)
                // 头像与胶囊的左端同心
                .padding(.leading, (Self.height - CueAvatar.Size.header.box) / 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.name).font(.title3.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                CueStatusLine(tally: true, font: .subheadline).lineLimit(1)
            }
            // 页头是定高的一条：字号跟着动态字体放大到这一档为止，再大第二行就被裁掉
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            Spacer(minLength: 6)
            Image(.expand).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .padding(.trailing, 18)
                .accessibilityHidden(true)
        }
        .frame(height: Self.height)
        .contentShape(.rect)
        .animation(Motion.quick, value: cue.presence)
        .accessibilityElement(children: .combine)
    }


    private func toggle() {
        withAnimation(Motion.spatial(Motion.panel, reduceMotion: reduceMotion)) { expanded.toggle() }
    }
}

/// 页头展开后的面板，手机上 Cue 的总面板（Mac 上这些分在 Cue 页输入框、"运行情况"、侧栏与设置里）：
/// 第一行左边是它的大脑（Agent、模型与思考强度，`CueConfigControls`；还没选在哪台运行时没有），右边是它在哪台运行与齿轮，点它推入设置
/// （`CueSettingsScreen`：在哪台 Mac 上运行、不用先问的事、工具步骤与名字；放在第一行是因为下面的会话一多，面板就要滚，末尾的入口看不见）；
/// 启用了接着是上下文用量（`CueContextCard`，与 Mac 同一个），然后是等你（卡片就在页面下方，点它收起面板）、在做（前几个，
/// 同 Mac 菜单栏面板；区头写一共几个会话、几个子代理在跑，多出的在列末就地展开）、全部会话（推入 Agent 整页）、额度与记忆。
/// 放不下时面板里面滚。
private struct CueNowPanel: View {
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    /// 面板只是一瞥：在做的会话最多列这么多，全部在 Agent 整页里。
    private static let limit = 5
    /// "在做"区头的高度（钉住时滚过的行在它下沿淡去，`FadesUnderHeader`）。
    @ScaledMetric(relativeTo: .footnote) private var headerHeight: CGFloat = 30

    var body: some View {
        HugHeight {
            ScrollView { content }.scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(DebugHooks.preset.cuePanelEnd ? .bottom : nil)
        }
        .refreshesQuota()
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
            QuotaStrip()
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
            navigation.push(.cueSettings)
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
                .frame(height: headerHeight)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func sessionRows(_ work: LiveWork, live: LiveSessions) -> some View {
        if work.rows.isEmpty {
            Text("没有在跑的会话").font(.subheadline).foregroundStyle(palette.ink3)
        } else {
            LiveSessionList(sessions: work.rows, limit: Self.limit, spacing: CueHeader.rowGap) { session in
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
                .buttonStyle(.row)
                .modifier(FadesUnderHeader(header: headerHeight))
            } fold: { count, expanded in
                PiReloadFold(count: count, expanded: expanded).modifier(FadesUnderHeader(header: headerHeight))
            }
        }
        link("全部会话", count: live.total) {
            close()
            navigation.push(.agent)
        }
        .modifier(FadesUnderHeader(header: headerHeight))
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

/// 钉住的"在做"区头不铺底，滚到它下面的行就地淡去：铺什么颜色都与面板的玻璃对不上（玻璃的光随背后变，深色下曾是一条直角色带），
/// 不铺底它就是玻璃本身。行顶离区头下沿还有 `fade` 的一半时开始淡，碰到区头的字之前淡完，字不会叠在一起。
/// 读的是渲染时的几何（`visualEffect`），不进状态、不挂几何回调：滚动时每帧只改透明度。
private struct FadesUnderHeader: ViewModifier {
    let header: CGFloat
    private static let fade: CGFloat = 12

    func body(content: Content) -> some View {
        content.visualEffect { [header] content, proxy in
            let top = proxy.frame(in: .scrollView).minY - (header - Self.fade / 2)
            return content.opacity(min(max(top / Self.fade, 0), 1))
        }
    }
}
#endif
