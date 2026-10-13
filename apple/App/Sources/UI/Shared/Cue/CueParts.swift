import CueStore
import CueText
import SwiftUI

/// 打开一件任务（Cue 页里的卡片、"等你"关联的任务、"你不在时"的一项）：Mac 是任务浮窗，iOS 是半屏浮窗。
struct CueTaskButton<Label: View>: View {
    let task: UUID
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        Button(action: open) { label.contentShape(.rect) }
            .buttonStyle(PressStyle(.card))
    }

    private func open() {
        #if os(iOS)
        navigation.openTask(task)
        #else
        let store = workspace.services.store, id = task
        workspace.attempt { if let card = try await store.card(id) { workspace.open(card) } }
        #endif
    }
}

/// Cue 页页头（对话最上面）：大头像、名字、此刻在做什么。
struct CueHead: View {
    var composing = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let cue = workspace.cue
        VStack(spacing: 8) {
            CueAvatar(mood: cue.mood(composing: composing), presence: cue.presence, size: .head)
            Text(cue.name).font(Typography.emptyTitle).foregroundStyle(palette.ink)
            if let line = cue.presence.line(name: cue.name) {
                Text(line)
                    .font(Typography.secondary).foregroundStyle(cue.presence.isUnreachable ? palette.failure : palette.ink3)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .animation(Motion.quick, value: cue.presence)
        .accessibilityElement(children: .combine)
    }
}


/// 还没启用时 Cue 页输入框上方的那一块：Mac 上主按钮直接是"在这台 Mac 上启用"（经管理器，挑这台装好并登录了的 Agent；
/// 一家都没有时就地说明）；手机上说明去哪台 Mac 启用（之前住过的那台写出名字）。没启用时输入框发不出去。
struct CueEnableCard: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var enabling = false
    @State private var failure: String?

