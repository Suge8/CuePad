import CueStore
import Observation
import SwiftUI

/// 停用只经开关：它是唯一的停用入口，在哪台运行的菜单里没有"不启用"。
/// 没写成的原因存在 `failure`，页面就地写出，下一次动作先清掉。能不能启用、改 Mac 要不要先确认只读 `CueGate`。
@Observable
final class CueSettingsModel {
    var settings: CueSettings? {
        didSet { settle() }
    }
    private(set) var failure: String?
    private(set) var enabling: String?
    /// 开关按下、还没写进库的那一态：开关先翻过去，写完由库里的接上，不弹回再翻。
    private(set) var turning: Bool?
    var moving: CueMove?

    var isOn: Bool { turning ?? (settings ?? .empty).isOn }

    /// 开关先翻到按下的那一态、停在那里直到库里读回来（没写成就回去）。`here` 是这台 Mac（手机为 nil）。
    func turn(_ on: Bool, here: String?, _ services: AppServices) {
        turning = on
        run(.turn) { try await services.turnCue(on, here: here) } finished: { self.settle() }
    }

    func enable(on host: String, moving: Bool = false, _ services: AppServices) {
        enabling = host
        run(.enable) { try await services.enableCue(on: host, moving: moving) } finished: { self.enabling = nil }
    }

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

    func rename(_ text: String, _ services: AppServices) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? CueProfile.defaultName : trimmed
        guard name != settings?.profile.name else { return }
        run(.rename) { try await services.updateCue { $0.name = name } } finished: {}
    }

    func chooseVoice(_ voice: CueVoice, _ services: AppServices) {
        guard voice != settings?.profile.callVoice else { return }
        run(.voice) { try await services.updateCue { $0.voice = .known(voice) } } finished: {}
    }

    func fail(_ error: any Error) {
        failure = error.localizedDescription
        turning = nil
    }

    /// 库里已是按下的那一态：开关交回给库。写完时库可能还没读回来（读回来时 `settings` 再来一次）。
    private func settle() {
        if turning == settings?.isOn { turning = nil }
    }

    private enum Action: Hashable { case turn, enable, rename, voice }
    /// 每种动作最新的一代：连续按时只有最新的一次改界面状态，先到的旧结果（完成或失败）不清掉后来那次的忙与乐观翻转。
    @ObservationIgnored private var generations: [Action: Int] = [:]

    private func run(_ action: Action, _ work: @escaping @MainActor () async throws -> Void, finished: @escaping @MainActor () -> Void) {
        failure = nil
        let mine = (generations[action] ?? 0) + 1
        generations[action] = mine
        Task {
            var failed: (any Error)?
            do { try await work() } catch { failed = error }
            guard generations[action] == mine else { return }
            if let failed {
                failure = failed.localizedDescription
                if action == .turn { turning = nil }
            }
            finished()
        }
    }
}

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

extension CueSettings {
    static func shown(_ running: String, in hosts: [Host]) -> String { hosts.first { $0.id == running }?.name ?? MacAgents.unnamed }

    static var hostTitle: String { String(localized: "在哪台 Mac 上运行") }
    #if os(iOS)
    /// 只写标题：面板里这一块定高放不下说明，设置里说明与出路就在紧下面的同步那一组。同步到不了 Mac 时写同步那一行的标题：手机只经 iCloud 和 Mac 连上，那时去 Mac 上打开也连不上。
    @MainActor static func noHost(_ services: AppServices) -> String {
        services.macAlert?.title ?? String(localized: "先在 Mac 上打开 CuePad")
    }
    #endif
    static let macDownload = URL(string: "https://github.com/Suge8/CuePad/releases/latest")!
}

extension CueSettings.Host {
    var note: String { usable ? brains.map(\.name).formatted(.list(type: .and)) : whyNone }
}

struct CueMove: Identifiable, Equatable {
    let to: CueSettings.Host
    let from: String
    let cue: String

    var id: String { to.id }
    var title: String { to.isHere ? String(localized: "让 \(cue) 改在这台 Mac 上运行？") : String(localized: "让 \(cue) 改在「\(to.name)」上运行？") }
    var message: String { String(localized: "原来那台「\(from)」就不再运行 \(cue)。") }
    var confirm: String { to.isHere ? String(localized: "改在这台运行") : String(localized: "改在「\(to.name)」运行") }
}
