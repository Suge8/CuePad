#if os(macOS)
import SwiftUI

/// 设置窗口通用那一页最上面一组：Cue 的名字与在哪台 Mac 上运行，各一行 `SettingRow`，组名是它的名字（同手机设置）。
/// 在哪台运行用各入口同一份菜单（`CueHostMenu`：这台排第一，每台写能当大脑的几家或为什么不能用，"不启用"是停用）；没能写成的原因写在这一行；
/// 能不能选读 `CueGate`：还没和 iCloud 对过时写在等什么、选不了，正在别的 Mac 上运行时改过来先确认。
/// 用哪个 Agent、模型与思考强度在 Cue 页输入框上（`CueConfigControls`），这里不重复。读写都经各入口同一份 `CueSettingsModel`。
struct CueSettingsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()

    /// 名字输入框的宽：不撑满一行。
    private static let fieldWidth: CGFloat = 200

    var body: some View {
        let settings = model.settings ?? .empty
        Section {
            SettingRow(title: "名字", icon: Image(.name)) {
                CueNameField(model: model).labelsHidden().frame(width: Self.fieldWidth)
            }
            host(settings)
        } header: {
            Text(settings.profile.name)
        }
        .cueSettings(model)
    }

    private func host(_ settings: CueSettings) -> some View {
        let hosts = settings.hosts(here: services.hostID)
        let waiting = settings.gate(services).waitingReason
        let running = settings.profile.activeHost
        return SettingRow(
            title: CueSettings.hostTitle, icon: Image(.mac), tone: model.failure == nil ? .calm : .failure,
            busy: model.enabling != nil || waiting != nil, status: (model.failure ?? waiting).map { Dotted($0) }
        ) {
            CueHostMenu(hosts: hosts, running: .init(id: running), accessibilityLabel: CueSettings.hostTitle) { host in
                if host?.id != running { model.choose(host, services) }
            } label: {
                HStack(spacing: 4) {
                    Text(CueSettings.shown(running, in: hosts))
                    Image(.expand).font(.footnote.weight(.semibold))
                }
                .foregroundStyle(palette.ink2)
            }
            .disabled(waiting != nil || model.enabling != nil)
        }
    }
}

#endif
