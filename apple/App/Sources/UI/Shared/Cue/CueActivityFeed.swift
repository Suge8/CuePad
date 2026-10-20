import CueStore
import Foundation

/// 实时活动那一份（`CueActivityState`）从库里怎么推：表情、在管与等你只从 Cue 的摘要来（`CueDigest`，数只读 `CueStore.cueTally`），
/// 第一件等你是摘要里等你的第一件，做完是今天做完的顶层任务（`CueStore.tasksDone`，去掉被等你占着的，同任务看板的做完列）。iPhone 上开着它的是 `CueLiveActivity`。
nonisolated extension CueActivityState {
    /// 一次读到的：摘要与今天做完的顶层任务（最近的在前）。
    struct Reading: Equatable, Sendable {
        var digest: CueDigest
        var done: [Card]

        static func read(from store: isolated CueStore) throws -> Reading {
            let digest = try CueDigest.read(from: store)
            return Reading(digest: digest, done: digest.tally.free(try store.tasksDone(since: Calendar.current.startOfDay(for: .now))))
        }
    }

    /// 表情按此刻（`moment`）推，同 Cue 那一行与小组件。
    init(_ reading: Reading, at moment: Speech.Moment) {
        let digest = reading.digest
        mood = digest.mood(at: moment).rawValue
        managing = digest.managing
        waiting = digest.waiting
        done = reading.done.count
        first = digest.tally.waiting.first.map { Self.wait($0, name: digest.name) }
        lastDone = reading.done.first.flatMap { task in task.completedAt.map { Done(title: task.title, at: $0) } }
        at = moment.now
    }

    /// Cue 的提问：要做的动作（`CueAsking.action`）与它请你允许哪一类事（规矩那一类是引的规矩），打开是 Cue 页，带选项的能"允许一次"（选第一项）；
    /// 会话在问：会话名与问题的第一行，打开是那个会话。
    private static func wait(_ wait: CueTally.Wait, name: String) -> Wait {
        switch wait {
        case .message(let message, _):
            let asking = message.asking
            return Wait(
                title: asking?.action ?? message.headline ?? "\(name) 在等你",
                detail: asking.map { $0.why ?? "\(name) 请你允许\($0.ask.name)" },
                open: DeepLink.cue.url,
                allow: message.choices?.first.map { Allow(message: message.id, choice: $0) })
        case .session(let state, _):
            let question = state.question?.text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
            return Wait(
                title: state.title.isEmpty ? "会话" : state.title,
                detail: question.flatMap { $0.isEmpty ? nil : $0 } ?? "在等你回答",
                open: DeepLink.session(state.id).url,
                allow: nil)
        }
    }
}
