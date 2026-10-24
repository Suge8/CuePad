#if os(iOS)
import CueStore
import SwiftUI

/// Cue 名牌长出的面板（`CueHeader`），手机上 Cue 的总面板（Mac 上这些分在 Cue 页输入框、"运行情况"、侧栏与设置里）。名牌长成的名片之下，沿中轴排：
/// 它的大脑（Agent、模型与思考强度，`CueConfigControls`；还没选在哪台运行时没有）与上下文那一行（`CueContextLine`，启用了才有），居中；
/// 在做：区头左"在做"，右边等你（赭黄，点它收起面板，等你的卡就在页面下方）与在跑、子代理的计数（`LiveWorkCount`）；下面固定几格会话（`SessionSlots`）；
/// 底部三个等宽的去处：全部会话（换到进展页的会话段）、记忆、设置（`CueSettingsScreen`：在哪台 Mac 上运行、不用先问的事、工具步骤与名字）。
/// 面板定高、不滚：会话空着、少、满都是同样几格高，多出的在全部会话里；放不下四格时少放几格（按给的高定，与有几个会话无关）。
/// 区头不钉住、面板里没有滚动区：滚动区会读到对话那块的内容边距（SwiftUI 把对话的 `contentMargins` 写到同一棵树里别的 UIScrollView 上），整块右移被裁。
struct CueNowPanel: View {
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    /// 面板的字号上限：再大名片、大脑、一格会话与去处就放不进最矮的 iPhone 了。
    private static let largestType = DynamicTypeSize.accessibility1

    var body: some View {
        let cue = workspace.cue
        VStack(spacing: 16) {
            if cue.hostID != nil || cue.canHear {
                VStack(spacing: 12) {
                    if cue.hostID != nil { CueConfigControls(fail: workspace.fail, alignment: .center) }
                    if cue.canHear { CueContextLine(context: cue.context).frame(maxWidth: 240) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                tally
                SessionSlots(sessions: workspace.liveWork.rows, open: open)
            }
            places
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
        .dynamicTypeSize(...Self.largestType)
    }

    /// 在做的区头：左"在做"，右边等你与在跑的计数；等你只在有的时候写。
    private var tally: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("在做").font(.footnote.weight(.semibold)).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if workspace.cue.waiting > 0 {
                Button(action: close) {
                    WaitingCount(count: workspace.cue.waiting).frame(minHeight: 32).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .accessibilityHint("收起面板，看下面等你的事")
                Dot().foregroundStyle(palette.ink3)
            }
            LiveWorkCount(work: workspace.liveWork, font: .footnote)
        }
        .font(.footnote)
        // 大字号下一行放不下时整行缩一点，不截掉子代理的数
        .minimumScaleFactor(0.8)
    }

    private var places: some View {
        HStack(spacing: 0) {
            place("全部会话", icon: .session, count: services.liveSessions.total) {
                close()
                workspace.showSessions()
            }
            place("记忆", icon: .memory) {
                close()
                workspace.cue.showsMemory = true
            }
            place("设置", icon: .settings) {
                close()
                workspace.push(.cueSettings)
            }
        }
    }

    private func place(_ title: String, icon: Icon, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(icon).font(.title3).foregroundStyle(palette.ink2).accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(title).foregroundStyle(palette.ink)
                    if let count, count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(palette.ink3) }
                }
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
    }

    private func open(_ session: PiSessionState) {
        close()
        workspace.openSession(session.id, sessionID: session.sessionID)
    }
}

/// 在做的那几格：一格一个会话（`PiSessionRow`，按 `LiveWork.rows` 的先后，要你注意的在前），格高就是一行的高（名字一行、状态一行），
/// 有没有会话、有几个都占同样几格；没有时一句话居中在这几格里。最多 `most` 格，给的高放不下就少几格（`ViewThatFits` 从多到少试）：
/// 只随屏高与字号变，不随会话变。
private struct SessionSlots: View {
    let sessions: [PiSessionState]
    let open: (PiSessionState) -> Void
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private static let most = 4

    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach((1...Self.most).reversed(), id: \.self, content: column)
        }
    }

    private func column(_ slots: Int) -> some View {
        VStack(alignment: .leading, spacing: CueHeader.rowGap) {
            ForEach(0..<slots, id: \.self) { index in
                SlotHeight().overlay(alignment: .topLeading) {
                    if index < sessions.count { row(sessions[index]) }
                }
            }
        }
        .overlay {
            if sessions.isEmpty { Text("没有在跑的会话").font(.subheadline).foregroundStyle(palette.ink3) }
        }
    }

    private func row(_ session: PiSessionState) -> some View {
        let live = services.liveSessions
        return Button { open(session) } label: {
            PiSessionRow(
                session: session, project: workspace.catalog?.project(session.projectID), delivery: live.deliveries[session.sessionID],
                rename: live.renames[session.sessionID], undelivered: live.undelivered[session.sessionID] ?? 0
            ).equatable()
                .contentShape(.rect)
        }
        .buttonStyle(.row)
    }
}

/// 一格的高：与 `PiSessionRow.Style.compact` 同样的两行字，看不见，铺满宽。
private struct SlotHeight: View {
    var body: some View {
        let style = PiSessionRow.Style.compact
        VStack(spacing: style.spacing) {
            Text(verbatim: " ").font(style.name)
            Text(verbatim: " ").font(style.line)
        }
        .frame(maxWidth: .infinity)
        .hidden()
        .accessibilityHidden(true)
    }
}
#endif
