import CueStore
import Foundation
import Observation

/// 一个窗口里 Cue 的现状（`CueDigest` 与 `CuePresence`）和 Cue 页的输入草稿：侧栏、底栏、菜单栏面板与 Cue 页都读这一份，不各自订阅。
/// 在不在、"等你 N"随此刻（`SpeechClock`）到点与同步通断重算，不另计时。
@Observable
final class CueWatch {
    private(set) var digest = CueDigest.empty
    /// 读到 `digest` 的那一刻（`AppServices.speech`）：Cue 在不在按它推。
    private(set) var moment = Speech.Moment.always()
    /// Cue 页的输入（离开再回来还在）。
    var draft = ComposerDraft()
    /// "Cue 记得什么"开着。
    var showsMemory = false
    #if os(macOS)
    /// Cue 页右侧开着"运行情况"（`CueRunPanel`）。
    var showsRun = false
    #endif

    var presence: CuePresence { CuePresence.derive(digest, at: moment) }
    var name: String { digest.name }
    /// 能对它说话：启用了（住的那台 Mac 不在线也能说，开机后它会读到）。
    var canHear: Bool { presence != .disabled }

    func mood(composing: Bool = false) -> CueMood {
        CueMood.of(presence, waiting: digest.waiting, composing: composing, justDone: digest.lastSaidDone)
    }

    /// 跟随资料库与此刻直到任务取消。
    func follow(_ services: AppServices) async throws {
        for try await (next, moment) in services.observeTimed({ store, moment in try CueDigest.read(from: store, at: moment) }) {
            if next != digest { digest = next }
            if moment != self.moment { self.moment = moment }
        }
    }
}
