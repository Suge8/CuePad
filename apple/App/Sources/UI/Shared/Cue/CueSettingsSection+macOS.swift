#if os(macOS)
import CueStore
import SwiftUI

/// 设置里的"Cue"一节：名字、住在哪台 Mac（这台与绑过文件夹的别的 Mac）、它的大脑用哪个 Agent 与模型、启用或停用。都写进同步的 `CueProfile`，
/// 别的设备上看到的是同一份。写入、启用、停用都经这台 Mac 的管理器（`services.cue`，写完自己上传）：启用就是让 Cue 住在这台 Mac，挑第一家装好并登录了的 Agent；
/// 这台一家都没有时就地说明。Agent 只列这台装好的（住在别的 Mac 上时全列）。
struct CueSettingsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: Data?
    @State private var name = ""
    @State private var model = ""
    @State private var failure: String?
    @FocusState private var editing: Field?

    /// 名字与模型在回车或离开输入框时写入。
    private enum Field { case name, model }

    nonisolated struct Data: Equatable, Sendable {
        var profile: CueProfile
        /// 能住的 Mac：id 与名字（这台排第一）。
        var hosts: [Host]
    }

    nonisolated struct Host: Equatable, Sendable, Identifiable {
        var id: String
        var name: String
    }

    var body: some View {
        Section {
            if let data { rows(data) }
            if let failure { Text(failure).font(Typography.meta).foregroundStyle(palette.failure) }
        } header: {
            Text("Cue").font(Typography.label).foregroundStyle(palette.ink3).padding(.top, 6)
        }
        .observing(services.store, into: $data, onError: { failure = $0.localizedDescription }) { [here = services.hostID] store in
            var hosts = [Host(id: here, name: "这台 Mac")]
            for binding in try store.directoryBindings() where !hosts.contains(where: { $0.id == binding.hostID }) {
                hosts.append(Host(id: binding.hostID, name: binding.hostName))
            }
            return Data(profile: try store.cueProfile() ?? CueProfile(), hosts: hosts)
        }
        .onChange(of: editing) { left, _ in
            if let left, let profile = data?.profile { commit(left, profile) }
        }
        .onChange(of: data?.profile, initial: true) { _, profile in
            name = profile?.name ?? CueProfile.defaultName
            model = profile?.model ?? ""
        }
    }

    @ViewBuilder private func rows(_ data: Data) -> some View {
        let profile = data.profile
        LabeledContent("名字") {
            TextField("名字", text: $name, prompt: Text(CueProfile.defaultName)).labelsHidden().multilineTextAlignment(.trailing)
                .focused($editing, equals: .name)
                .onSubmit { commit(.name, profile) }
        }
        Picker("住在哪台 Mac", selection: Binding(get: { profile.hostID }, set: { host in update { $0.hostID = host } })) {
            Text("还没选").tag(String?.none)
            ForEach(data.hosts) { Text($0.name).tag(Optional($0.id)) }
        }
        let here = profile.hostID == services.hostID
        Picker("用哪个 Agent", selection: Binding(get: { profile.runtime.known ?? .pi }, set: { runtime in update { $0.runtime = .known(runtime) } })) {
            ForEach(CueRuntime.allCases, id: \.self) { runtime in
                Text(runtime.label).tag(runtime).selectionDisabled(here && services.cue.runtimes?.contains(runtime) == false)
            }
        }
        LabeledContent("模型") {
            TextField("模型", text: $model, prompt: Text("默认")).labelsHidden().multilineTextAlignment(.trailing)
                .focused($editing, equals: .model)
                .onSubmit { commit(.model, profile) }
        }
        Picker("思考强度", selection: Binding(get: { profile.effort?.known }, set: { level in update { $0.effort = level.map { .known($0) } } })) {
            Text("默认").tag(PiThinkingLevel?.none)
            ForEach(PiThinkingLevel.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        Toggle("在这台 Mac 上启用 Cue", isOn: Binding(get: { profile.activeHost == services.hostID }, set: enable))
        if let active = profile.activeHost, active != services.hostID, let host = data.hosts.first(where: { $0.id == active }) {
            Text("\(profile.name) 住在\(host.name)上；在这里启用就搬到这台").font(Typography.meta).foregroundStyle(palette.ink3)
        }
    }

    /// 写入一个输入框的值；和库里一样就不写。
    private func commit(_ field: Field, _ profile: CueProfile) {
        switch field {
        case .name:
            let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = text.isEmpty ? CueProfile.defaultName : text
            if value != profile.name { update { $0.name = value } }
        case .model:
            let text = model.trimmingCharacters(in: .whitespaces)
            let value = text.isEmpty ? nil : text
            if value != profile.model { update { $0.model = value } }
        }
    }

    private func enable(_ on: Bool) {
        failure = nil
        let cue = services.cue
        Task {
            do {
                if on { try await cue.enable() } else { try await cue.disable() }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func update(_ edit: @escaping @Sendable (inout CueProfile) -> Void) {
        failure = nil
        let cue = services.cue
        Task {
            do {
                try await cue.update(edit)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

extension CueRuntime {
    var label: String {
        switch self {
        case .pi: "Pi"
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }
}
#endif