    var body: some View {
        let cue = workspace.cue
        VStack(alignment: .leading, spacing: 10) {
            #if os(macOS)
            Text("启用后 \(cue.name) 住在这台 Mac 上，替你派活、跟进，只在要你拿主意时找你").font(Typography.secondary).foregroundStyle(palette.ink2)
            HStack(spacing: 10) {
                Button(action: enable) {
                    HStack(spacing: 6) {
                        if enabling { Spinner(.mini) }
                        Text("在这台 Mac 上启用")
                    }
                }
                .buttonStyle(ControlButtonStyle(kind: .primary))
                .disabled(enabling)
                if let failure { Text(failure).font(Typography.meta).foregroundStyle(palette.failure).lineLimit(2) }
            }
            #else
            Label {
                Text(cue.digest.hostName.map { "到「\($0)」上打开 CuePad，在设置里启用 \(cue.name)" } ?? "到你的 Mac 上打开 CuePad，在设置里启用 \(cue.name)")
            } icon: {
                Image(systemName: "desktopcomputer")
            }
            .font(Typography.secondary).foregroundStyle(palette.ink2)
            #endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: .rect(cornerRadius: ComposerMetrics.radius, style: .continuous))
    }

    #if os(macOS)
    private func enable() {
        enabling = true
        failure = nil
        let cue = services.cue, services = services
        Task {
            defer { enabling = false }
            do {
                try await cue.enable()
                await services.upload(CueProfile.recordID)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
    #endif
}

/// 派出去的一件活：一张纸，任务圈、标题、在做那一步的状态标与一句近况，右边是最近一份预览的缩略图；随库就地更新。
/// 做完了收成一行（对勾与标题）。点它打开任务，点缩略图看预览。
struct CueTaskCard: View {
    let live: CueLiveTask
    let open: (PiPreview) -> Void
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        CueTaskButton(task: live.task.id) {
            if live.done { doneLine } else { card }
        }
        .animation(Motion.snappy, value: live.done)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开任务")
    }

    private var doneLine: some View {
        HStack(spacing: 8) {
            TaskRingView(status: .done, ring: .plain, done: true, size: 15)
            Text(live.task.title).font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(minHeight: 32)
        .transition(.opacity)
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 12) {
            TaskRingView(status: live.task.status, ring: TaskRing(live.progress), done: false, size: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(live.task.title).font(Typography.body.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(2)
                    if let progress = live.progress {
                        Text("\(progress.done)/\(progress.total)").font(Typography.meta).monospacedDigit().foregroundStyle(palette.ink3).fixedSize()
                    }
                }
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let preview = live.previews.first { CuePreviewThumb(preview: preview, open: open) }
        }
        .padding(12)
        .paper(radius: 14)
        .transition(.opacity)
    }

    /// 在做那一步的状态标与一句近况（步骤名、提问、出错原因、动作、上一轮的回答）。
    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let session {
                PiStateDot(shown: services.settings.shown(session, delivery: nil), size: 6)
            } else if live.launching {
                Spinner(.mini)
            }
            Text(Dotted(live.leaf.id == live.task.id ? nil : live.leaf.title, note)).lineLimit(1)
                .foregroundStyle(session?.waitsForYou == true ? palette.attention : session?.state == .known(.error) ? palette.failure : palette.ink2)
        }
        .font(Typography.meta)
    }

    private var session: PiSessionState? {
        #if os(macOS)
        live.session.map(workspace.withLiveState)
        #else
        live.session
        #endif
    }

    private var note: String {
        if live.launching { return "正在开会话" }
        guard let session else { return "还没开始" }
        let shown = services.settings.shown(session, delivery: nil)
        if session.waitsForYou { return session.question?.text.firstLine ?? shown.label }
        if session.state == .known(.error) { return session.detail?.firstLine ?? shown.label }
        if shown.isLive { return session.detail.flatMap(PiProgress.action) ?? shown.label }
        return session.lastReply.map { CueFormat.plainText($0).firstLine } ?? shown.label
    }

}

/// 一份预览的缩略图：图片是图本身，其余是类型图标；点它全屏看（`previewPresenter`）。
struct CuePreviewThumb: View {
    let preview: PiPreview
    var side: CGFloat = 44
    let open: (PiPreview) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button { open(preview) } label: {
            Group {
                if preview.kind == .image {
                    Thumbnail(hash: preview.hash, height: side, radius: 8)
                } else {
                    Image(systemName: PreviewCard.symbol(preview.kind)).font(.title3).foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(palette.fill, in: .rect(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(width: side, height: side)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel("预览：\(preview.title)")
        #if os(macOS)
        .help(preview.title)
        #endif
    }
}

nonisolated extension String {
    /// 第一行非空的字（近况、提问只占一行）。
    var firstLine: String {
        split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}

/// 连着的几条动态（Cue 自己醒来那一轮的经过）：折成一行灰字，点开看全。
struct CueNotes: View {
    let notes: [CueMessage]
    @State private var expanded = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(Motion.quick) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(Dotted(CueFormat.plainText(notes.last?.text ?? "").firstLine, notes.count > 1 ? "\(notes.count) 条" : nil))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
                .frame(minHeight: 24).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "收起" : "展开")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notes) { note in
                        Text(CueFormat.plainText(note.text)).font(Typography.meta).foregroundStyle(palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .selectable()
                    }
                }
                .padding(.leading, 15)
                .transition(.opacity)
            }
        }
        .transition(.entry)
    }
}

/// Cue 说的一句：左侧全宽 Markdown（同会话里 Agent 的回答）；问过你的、答了的下面一行写你选的那一项（还在等的不在对话里，见 `CueThread.rows`）。
struct CueSays: View {
    let message: CueMessage
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownText(source: message.text).equatable()
            if let answer = message.answer {
                Label(answer, systemImage: "arrowshape.turn.up.left").font(Typography.meta).foregroundStyle(palette.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.entry)
    }
}

/// "等你"：固定在输入框上方，最早的那一条。问题、关联任务发来看的文件（缩略图，验收的证据）、推荐的答案（第一个选项）作主按钮、
/// 其余选项、关联的任务；还有别的在等时写一句。
struct CueWaitingDock: View {
    let waiting: [CueMessage]
    let tasks: [UUID: CueLiveTask]
    let open: (PiPreview) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var answered: Set<UUID> = []

    var body: some View {
        if let message = waiting.first(where: { !answered.contains($0.id) }) {
            Callout(tint: palette.attention, symbol: "questionmark.circle.fill", text: CueFormat.plainText(message.text), docked: true) {
                VStack(alignment: .leading, spacing: 10) {
                    // 关联任务发来看的文件就是证据：在手机上看完图再点答案，验收就做完了
                    if let id = message.taskID, let previews = tasks[id]?.previews, !previews.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) { ForEach(previews) { CuePreviewThumb(preview: $0, side: 64, open: open) } }
                        }
                    }
                    choices(message)
                    HStack(spacing: 10) {
                        if let id = message.taskID, let live = tasks[id] {
                            CueTaskButton(task: id) {
                                HStack(spacing: 6) {
                                    TaskRingView(status: live.task.status, ring: .plain, done: live.done, size: 13)
                                    Text(live.task.title).lineLimit(1)
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                }
                                .font(Typography.meta).foregroundStyle(palette.ink2)
                            }
                            .accessibilityLabel("关于 \(live.task.title)")
                        }
                        Spacer(minLength: 0)
                        let others = waiting.count - answered.count - 1
                        if others > 0 { Text("还有 \(others) 条").font(Typography.meta).foregroundStyle(palette.ink3) }
                    }
                }
            }
            .id(message.id)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func choices(_ message: CueMessage) -> some View {
        let options = message.choices ?? []
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons(message, options) }
            VStack(alignment: .leading, spacing: 8) { buttons(message, options) }
        }
    }

    @ViewBuilder private func buttons(_ message: CueMessage, _ options: [String]) -> some View {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            Button(option) { answer(message, option) }
                .buttonStyle(ControlButtonStyle(kind: index == 0 ? .primary : .secondary))
                .lineLimit(2)
        }
    }

    private func answer(_ message: CueMessage, _ option: String) {
        withAnimation(Motion.quick) { _ = answered.insert(message.id) }
        workspace.answerCue(message, option)
    }
}

