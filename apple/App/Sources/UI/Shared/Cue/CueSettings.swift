import CueStore
import Observation
import SwiftUI

/// Cue 的设置，各入口同一份：两端设置里 Cue 那一组（`CueSettingsSection`）、Cue 页的开关（Mac 的"⋯"、手机 Cue 面板）、手机 Cue 面板的选 Mac
/// （`CueNowPanel`）与两端 Cue 页的启用（`CueWelcome`）都读写它。读的是同步的设置（`CueProfile`）与各台 Mac 自报的名字与能用的 Agent
/// （`CueStore.allMacAgents`，Cue 能在哪台上运行就是这几台）；动作是改名、开关（`turn`）、在哪台运行并启用（`AppServices.enableCue`，
/// 规则在 `CueStore.enableCue`），写完都立即上传。停用只经开关：它是唯一的停用入口，在哪台运行的菜单里没有"不启用"。
/// 没写成的原因存在 `failure`，页面就地写出，下一次动作先清掉。
/// 能不能启用、改 Mac 要不要先确认只读 `CueGate`。
@Observable
final class CueSettingsModel {
    /// 读到的（`cueSettings(_:)` 挂上的订阅写入；第一帧当场读好）。
    var settings: CueSettings? {
        didSet { settle() }
    }
    private(set) var failure: String?
    /// 正在改过去并启用的那台。
    private(set) var enabling: String?
    /// 开关按下、还没写进库的那一态：开关先翻过去，写完由库里的接上，不弹回再翻。
    private(set) var turning: Bool?
    /// 等你确认的改 Mac（`choose` 遇上它正在别的 Mac 上运行）：页面据此弹确认框，确认了才 `confirm`。
    var moving: CueMove?

    /// 开关此刻的样子：按下了就是按下的那一态，否则是库里的。
    var isOn: Bool { turning ?? (settings ?? .empty).isOn }

    /// 开关（`AppServices.turnCue`）：开关先翻到按下的那一态、停在那里直到库里读回来（没写成就回去）。`here` 是这台 Mac（手机为 nil）。
    func turn(_ on: Bool, here: String?, _ services: AppServices) {
        turning = on
        run {
            defer { self.settle() }
            try await services.turnCue(on, here: here)
        }
    }

    func enable(on host: String, moving: Bool = false, _ services: AppServices) {
        enabling = host
        run {
            defer { self.enabling = nil }
            try await services.enableCue(on: host, moving: moving)
        }
    }

    /// 选在哪台运行：就在那台启用，Cue 正在别的 Mac 上运行时先请你确认（`moving`）。
    func choose(_ host: CueSettings.Host, _ services: AppServices) {
        let settings = settings ?? .empty
        if case .runs(let id, let from) = settings.gate(services), id != host.id {
            moving = CueMove(to: host, from: from, cue: settings.profile.name)
        } else {
            enable(on: host.id, services)
        }
    }

    /// 确认框的确认：改在那台运行，原来那台停下。带着确认框问的那一次：按下按钮时确认框先收起（`moving` 已清掉）。
    func confirm(_ move: CueMove, _ services: AppServices) {
        enable(on: move.to.id, moving: true, services)
    }

    /// 改名：空的写回默认名；和库里一样就不写。
    func rename(_ text: String, _ services: AppServices) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? CueProfile.defaultName : trimmed
        guard name != settings?.profile.name else { return }
        run { try await services.updateCue { $0.name = name } }
    }

    /// 读不出来、写不成：原因就地写出，开关回到库里那一态。
    func fail(_ error: any Error) {
        failure = error.localizedDescription
        turning = nil
    }

    /// 库里已是按下的那一态：开关交回给库。写完时库可能还没读回来（读回来时 `settings` 再来一次）。
    private func settle() {
        if turning == settings?.isOn { turning = nil }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        failure = nil
        Task {
            do { try await work() } catch { fail(error) }
        }
    }
}

