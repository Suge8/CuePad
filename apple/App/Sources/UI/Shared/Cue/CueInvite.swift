import CueStore
import SwiftUI

/// 舞台自己读的（舞台开着时才读）：做完了你还没看结果的那件，与请你点头的建议。
nonisolated struct CueStageRead: Equatable, Sendable {
    var done: CueStage.Done?
    var invites: [CueInvite] = []

    static func read(from store: isolated CueStore) throws -> CueStageRead {
        let done = try store.unseenDone().flatMap { task in task.piSessionID.map { CueStage.Done(task: task.id, title: task.heading, session: $0) } }
        return CueStageRead(done: done, invites: try CueInvite.read(from: store))
    }
}

/// 舞台上请你点头的建议（邀请）：没什么要你管时，Cue 的气泡里列至多三件可以顺手做的，规则由 App 挑（不跑 Cue 的一轮：快、不花额度）。
/// 没处理的灵感（点了交给 Cue 拆成任务，你说的那句落进对话）、傍晚起明天的一次性定时（点了打开定时）。做完没看的不在这里：它先上舞台（`CueStage.Focus.done`）。
/// 什么都不会自己发生：不点就只是摆着。划掉灵感（×）是"今天先不做"（`Mark.ideaSkipped`，同步，别的设备今天也不再提）。
nonisolated struct CueInvite: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case idea, tomorrow }

    let kind: Kind
    let id: UUID
    let title: String
    let at: Date
    /// 交给 Cue 时写进那句话的卡片短 id：Cue 凭它找到是哪张（同它自己说"灵感「…」（短 id）"的写法）。
    let tag: String

    static let limit = 3
    /// 傍晚起才提明天：白天提明天的事是噪音，下班前看一眼明天正好。
    static let evening = 17

    /// 明天的定时排在最前（一天只这一条），灵感补满。
    static func read(from store: isolated CueStore, now: Date = .now, calendar: Calendar = .current) throws -> [CueInvite] {
        var tomorrow: [CueInvite] = []
        if calendar.component(.hour, from: now) >= evening, let day = calendar.date(byAdding: .day, value: 1, to: now) {
            tomorrow = try store.cueScheduleLines().lazy
                .filter { $0.repeats == nil && $0.remindAt.map { calendar.isDate($0, inSameDayAs: day) } == true }
                .prefix(1).map { CueInvite(kind: .tomorrow, id: $0.id, title: Self.firstLine($0.text), at: $0.remindAt ?? now, tag: "") }
        }
        let ideas = try store.pendingIdeas(limit: limit - tomorrow.count)
            .map { CueInvite(kind: .idea, id: $0.id, title: $0.heading, at: $0.createdAt, tag: $0.id.shortID) }
        return tomorrow + ideas
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

struct CueInviteRow: View {
    let invite: CueInvite
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Button(action: act) {
                HStack(spacing: Spacing.group) {
                    Image(icon).font(Glyph.large).foregroundStyle(palette.ink2).frame(width: Glyph.largeSize)
                    // 动作字排在第二行右边：放在标题那一行，手机上标题只剩几个字
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(verbatim: invite.title).font(Typography.bodyStrong).foregroundStyle(palette.ink).lineLimit(1)
                        HStack(spacing: Spacing.item) {
                            Text(verbatim: meta).foregroundStyle(palette.ink3).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(verb).fontWeight(.medium).foregroundStyle(palette.ink2).fixedSize()
                        }
                        .font(Typography.meta)
                    }
                }
                .padding(.horizontal, Spacing.item).padding(.vertical, Spacing.item)
                .contentShape(.rect(cornerRadius: Radius.row))
            }
            .buttonStyle(PressStyle())
            if invite.kind == .idea {
                Button(action: skip) { Image(.close).font(Glyph.small) }
                    .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
                    .foregroundStyle(palette.ink3)
                    .accessibilityLabel("今天先不做")
            }
        }
    }

    private var icon: Icon {
        switch invite.kind {
        case .idea: .idea
        case .tomorrow: .schedule
        }
    }

    private var meta: String {
        switch invite.kind {
        case .idea: Dotted(String(localized: "灵感"), DateLabel.short(invite.at)).visible
        case .tomorrow: String(localized: "明天 \(invite.at.formatted(date: .omitted, time: .shortened))")
        }
    }

    private var verb: LocalizedStringKey {
        switch invite.kind {
        case .idea: "拆成任务"
        case .tomorrow: "看看"
        }
    }

    private func act() {
        switch invite.kind {
        case .idea:
            // 交出去今天就不再提：Cue 拆完灵感就进回收站，没拆的明天再说
            skip()
            workspace.speak("把灵感「\(invite.title)」（\(invite.tag)）拆成任务", to: .cue)
            close()
        case .tomorrow:
            workspace.cue.showsSchedules = true
        }
    }

    private func skip() {
        let store = workspace.services.store, id = invite.id
        workspace.attempt { try await store.mark(.ideaSkipped(id)) }
    }
}