/// "你不在时"：回到 Cue 页时，离开期间有变化就在对话最上面放一张：完成了几件、几件新问你的、哪些出错；点一项进那件任务。
struct CueAwayCard: View {
    let away: CueAway
    let dismiss: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Dotted(
                    away.done.isEmpty ? nil : "完成了 \(away.done.count) 件", away.asked > 0 ? "\(away.asked) 件在等你" : nil,
                    away.failed.isEmpty ? nil : "\(away.failed.count) 件出错"))
                    .font(Typography.body.weight(.semibold)).foregroundStyle(palette.ink)
                Spacer(minLength: 8)
                Button("收起", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink3)
                    .frame(width: 28, height: 28).contentShape(.rect)
                    .buttonStyle(PressStyle(.button))
            }
            ForEach(away.failed) { item(item: $0, failed: true) }
            ForEach(away.done) { item(item: $0, failed: false) }
        }
        .padding(14)
        .paper(radius: 16)
        .transition(.opacity)
    }

    private func item(item: CueAway.Item, failed: Bool) -> some View {
        CueTaskButton(task: item.id) {
            HStack(spacing: 8) {
                if failed {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(palette.failure).font(.system(size: 14))
                } else {
                    TaskRingView(status: .done, ring: .plain, done: true, size: 14)
                }
                Text(item.title).font(Typography.secondary).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.ink3)
            }
            .frame(minHeight: 28)
        }
        .accessibilityLabel(failed ? "出错：\(item.title)" : "完成：\(item.title)")
    }
}
