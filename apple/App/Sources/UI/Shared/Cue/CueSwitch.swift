import CueStore
import SwiftUI

/// 两端设置里 Cue 那一组的第一行（`CueSettingsSection`）：头像、名字（就地改，`CueNameField`）、开关（`CueSwitch`）。组名不另写，这一行就是它。
/// 头像跟着开关醒着或睡着（`CueBeat.resting`、`.away`），按下开的那一刻到写成之间是在听的那一拍（带在动的点）：不另放转圈，
/// 关着时这一行不写别的——停用是平常的一态，不是出错。名字下面那一行只在有话要说时出：没写成的原因（胭脂）、为什么此刻开不了（`blocked`）；
/// 有没有那一行都不改这一行的高（按头像与两行字里高的那个定）。
struct CueSwitchRow: View {
    let model: CueSettingsModel
    /// 这台 Mac（手机为 nil）。
    let here: String?
    /// 此刻开不了的原因（还没和 iCloud 对过、手机上还没有哪台 Mac）：开关停用，原因写在名字下面。开着时照样能关。
    let blocked: String?
    @Environment(\.palette) private var palette

    var body: some View {
        let note = model.failure ?? (model.isOn ? nil : blocked)
        HStack(spacing: 12) {
            CueAvatar(beat, size: .row)
            VStack(alignment: .leading, spacing: 2) {
                CueNameField(model: model)
                    .font(Typography.bodyStrong)
                    .labelsHidden()
                if let note {
                    Text(note).font(Typography.meta).foregroundStyle(model.failure == nil ? palette.ink3 : palette.failure)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
            CueSwitch(model: model, here: here)
                .disabled(!model.isOn && blocked != nil)
        }
        .animation(Motion.fade, value: note)
    }

    private var beat: CueBeat {
        if model.turning == true || model.enabling != nil { return .hearing }
        return model.isOn ? .resting : .away
    }

    /// 这一行的高：头像与名字、原因两行字都放得下，原因出没不挤动这一组。
    private static var height: CGFloat { 36 }
}

/// Cue 的开关本身（设置里那一行、手机 Cue 面板），读写各入口同一份 `CueSettingsModel.turn`。
struct CueSwitch: View {
    let model: CueSettingsModel
    let here: String?
    @Environment(AppServices.self) private var services

    var body: some View {
        let name = (model.settings ?? .empty).profile.name
        Toggle(isOn: Binding(get: { model.isOn }, set: { model.turn($0, here: here, services) })) {
            Text("启用 \(name)")
        }
        .labelsHidden()
        .toggleStyle(.switch)
    }
}

#if os(macOS)
extension Workspace {
    /// Mac Cue 页"⋯"里的开关：经各处同一个 `AppServices.turnCue`，没写成的原因弹提示。
    /// 回到这台而这台一家 Agent 都没接上时打开接入面板（`SetupPanel`：给装法，接上的同一下启用），同 Cue 页的启用钮。
    func turnCue(_ on: Bool) {
        attempt { [self] in
            do {
                try await services.turnCue(on, here: localHost)
            } catch CueEnableError.noRuntime {
                showsSetup = true
            }
        }
    }
}
#endif
