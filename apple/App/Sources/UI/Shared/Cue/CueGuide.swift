import CueStore
import CueSync
import SwiftUI

/// Cue 还不能听你说话时，由它自己开口带你接好：此刻卡在哪一步全由库与同步状态推出来（`of`），不另记走到了第几步；
/// 每一步它说哪几句（`lines`），右边给你哪一下由 `CueWelcome` 按步子排。
enum CueGuide: Equatable {
    case ready
    case waiting(String)
    /// 没有 Mac 时是有几台、还没定在哪台：给你挑。
    case enable(CueSettings.Host?)
    #if os(iOS)
    case offline(SyncStatus)
    case install
    case agents(mac: String)
    #endif

    struct Line: Hashable {
        let text: String
        var detail: String?
        var busy = false
        var failed = false
    }

    static func of(_ settings: CueSettings, here: String?, canHear: Bool, services: AppServices) -> CueGuide {
        if canHear { return .ready }
        #if os(iOS)
        let status = services.syncing.state.status
        if !status.reachesMac { return .offline(status) }
        #endif
        if let why = settings.gate(services).waitingReason { return .waiting(why) }
        #if os(iOS)
        guard let mac = settings.macs.first else { return .install }
        if settings.macs.allSatisfy(\.kinds.isEmpty) { return .agents(mac: mac.shownName) }
        #endif
        return .enable(settings.primaryHost(here: here))
    }

    /// `intro`：空着的 Cue 页，打个招呼从头说；不然（已有对话、它停着）只说最后那句。
    func lines(name: String, intro: Bool) -> [Line] {
        let said = said
        if intro { return [Line(text: String(localized: "嗨，我是 \(name)。"))] + said }
        if case .enable(let host) = self, host?.usable != false { return [Line(text: String(localized: "启用我，接着干活。"))] }
        return said.suffix(1)
    }

    private var said: [Line] {
        switch self {
        case .ready:
            [Line(text: String(localized: "要做什么，直接跟我说。"))]
        case .waiting(let why):
            [Line(text: why, busy: true)]
        case .enable(let host?) where host.isHere && !host.usable:
            [Line(text: String(localized: "我借 Agent 的手干活。")), Line(text: String(localized: "先在这台 Mac 上接一个吧。"))]
        case .enable(let host?):
            #if os(iOS)
            [Line(text: String(localized: "「\(host.name)」上接好了 \(host.note)。")), Line(text: String(localized: "让我在那儿开工？要你拿主意时，我发通知找你。"))]
            #else
            [Line(text: host.isHere ? String(localized: "说一件想做的事，我来开工；要你拿主意时，我再找你。") : String(localized: "让我在「\(host.name)」上开工？"))]
            #endif
        case .enable(nil):
            [Line(text: String(localized: "你有好几台 Mac，挑一台让我开工。"))]
        #if os(iOS)
        case .offline(let status):
            [Line(text: String(localized: "我住在你的 Mac 上，靠 iCloud 跟手机碰头。")), Line(text: SyncSummary(status).title, detail: SyncSummary(status).detail)]
        case .install:
            [Line(text: String(localized: "我住在你的 Mac 上，替你看着 Agent 干活。")), Line(text: String(localized: "在 Mac 上装好 CuePad、登同一个 iCloud，我就来了。"))]
        case .agents(let mac):
            [Line(text: String(localized: "找到你的「\(mac)」了。")), Line(text: String(localized: "再在它上面接一个 Agent，我借它的手干活。"))]
        #endif
        }
    }
}

extension CueSettings {
    /// 不用挑就知道该在哪台启用：只有一台、之前定过、或就是这台 Mac。
    func primaryHost(here: String?) -> Host? {
        let hosts = hosts(here: here)
        guard hosts.count == 1 || profile.hostID != nil || hosts.first?.isHere == true else { return nil }
        return resumeHost(here: here)
    }
}