extension AppServices {
    /// Cue 的开关，各处同一个（两端设置里 Cue 那一行、Mac Cue 页的"⋯"、手机 Cue 面板、Cue 页停用后的那张小纸），也是唯一的停用入口：
    /// 关是停用（库里记着那台，`CueProfile.hostID`）；开是在接着干活的那台启用（`CueSettings.resumeHost`，规则同 `enableCue`）。
    /// 开的时候按此刻库里的读，不按界面上一次读到的。`here` 是这台 Mac（手机为 nil）。一台 Mac 都没有时开不了，各处的开关那时停用。
    func turnCue(_ on: Bool, here: String?) async throws {
        guard on else { return try await updateCue { $0.enabledAt = nil } }
        guard let host = try await CueSettings.read(from: store).resumeHost(here: here) else { return }
        try await enableCue(on: host.id, moving: false)
    }
}

/// Cue 的名字输入框（两端设置里 Cue 那一行，`CueSwitchRow`）：不带框、像那一行的名字，点进去就改；回车或离开输入框时写入
/// （`CueSettingsModel.rename`），库里的名字变了跟着回填。
struct CueNameField: View {
    let model: CueSettingsModel
    @Environment(AppServices.self) private var services
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        TextField("名字", text: $name, prompt: Text(CueProfile.defaultName))
            .textFieldStyle(.plain)
            .focused($editing)
            .onSubmit { model.rename(name, services) }
            .onChange(of: editing) { left, _ in
                if left { model.rename(name, services) }
            }
            .onChange(of: (model.settings ?? .empty).profile.name, initial: true) { _, saved in name = saved }
    }
}

extension View {
    /// 读 Cue 的设置进 `model`（随设置、各台 Mac 的记录与项目变化重读），并挂上改 Mac 前的确认框（`CueSettingsModel.moving`）：
    /// 能启用的入口都经它，确认框只有这一个。
    func cueSettings(_ model: CueSettingsModel) -> some View { modifier(CueSettingsReader(model: model)) }
}

private struct CueSettingsReader: ViewModifier {
    @Bindable var model: CueSettingsModel
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content
            .observing(services.store, into: $model.settings, onError: model.fail) { try CueSettings.read(from: $0) }
            .dialog(.verbatim(model.moving?.title ?? ""), item: $model.moving, message: model.moving.map { .verbatim($0.message) }) { move in
                [DialogButton(title: .verbatim(move.confirm)) { model.confirm(move, services) }]
            }
    }
}

/// Cue 的设置读到的那一份，与给人看的写法（两端同一套）。
nonisolated struct CueSettings: Equatable, Sendable {
    var profile: CueProfile
    var macs: [MacAgents]

    static let empty = CueSettings(profile: CueProfile(), macs: [])

    static func read(from store: isolated CueStore) throws -> CueSettings {
        CueSettings(profile: try store.cueProfile() ?? CueProfile(), macs: try store.allMacAgents())
    }

    /// 开着：在哪台 Mac 上启用着。
    var isOn: Bool { profile.activeHost != nil }

    /// 能运行 Cue 的一台：名字（那台自报的，`MacAgents.shownName`；是这台（`isHere`）时写"这台 Mac"）、能用的几家与一家都不能用时为什么。
    struct Host: Identifiable, Equatable {
        let id: String
        let isHere: Bool
        let name: String
        let brains: [AgentKind]
        let whyNone: String

        var usable: Bool { !brains.isEmpty }
        /// 能不能选它启用：一家都用不了的别的 Mac 选不了（各入口列着、写为什么，是停用项）；这台照样能选——它的记录可能还没写下，
        /// 启用前会重新探测，Cue 页上点它还会打开接入面板给装法。
        var selectable: Bool { usable || isHere }
        /// 菜单里名字下面那一行：能用的几家，或为什么一家都不能用。
        var note: String { usable ? brains.map(\.name).formatted(.list(type: .and)) : whyNone }
    }

    /// Cue 能在哪几台上运行，`here` 是这台 Mac（手机为 nil）时它排第一：这台刚启动、自己的记录还没写下时也在（启用前会先重新探测）。
    func hosts(here: String?) -> [Host] {
        var hosts = macs.map { mac in
            Host(id: mac.hostID, isHere: mac.hostID == here, name: mac.hostID == here ? Self.here : mac.shownName,
                 brains: mac.kinds, whyNone: mac.whyNone)
        }
        if let here {
            let local = hosts.firstIndex { $0.id == here }.map { hosts.remove(at: $0) }
            hosts.insert(local ?? Host(id: here, isHere: true, name: Self.here, brains: [], whyNone: ""), at: 0)
        }
        return hosts
    }

    /// 开关打开时在哪台启用：停用前那台还能选就回到它（接着干活），否则这台 Mac，再否则第一台能用的；
    /// 都不能用时仍给第一台，启用时说清为什么（`CueEnableError`）。一台都没有为 nil。
    func resumeHost(here: String?) -> Host? {
        let hosts = hosts(here: here)
        return hosts.first { $0.id == profile.hostID && $0.selectable } ?? hosts.first(where: \.selectable) ?? hosts.first
    }

    /// 在哪台运行那一行写的：此刻运行的那台的名字。
    static func shown(_ running: String, in hosts: [Host]) -> String { hosts.first { $0.id == running }?.name ?? MacAgents.unnamed }

    /// 能不能在哪台启用（`CueGate`）：按库里它此刻运行在哪台、那台自报的名字。
    @MainActor func gate(_ services: AppServices) -> CueGate {
        let running = profile.activeHost
        return CueGate.of(services, running: running, name: running.map { id in macs.first { $0.hostID == id }?.shownName ?? MacAgents.unnamed })
    }

    /// 各端同一套写法：选在哪台运行的那一行。
    static var hostTitle: String { String(localized: "在哪台 Mac 上运行") }
    #if os(iOS)
    /// 手机上还没有哪台 Mac 写下过自己（`hosts` 为空）时设置与 Cue 面板里那句。同步到不了 Mac（`AppServices.macAlert`）时写同步那一行的标题：
    /// 手机只经 iCloud 和 Mac 连上，那时去 Mac 上打开也连不上。只写标题：面板里这一块定高放不下说明，设置里说明与出路就在紧下面的同步那一组。
    /// Cue 页上给的动作是发出 Mac 版的下载链接（`macDownload`）。
    @MainActor static func noHost(_ services: AppServices) -> String {
        services.macAlert?.title ?? String(localized: "先在 Mac 上打开 CuePad")
    }
    #endif
    static let macDownload = URL(string: "https://github.com/Suge8/CuePad/releases/latest")!

    private static var here: String { String(localized: "这台 Mac") }
}

