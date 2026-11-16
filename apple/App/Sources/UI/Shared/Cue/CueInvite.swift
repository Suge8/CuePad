import CueStore
import SwiftUI

/// 舞台上请你点头的建议（邀请）：没什么要你管时，Cue 的气泡里列至多三件可以顺手做的，规则由 App 挑（不跑 Cue 的一轮：快、不花额度）。
/// 做完了你还没看结果的（点了打开那件任务，记为看过）、没处理的灵感（点了交给 Cue 拆成任务，你说的那句落进对话）、傍晚起明天的一次性定时（点了打开定时）。
/// 什么都不会自己发生：不点就只是摆着。划掉（×）是"今天先不做"：灵感搁到明天 0 点，做完的记为看过；两样都同步，别的设备也不再提。
/// 先各出一件、再补满：三件都是灵感时看不出还有别的可做。
nonisolated struct CueInvite: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case done, idea, tomorrow }

    let kind: Kind
    let id: UUID
    let title: String
    let at: Date
    /// 交给 Cue 时写进那句话的卡片短 id：Cue 凭它找到是哪张（同它自己说"灵感「…」（短 id）"的写法）。
    let tag: String

    static let limit = 3
    /// 傍晚起才提明天：白天提明天的事是噪音，下班前看一眼明天正好。
    static let evening = 17

    static func read(from store: isolated CueStore, now: Date = .now, calendar: Calendar = .current) throws -> [CueInvite] {
        let found = try store.inviteCandidates(ideas: limit, unseenDone: limit)
        let done = found.unseenDone.map { CueInvite(kind: .done, id: $0.id, title: $0.heading, at: $0.completedAt ?? $0.modifiedAt, tag: $0.id.shortID) }
        let ideas = found.ideas.map { CueInvite(kind: .idea, id: $0.id, title: $0.heading, at: $0.createdAt, tag: $0.id.shortID) }
        var tomorrow: [CueInvite] = []
        if calendar.component(.hour, from: now) >= evening, let day = calendar.date(byAdding: .day, value: 1, to: now) {
            tomorrow = try store.cueScheduleLines().lazy
                .filter { $0.repeats == nil && $0.remindAt.map { calendar.isDate($0, inSameDayAs: day) } == true }
                .prefix(1).map { CueInvite(kind: .tomorrow, id: $0.id, title: Self.firstLine($0.text), at: $0.remindAt ?? now, tag: "") }
        }
        let firsts = [done.first, ideas.first, tomorrow.first].compactMap(\.self)
        return Array((firsts + done.dropFirst() + ideas.dropFirst()).prefix(limit))
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
                    Image(icon).font(Glyph.large).foregroundStyle(tint).frame(width: Glyph.largeSize)
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
            if invite.kind != .tomorrow {
                Button(action: shelve) { Image(.close).font(Glyph.small) }
                    .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
                    .foregroundStyle(palette.ink3)
                    .accessibilityLabel("今天先不做")
            }
        }
    }

    private var icon: Icon {
        switch invite.kind {
        case .done: .done
        case .idea: .idea
        case .tomorrow: .schedule
        }
    }

    private var tint: Color {
        invite.kind == .done ? CueNow.Tone.done.color(palette) : palette.ink2
    }

    private var meta: String {
        switch invite.kind {
        case .done: Dotted(String(localized: "做完，还没看结果"), DateLabel.short(invite.at)).visible
        case .idea: Dotted(String(localized: "灵感"), DateLabel.short(invite.at)).visible
        case .tomorrow: String(localized: "明天 \(invite.at.formatted(date: .omitted, time: .shortened))")
        }
    }

    private var verb: LocalizedStringKey {
        switch invite.kind {
        case .done: "看结果"
        case .idea: "拆成任务"
        case .tomorrow: "看看"
        }
    }

    private func act() {
        let store = workspace.services.store, id = invite.id
        switch invite.kind {
        case .done:
            close()
            workspace.openTask(id: id)
        case .idea:
            // 交出去就不再提：Cue 拆完灵感就进回收站，没拆的明天再说
            workspace.attempt { try await store.shelve(id, until: Self.tomorrow) }
            workspace.speak("把灵感「\(invite.title)」（\(invite.tag)）拆成任务", to: .cue)
            close()
        case .tomorrow:
            workspace.cue.showsSchedules = true
        }
    }

    private func shelve() {
        let store = workspace.services.store, id = invite.id
        switch invite.kind {
        case .done: workspace.attempt { try await store.markSeen(id) }
        case .idea: workspace.attempt { try await store.shelve(id, until: Self.tomorrow) }
        case .tomorrow: break
        }
    }

    private static var tomorrow: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
    }
}
