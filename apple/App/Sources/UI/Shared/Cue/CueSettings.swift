import CueStore
import Observation
import SwiftUI

/// Cue 的设置，两端同一份：Mac 设置窗口的 Cue 那一页（`CueSettingsPane`）、手机的 Cue 设置页（`CueSettingsScreen`）与两端 Cue 页的启用
/// （`CueWelcome`）都读写它。读的是同步的设置（`CueProfile`）、各台 Mac 自报的名字与能用的 Agent（`CueStore.allMacAgents`，Cue 能在
/// 哪台上运行就是这几台）与项目名（允许清单里写）；动作是改名、在哪台运行并启用（`AppServices.enableCue`，规则在 `CueStore.enableCue`）、停用、
/// 允许清单的一项（`CueStore.setCueAllow`），写完都立即上传。没写成的原因存在 `failure`，页面就地写出，下一次动作先清掉。
/// 能不能启用、改 Mac 要不要先确认只读 `CueGate`。
@Observable
final class CueSettingsModel {
    /// 读到的（`cueSettings(_:)` 挂上的订阅写入；第一帧当场读好）。
    var settings: CueSettings?
    private(set) var failure: String?
    /// 正在改过去并启用的那台。
    private(set) var enabling: String?
    /// 等你确认的改 Mac（`choose` 遇上它正在别的 Mac 上运行）：页面据此弹确认框，确认了才 `confirm`。
    var moving: CueMove?

    func enable(on host: String, moving: Bool = false, _ services: AppServices) {
        enabling = host
        run {
            defer { self.enabling = nil }
            try await services.enableCue(on: host, moving: moving)
        }
    }

    /// 设置里的"在哪台运行"：nil（"不启用"）是停用；选一台就是在那台启用，Cue 正在别的 Mac 上运行时先请你确认（`moving`）。
    func choose(_ host: CueSettings.Host?, _ services: AppServices) {
        guard let host else { return run { try await services.updateCue { $0.enabledAt = nil } } }
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

    func allow(_ item: CueAllow, _ allowed: Bool, _ services: AppServices) {
        run { if try await services.store.setCueAllow(item, allowed: allowed) { await services.upload(CueProfile.recordID) } }
    }

    /// 读不出来、写不成：原因就地写出。
    func fail(_ error: any Error) { failure = error.localizedDescription }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        failure = nil
        Task {
            do { try await work() } catch { fail(error) }
        }
    }
}

/// Cue 的名字输入框（两端设置同一个）：回车或离开输入框时写入（`CueSettingsModel.rename`），库里的名字变了跟着回填。
struct CueNameField: View {
    let model: CueSettingsModel
    @Environment(AppServices.self) private var services
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        TextField("名字", text: $name, prompt: Text(CueProfile.defaultName))
            .multilineTextAlignment(.trailing)
            .focused($editing)
            .onSubmit { model.rename(name, services) }
            .onChange(of: editing) { left, _ in
                if left { model.rename(name, services) }
            }
            .onChange(of: (model.settings ?? .empty).profile.name, initial: true) { _, saved in name = saved }
    }
}

/// Cue 页对话里显示不显示工具步骤（`AppSettings.showsCueSteps`，存本机、不同步：只管这台设备上怎么看），两端设置里同一句话。
enum CueStepsSetting {
    static let title = "显示工具步骤"
    static let note = "对话里每一轮“跑了几步、建了几件任务”那一行；关了只在它做事时于末尾写一行在做什么"
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
            .dialog(model.moving?.title ?? "", item: $model.moving, message: model.moving?.message) { move in
                [DialogButton(title: move.confirm) { model.confirm(move, services) }]
            }
    }
}