/// 改 Cue 运行的 Mac 前那一问（`CueSettingsModel.moving`），两端同一份说法：改在哪台、原来那台（`from`，它自报的名字）不再运行。
struct CueMove: Identifiable, Equatable {
    let to: CueSettings.Host
    let from: String
    /// Cue 的名字
    let cue: String

    var id: String { to.id }
    var title: String { to.isHere ? String(localized: "让 \(cue) 改在这台 Mac 上运行？") : String(localized: "让 \(cue) 改在「\(to.name)」上运行？") }
    var message: String { String(localized: "原来那台「\(from)」就不再运行 \(cue)。") }
    var confirm: String { to.isHere ? String(localized: "改在这台运行") : String(localized: "改在「\(to.name)」运行") }
}

/// 能不能在一台 Mac 上启用 Cue、改它运行的 Mac：所有入口（Cue 页的启用钮与它的多台菜单（`CueWelcome`）、手机 Cue 面板的选 Mac、接入面板 Cue 那一行、
/// 各处的开关、两端设置里在哪台运行那一行）只读这一处，
/// 规则本身落在启用的入口（`AppServices.enableCue`），这里只给界面说清楚此刻是哪种。
enum CueGate: Equatable {
    /// 这台的库还没和 iCloud 对过一遍（`AppServices.knowsSyncedFacts`）：入口写这句原因，不能启用
    case waiting(String)
    /// 正在 `id` 那台 Mac 上运行（`name` 是它自报的名字）：改到别的 Mac 要你确认（`CueMove`）
    case runs(id: String, name: String)
    /// 没启用：哪台都能直接启用
    case open

    /// `running`：它此刻运行的那台（没启用为 nil），`name` 是那台的名字。
    static func of(_ services: AppServices, running: String?, name: String?) -> CueGate {
        guard services.knowsSyncedFacts else {
            // 不通的原因只在同步那一组说（`SyncSummary`）
            return .waiting(services.syncStatus.reachesMac ? String(localized: "正在从 iCloud 同步…") : String(localized: "同步恢复后再启用"))
        }
        guard let running else { return .open }
        return .runs(id: running, name: name ?? MacAgents.unnamed)
    }

    var waitingReason: String? {
        if case .waiting(let why) = self { why } else { nil }
    }
}
