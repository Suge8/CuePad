#if os(iOS)
import CueStore
import SwiftUI

/// 手机与 iPad 的 Cue 页头：一块玻璃，平时是 56 点高的一条——头像、名字、此刻在做什么、"等你 N"、展开的箭头；
/// 点它从顶部长出面板（同一块玻璃长高、变宽，盖住左边的设置钮）：等你、在做（`LiveSessionList`）、全部会话、额度（`QuotaStrip`）、记忆。
/// 与 Mac 侧栏的 Cue 行与 Agent 区、菜单栏面板是同一套件、同一份数据（`CueWatch`、`Workspace.liveSessionRows`）。
/// 点页头、点面板外、往上划都收起；点面板里的一项先收起再去那里。
/// 动效：玻璃随无回弹弹簧（`Motion.panel`，0.25 秒）长大，面板的几行只淡入、下移 6 点，箭头转半圈；减弱动态效果时收起与展开的两块玻璃整块交叉淡入淡出（换身份，同底部栏的选中滴），尺寸、位置与箭头都不插值。
/// 页头浮在对话上（对话让出固定的 `reserve`），展开不改对话的布局，长大的只有这一小块；展开与否只在这里（不进 `CueWatch`：底栏、侧栏都读它）。
/// 打开时不读库：面板里的数据都是已经在订阅的。
struct CueHeader: View {
    /// 左边留着设置钮（iPhone 标签栏布局；iPad 的设置在侧栏）。
    let showsSettings: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = DebugHooks.preset.cuePanelOpen

    static let height: CGFloat = 56
    private static let radius: CGFloat = 28
    /// 离页面两侧与上安全区的距离（同 `RootBar`）。
    private static let edge: CGFloat = 16
    private static let top: CGFloat = 4
    /// 对话在顶上让出的高度：页头一条加上下的空。
    static let reserve: CGFloat = top + height + 8

    var body: some View {
        ZStack(alignment: .top) {
            if expanded {
                // 面板外点一下收起；背后的页面不压色（同浮起的输入框）
                Color.clear.contentShape(.rect).ignoresSafeArea()
                    .onTapGesture(perform: toggle)
                    .accessibilityHidden(true)
            }
            if showsSettings {
                SettingsButton()
                    .buttonStyle(ControlButtonStyle(kind: .circular)).labelStyle(.iconOnly)
                    .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
                    .padding(.horizontal, Self.edge).padding(.top, Self.top)
            }
            glass
                .padding(.leading, expanded || !showsSettings ? 0 : ControlMetrics.height + 8)
                .padding(.horizontal, Self.edge).padding(.top, Self.top)
                .id(reduceMotion ? expanded : nil)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil, alignment: .top)
        .sensoryFeedback(.impact(weight: .light), trigger: expanded)
        .onDisappear { expanded = false }
        .debugExposesCuePanel(toggle)
    }

    private var glass: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { head }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(expanded ? "收起" : "看在做的会话、等你的事与记忆")
            if expanded {
                CueNowPanel(close: toggle)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 面板的几行按长大后的位置排好、淡入：玻璃还在长的那几帧里不画到玻璃外面
        .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
        .glass(in: .rect(cornerRadius: Self.radius, style: .continuous), ink: .solid)
        .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { drag in
            if expanded, drag.translation.height < -24 { toggle() }
        })
    }

    private var head: some View {
        let cue = workspace.cue
        return HStack(spacing: 10) {
            CueAvatar(mood: cue.mood(composing: !cue.draft.isEmpty(accepting: .images)), presence: cue.presence, size: .header)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.name).font(.headline).foregroundStyle(palette.ink).lineLimit(1)
                CueStatusLine(fallback: cue.digest.lastSaid, font: .footnote).lineLimit(1)
            }
            Spacer(minLength: 6)
            // 展开时等你那一行在面板里，页头不再重复
            WaitingCount(count: expanded ? 0 : cue.digest.waiting).font(.subheadline)
            Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .padding(.trailing, 18)
                .accessibilityHidden(true)
        }
        .frame(height: Self.height)
        .contentShape(.rect)
        .animation(Motion.quick, value: cue.digest)
        .animation(Motion.quick, value: cue.presence)
        .accessibilityElement(children: .combine)
    }

    private func toggle() {
        withAnimation(Motion.spatial(Motion.panel, reduceMotion: reduceMotion)) { expanded.toggle() }
    }
}

/// 页头展开后的面板：等你（卡片就在页面下方，点它收起面板）、在做（前几个，同 Mac 侧栏的 Agent 区）、全部会话（推入 Agent 整页）、额度、记忆。
private struct CueNowPanel: View {
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    /// 面板只是一瞥：在做的会话最多列这么多，全部在 Agent 整页里。
    private static let limit = 5

    var body: some View {
        let cue = workspace.cue, sessions = services.liveSessions
        let rows = workspace.liveSessionRows
        VStack(alignment: .leading, spacing: 16) {
            if cue.digest.waiting > 0 {
                Button(action: close) {
                    HStack(spacing: 8) {
                        Image(systemName: Waiting.symbol).foregroundStyle(Waiting.tint(dark: palette.dark)).accessibilityHidden(true)
                        WaitingCount(count: cue.digest.waiting)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .contentShape(.rect)
                }
                .buttonStyle(RowPressStyle())
                .accessibilityHint("收起面板，看下面等你的事")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("在做").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                if rows.isEmpty {
                    Text("没有在跑的会话").font(.subheadline).foregroundStyle(palette.ink3)
                } else {
                    LiveSessionList(sessions: rows, limit: Self.limit, spacing: 12) { session in
                        Button {
                            close()
                            navigation.openSession(session.id, sessionID: session.sessionID, store: services.store)
                        } label: {
                            PiSessionRow(
                                session: session, project: workspace.catalog?.project(session.projectID), delivery: sessions.deliveries[session.sessionID],
                                rename: sessions.renames[session.sessionID], undelivered: sessions.undelivered[session.sessionID] ?? 0
                            ).equatable()
                                .contentShape(.rect)
                        }
                        .buttonStyle(RowPressStyle())
                    } fold: { count, expanded in
                        PiReloadFold(count: count, expanded: expanded)
                    }
                }
                link("全部会话", count: sessions.total) {
                    close()
                    navigation.push(.agent)
                }
            }
            QuotaStrip()
            link("记忆", symbol: "brain") {
                close()
                cue.showsMemory = true
            }
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
        .refreshesQuota()
    }

    private func link(_ title: String, symbol: String? = nil, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).foregroundStyle(palette.ink2).accessibilityHidden(true) }
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
