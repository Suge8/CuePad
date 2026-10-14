#if os(macOS)
import CueStore
import SwiftUI

/// 设置里的"Cue"一节，每项一行 `SettingRow`（同其他各节）：第一行是启用开关，状态写它住在哪、用哪个 Agent，没能写成的原因也写在这里；
/// 下面是名字、住在哪台 Mac（这台与绑过文件夹的别的 Mac）。用哪个 Agent、模型与思考强度在 Cue 页的输入框里选（`CueConfigControls`）。
/// 都写进同步的 `CueProfile`（`AppServices.updateCue`，写完立即上传），别的设备上看到的是同一份。启用、停用经这台 Mac 的管理器（`services.cue`）：
/// 启用就是让 Cue 住在这台 Mac，选的 Agent 这台用不了就挑第一家装好并登录了的；这台一家都没有时就地说明。
struct CueSettingsSection: View {
    @Environment(AppServices.self) private var services
    @State private var data: Data?
    @State private var name = ""
    @State private var failure: String?
    /// 名字在回车或离开输入框时写入。
    @FocusState private var editing: Bool

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
        // 读到之前先按空设置排（行一直在，读库挂在它们上面；不排行时 Section 是空的，读库永远不开始）
        Section {
            rows(data ?? Data(profile: CueProfile(), hosts: []))
        }
        .observing(services.store, into: $data, onError: { failure = $0.localizedDescription }) { [here = services.hostID] store in
            var hosts = [Host(id: here, name: "这台 Mac")]
            for binding in try store.directoryBindings() where !hosts.contains(where: { $0.id == binding.hostID }) {
                hosts.append(Host(id: binding.hostID, name: binding.hostName))
            }
            return Data(profile: try store.cueProfile() ?? CueProfile(), hosts: hosts)
        }
        .onChange(of: editing) { left, _ in
            if left, let profile = data?.profile { commit(profile) }
        }
        .onChange(of: data?.profile.name, initial: true) { _, saved in name = saved ?? CueProfile.defaultName }
    }

    @ViewBuilder private func rows(_ data: Data) -> some View {
        let profile = data.profile
        SettingRow(
            title: profile.name, icon: Image(systemName: "face.smiling"), tone: failure == nil ? .calm : .failure, status: status(profile, data)
        ) {
            Toggle("在这台 Mac 上启用", isOn: Binding(get: { profile.activeHost == services.hostID }, set: enable))
                .labelsHidden().toggleStyle(.switch)
        }
        SettingRow(title: "名字", icon: Image(systemName: "tag")) {
            TextField("名字", text: $name, prompt: Text(CueProfile.defaultName)).labelsHidden().multilineTextAlignment(.trailing)
                .frame(width: Self.fieldWidth)
                .focused($editing)
                .onSubmit { commit(profile) }
        }
        SettingRow(title: "住在哪台 Mac", icon: Image(systemName: "house")) {
            Picker("住在哪台 Mac", selection: Binding(get: { profile.hostID }, set: { host in update { $0.hostID = host } })) {
                Text("还没选").tag(String?.none)
                ForEach(data.hosts) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden().fixedSize()
        }
    }

    /// 名字输入框的宽：不撑满一行。
    private static let fieldWidth: CGFloat = 200

    /// 启用那一行的状态：没写成的原因；住在别的 Mac 时说在这里启用会搬过来；启用了写用哪个 Agent；没启用写"没启用"。
    private func status(_ profile: CueProfile, _ data: Data) -> Dotted {
        if let failure { return Dotted(failure) }
        guard let active = profile.activeHost else { return "没启用" }
        if active == services.hostID { return Dotted("住在这台 Mac", profile.runtime.known?.name) }
        let host = data.hosts.first { $0.id == active }?.name ?? "别的 Mac"
        return Dotted("住在\(host)上，在这里启用就搬过来")
    }

    /// 写入名字；和库里一样就不写。
    private func commit(_ profile: CueProfile) {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text.isEmpty ? CueProfile.defaultName : text
        if value != profile.name { update { $0.name = value } }
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
        let services = services
        Task {
            do {
                try await services.updateCue(edit)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

#endif
