import CueStore
import SwiftUI

/// 等你列的一张卡：上面是它落在的任务（同一种任务行 `TaskLine`），没落在任务上的会话写会话名与"没绑任务"；下面就地处理——
/// Cue 的提问是要你定什么与它的选项（`CueChoices`，与 Cue 页"等你"卡同一套，答的方法同 `AppServices.answerCueQuestion`）；
/// 会话在问的是问题与回答框（`BoardReply`，与会话页回复同一个发送方法）。
struct BoardWaitCard: View {
    let wait: TaskBoard.Wait
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    /// 正在答的那条（写成后它从等你里消失，写不成就清掉）。
    @State private var ending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch wait.wait {
            case .message(let message, _):
                question(message.headline ?? "", by: workspace.cue.name)
                CueChoices(options: message.choices ?? [], disabled: ending, stacks: true) { answer(message, $0) }
            case .session(let session, _):
                // 在问的是整段问题连同选项（回答框里写选项原文或序号）；Cue 留给你回的是它最后那句的首句
                question(session.question?.displayText ?? PiProgress.line(of: session) ?? workspace.shown(session, delivery: nil).label, by: nil)
                BoardReply(session: session)
            }
        }
        .padding(TaskMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: TaskMetrics.cardRadius)
    }

    @ViewBuilder private var header: some View {
        if let item = wait.item {
            TaskLine(task: item.task, subtasks: item.steps, lead: item.leaf).padding(.leading, -BoardInset.ring)
        } else if case .session(let session, _) = wait.wait {
            BoardSessionHeader(session: session)
        }
    }

    /// 要你定什么那一句；Cue 问的前面写它的名字。不再画问号：列名与任务行尾的状态标已经说了在等你。
    private func question(_ text: String, by asker: String?) -> some View {
        Text([asker, CueQuestionLine.keepingTail(text)].compactMap(\.self).joined(separator: " "))
            .font(Typography.secondary.weight(.medium))
            .foregroundStyle(palette.ink).fixedSize(horizontal: false, vertical: true)
    }

    private func answer(_ message: CueMessage, _ choice: String) {
        ending = true
        workspace.attempt {
            defer { ending = false }
            try await workspace.services.answerCueQuestion(message.id, choice)
        }
    }

}

/// 推进中那一列里一个没绑没做完的任务的活会话（终端里开的、"新会话"、只有已完成的事绑着的）：就是会话列表的那一行（`PiSessionRow`，菜单栏面板、Cue 页头面板同一种），
/// 在纸里它所在项目那一段（段头已经写了项目，行里不再写），点了打开会话。
struct BoardSessionRow: View {
    let session: PiSessionState
    @Environment(AppServices.self) private var services

    var body: some View {
        let live = services.liveSessions
        BoardSessionLink(session: session) {
            PiSessionRow(
                session: session, project: nil, delivery: live.deliveries[session.sessionID],
                rename: live.renames[session.sessionID], undelivered: live.undelivered[session.sessionID] ?? 0
            ).equatable()
                .padding(.leading, BoardInset.ring).padding(.vertical, 8)
        }
    }
}

/// 等你卡上没绑任务的会话的抬头：会话名与"会话 · 没绑任务"，点了打开会话。
private struct BoardSessionHeader: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette

    var body: some View {
        BoardSessionLink(session: session) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(.session).foregroundStyle(palette.ink2)
                    Text(session.title).font(TaskMetrics.lineFont.monospaced()).foregroundStyle(palette.ink).lineLimit(1)
                }
                Text(Dotted("会话", "没绑任务")).font(TaskMetrics.caption).foregroundStyle(palette.ink3)
            }
        }
    }
}

/// 看板上点了打开会话的一块（推进中的会话行、等你卡的抬头）。
private struct BoardSessionLink<Label: View>: View {
    let session: PiSessionState
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        Button(action: open) {
            label.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityHint("打开会话")
    }

    private func open() {
        #if os(macOS)
        workspace.show(.session(session.sessionID))
        #else
        navigation.openSession(session.id, sessionID: session.sessionID, store: services.store)
        #endif
    }
}

/// 等你卡上回答会话的一行：草稿就是会话页回复框那一份（`AppSettings.replyDraft`，两处写的是同一句），发出同会话页的作答
/// （`Workspace.speak`：会话在等 CuePad 答得了的提问时这句就是答案，选项写原文或序号）；只发文字，草稿里的卡片与图片留给会话页。
/// 同步到不了 Mac 时不能发（同回复框）。
struct BoardReply: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var box: Binding<ComposerDraft> { services.settings.replyDraftBinding(for: session.id) }
    private var canSend: Bool { services.reachesPiHost && !box.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("回答 \(session.title)", text: box.text, palette: palette, axis: .vertical)
                .textFieldStyle(.plain).font(Typography.secondary).lineLimit(1...4)
                .padding(.vertical, 7)
                .onSubmit(send)
            Button(action: send) { SendGlyph(canSend ? .ready : .idle) }
                .buttonStyle(PressStyle(.button))
                .disabled(!canSend)
                .accessibilityLabel("回答")
        }
        .padding(.leading, 12).padding(.trailing, 3).padding(.vertical, 3)
        .background(palette.fill, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func send() {
        guard canSend else { return }
        _ = workspace.speak(to: .session(session, mode: .send), from: box, keeping: { var kept = $0; kept.text = ""; return kept }) { draft in
            draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