/// Cue 的设置读到的那一份，与给人看的写法（两端同一套）。
nonisolated struct CueSettings: Equatable, Sendable {
    var profile: CueProfile
    var macs: [MacAgents]
    /// 项目的名字（允许清单里只管一个项目的那几项写它的名字）。
    var projects: [UUID: String]

    static let empty = CueSettings(profile: CueProfile(), macs: [], projects: [:])

    static func read(from store: isolated CueStore) throws -> CueSettings {
        CueSettings(
            profile: try store.cueProfile() ?? CueProfile(), macs: try store.allMacAgents(),
            projects: Dictionary(try store.projects().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
    }

    /// 能运行 Cue 的一台：名字（那台自报的，`MacAgents.shownName`；是这台（`isHere`）时写"这台 Mac"）、能当大脑的几家与一家都不能用时为什么。
    struct Host: Identifiable, Equatable {
        let id: String
        let isHere: Bool
        let name: String
        let brains: [AgentKind]
        let whyNone: String

        var usable: Bool { !brains.isEmpty }
        /// 菜单里名字下面那一行：能当大脑的几家，或为什么一家都不能用。
        var note: String { usable ? brains.map(\.name).joined(separator: "、") : whyNone }
    }

    /// Cue 能在哪几台上运行，`here` 是这台 Mac（手机为 nil）时它排第一：这台刚启动、自己的记录还没写下时也在（启用前会先重新探测）。
    func hosts(here: String?) -> [Host] {
        var hosts = macs.map { mac in
            Host(id: mac.hostID, isHere: mac.hostID == here, name: mac.hostID == here ? Self.here : mac.shownName,
                 brains: CueProfile.runtimes.filter(mac.kinds.contains), whyNone: mac.whyNone)
        }
        if let here {
            let local = hosts.firstIndex { $0.id == here }.map { hosts.remove(at: $0) }
            hosts.insert(local ?? Host(id: here, isHere: true, name: Self.here, brains: [], whyNone: ""), at: 0)
        }
        return hosts
    }

    /// 允许清单的一类：所有项目都不用问（`all`），与只管一个项目的几项（名字是「项目名」，删了的写"已删的项目"）。规矩那一类没有。
    struct AllowGroup: Identifiable {
        let ask: CueAsk
        let all: Bool
        let projects: [(allow: CueAllow, name: String)]

        var id: CueAsk { ask }
        var everywhere: CueAllow { CueAllow(ask, project: nil) }
    }

    /// 能不能在哪台启用（`CueGate`）：按库里它此刻运行在哪台、那台自报的名字。
    @MainActor func gate(_ services: AppServices) -> CueGate {
        let running = profile.activeHost
        return CueGate.of(services, running: running, name: running.map { id in macs.first { $0.hostID == id }?.shownName ?? MacAgents.unnamed })
    }

    /// 两端同一套写法：选在哪台运行的那一项，与允许清单那一节（开关打开的那类在所有项目里都不用问）。
    static let hostTitle = "在哪台 Mac 上运行"
    /// 手机上还没有哪台 Mac 写下过自己（`hosts` 为空）时 Cue 设置里那句；Cue 页上给的动作是发出 Mac 版的下载链接（`macDownload`）。
    static let noHost = "先在 Mac 上打开 CuePad"
    static let macDownload = URL(string: "https://github.com/Suge8/CuePad/releases/latest")!
    static let allowsTitle = "不用先问的事"
    static func allowsNote(_ name: String) -> String {
        "推送、删除这类收不回的事，\(name) 做之前会先问你；打开的那类在所有项目里直接做。在它的提问上选\u{201C}以后……不用问\u{201D}也记在这里。"
    }

    var allowGroups: [AllowGroup] {
        let allows = profile.allows
        return CueAsk.allCases.filter { $0.always != nil }.map { ask in
            let projects = allows.filter { $0.ask == .known(ask) && $0.project != nil }
                .map { (allow: $0, name: $0.project.flatMap { projects[$0] }.map { "「\($0)」" } ?? "已删的项目") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return AllowGroup(ask: ask, all: allows.contains(CueAllow(ask, project: nil)), projects: projects)
        }
    }

    private static let here = "这台 Mac"
}

/// 改 Cue 运行的 Mac 前那一问（`CueSettingsModel.moving`），两端同一份说法：改在哪台、原来那台（`from`，它自报的名字）不再运行。
struct CueMove: Identifiable, Equatable {
    let to: CueSettings.Host
    let from: String
    /// Cue 的名字
    let cue: String

    var id: String { to.id }
    var title: String { to.isHere ? "让 \(cue) 改在这台 Mac 上运行？" : "让 \(cue) 改在「\(to.name)」上运行？" }
    var message: String { "原来那台「\(from)」就不再运行 \(cue)。" }
    var confirm: String { to.isHere ? "改在这台运行" : "改在「\(to.name)」运行" }
}

/// 能不能在一台 Mac 上启用 Cue、改它运行的 Mac：所有入口（Cue 页的启用卡与它的多台菜单、接入面板 Cue 那一行、两端设置里的选择器）只读这一处，
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
            return .waiting(services.syncStatus == .offline ? "连上 iCloud 后再启用" : "正在从 iCloud 同步…")
        }
        guard let running else { return .open }
        return .runs(id: running, name: name ?? MacAgents.unnamed)
    }

    var waitingReason: String? {
        if case .waiting(let why) = self { why } else { nil }
    }
}
