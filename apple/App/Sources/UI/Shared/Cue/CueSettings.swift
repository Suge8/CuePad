import CueStore
import Observation
import SwiftUI

/// Cue 的设置，两端同一份：Mac 设置窗口的 Cue 那一页（`CueSettingsPane`）、手机的 Cue 设置页（`CueSettingsScreen`）与两端的启用卡
/// （`CueEnableCard`）都读写它。读的是同步的设置（`CueProfile`）、各台 Mac 自报的名字与能用的 Agent（`CueStore.allMacAgents`，Cue 能在
/// 哪台上运行就是这几台）与项目名（允许清单里写）；动作是改名、在哪台运行并启用（`AppServices.enableCue`，规则在 `CueStore.enableCue`）、停用、
/// 允许清单的一项（`CueStore.setCueAllow`），写完都立即上传。没写成的原因存在 `failure`，页面就地写出，下一次动作先清掉。
@Observable
final class CueSettingsModel {
    /// 读到的（`cueSettings(_:)` 挂上的订阅写入；第一帧当场读好）。
    var settings: CueSettings?
    private(set) var failure: String?
    /// 正在换过去并启用的那台。
    private(set) var enabling: String?

    func enable(on host: String, _ services: AppServices) {
        enabling = host
        run {
            defer { self.enabling = nil }
            try await services.enableCue(on: host)
        }
    }

    /// 在哪台运行：选一台就是换到那台并启用，nil（"不启用"）是停用。
    func run(on host: String?, _ services: AppServices) {
        guard let host else { return run { try await services.disableCue() } }
        enable(on: host, services)
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

/// Cue 页对话里显示不显示工具步骤（`AppSettings.showsCueSteps`，存本机、不同步：只管这台设备上怎么看），两端设置里同一句话。
enum CueStepsSetting {
    static let title = "显示工具步骤"
    static let note = "对话里每一轮“跑了几步、建了几件任务”那一行；关了只在它做事时于末尾写一行在做什么"
}

extension View {
    /// 读 Cue 的设置进 `model`（随设置、各台 Mac 的记录与项目变化重读）。
    func cueSettings(_ model: CueSettingsModel) -> some View { modifier(CueSettingsReader(model: model)) }
}

private struct CueSettingsReader: ViewModifier {
    @Bindable var model: CueSettingsModel
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content.observing(services.store, into: $model.settings, onError: model.fail) { try CueSettings.read(from: $0) }
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

    /// 能运行 Cue 的一台：名字（那台自报的，`MacAgents.shownName`；`here` 是这台时写"这台 Mac"）、能当大脑的几家与一家都不能用时为什么。
    struct Host: Identifiable, Equatable {
        let id: String
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
            Host(id: mac.hostID, name: mac.hostID == here ? Self.here : mac.shownName,
                 brains: CueProfile.runtimes.filter(mac.kinds.contains), whyNone: mac.whyNone)
        }
        if let here {
            let local = hosts.firstIndex { $0.id == here }.map { hosts.remove(at: $0) }
            hosts.insert(local ?? Host(id: here, name: Self.here, brains: [], whyNone: ""), at: 0)
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

    /// 两端同一套写法：选在哪台运行的那一项，与允许清单那一节（开关打开的那类在所有项目里都不用问）。
    static let hostTitle = "在哪台 Mac 上运行"
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
