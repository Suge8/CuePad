import CueStore
import Foundation
import Observation

/// 一个窗口里 Cue 的现状（`CueDigest` 与 `CuePresence`）和 Cue 页的输入草稿：侧栏、底栏、菜单栏面板与 Cue 页都读这一份，不各自订阅。
/// 它那台 Mac 的在线期限、你最近一句等回执的时限到点由订阅重读（`CueStore.macOnline`、`cueSpeech` 登记的 `expire(at:)`），这里不另计时；
/// 只补一个库里没有的输入：到它那台 Mac 的同步此刻通不通（`reaches`）。
@Observable
final class CueWatch {
    private(set) var digest = CueDigest.empty
    /// 到 Cue 住的那台 Mac 的同步通不通（`AppServices.reaches`，`Workspace.observeCue` 接上）。
    @ObservationIgnored var reaches: (String?) -> Bool = { _ in true }
    /// Cue 页的输入（离开再回来还在）。
    var draft = ComposerDraft()
    /// "Cue 记得什么"开着。
    var showsMemory = false
    #if os(macOS)
    /// Cue 页右侧开着"运行情况"（`CueRunPanel`）。
    var showsRun = false
    #endif

    var presence: CuePresence { CuePresence.derive(digest, reachable: reaches(digest.hostID)) }
    var name: String { digest.name }
    /// 能对它说话：启用了（住的那台 Mac 不在线也能说，开机后它会读到）。
    var canHear: Bool { presence != .disabled }

    func mood(composing: Bool = false) -> CueMood {
        CueMood.of(presence, waiting: digest.waiting, composing: composing, justDone: digest.lastSaidDone)
    }

    /// 跟随资料库直到任务取消。
    func follow(_ store: CueStore) async throws {
        for try await next in store.observe({ try CueDigest.read(from: $0) }) where next != digest {
            digest = next
        }
    }
}
