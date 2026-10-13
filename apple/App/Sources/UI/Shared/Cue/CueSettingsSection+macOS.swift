#if os(macOS)
import CueStore
import SwiftUI

/// 设置里的"Cue"一节：名字、住在哪台 Mac（这台与绑过文件夹的别的 Mac）、它的大脑用哪个 Agent 与模型、启用或停用。都写进同步的 `CueProfile`，
/// 别的设备上看到的是同一份。启用要先选好住在哪台 Mac。
struct CueSettingsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: Data?
    @State private var name = ""
    @State private var model = ""
    @State private var failure: String?

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
        .onChange(of: data?.profile, initial: true) { _, profile in
            name = profile?.name ?? CueProfile.defaultName
            model = profile?.model ?? ""
        }
    }

    @ViewBuilder private func rows(_ data: Data) -> some View {
        let profile = data.profile
        LabeledContent("名字") {
            TextField("名字", text: $name, prompt: Text(CueProfile.defaultName)).labelsHidden().multilineTextAlignment(.trailing)
                .onSubmit { let text = name; update { $0.name = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CueProfile.defaultName : text } }
        }
        Picker("住在哪台 Mac", selection: Binding(get: { profile.hostID }, set: { host in update { $0.hostID = host } })) {
            Text("还没选").tag(String?.none)
            ForEach(data.hosts) { Text($0.name).tag(Optional($0.id)) }
        }
        Picker("用哪个 Agent", selection: Binding(get: { profile.runtime.known ?? .pi }, set: { runtime in update { $0.runtime = .known(runtime) } })) {
            ForEach(CueRuntime.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        LabeledContent("模型") {
            TextField("模型", text: $model, prompt: Text("默认")).labelsHidden().multilineTextAlignment(.trailing)
                .onSubmit { let text = model.trimmingCharacters(in: .whitespaces); update { $0.model = text.isEmpty ? nil : text } }
        }
        Picker("思考强度", selection: Binding(get: { profile.effort?.known }, set: { level in update { $0.effort = level.map { .known($0) } } })) {
            Text("默认").tag(PiThinkingLevel?.none)
            ForEach(PiThinkingLevel.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        Toggle("启用 Cue", isOn: Binding(get: { profile.enabledAt != nil }, set: { on in update { $0.enabledAt = on ? .now : nil } }))
            .disabled(profile.hostID == nil)
    }

    private func update(_ edit: @escaping @Sendable (inout CueProfile) -> Void) {
        failure = nil
        let store = services.store
        Task {
            do {
                try await store.updateCueProfile(edit)
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
