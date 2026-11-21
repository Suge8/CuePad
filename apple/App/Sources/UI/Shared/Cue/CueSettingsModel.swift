import CueStore
import Observation
import SwiftUI

@Observable
final class CueSettingsModel {
    var settings: CueSettings? {
        didSet { settle() }
    }
    private(set) var failure: String?
    private(set) var enabling: String?
    private(set) var turning: Bool?
    var moving: CueMove?

    var isOn: Bool { turning ?? (settings ?? .empty).isOn }

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

    private func settle() {
        if turning == settings?.isOn { turning = nil }
    }

    private enum Action: Hashable { case turn, enable, rename, voice }
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
    @MainActor static func noHost(_ services: AppServices) -> String {
        services.syncing.macAlert?.title ?? String(localized: "先在 Mac 上打开 CuePad")
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
