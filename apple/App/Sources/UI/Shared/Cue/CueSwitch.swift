import CueStore
import SwiftUI

/// 按下开的那一刻到写成之间头像是在听的那一拍（带在动的点），不另放转圈。关着时这一行不写别的：停用是平常的一态，不是出错。
struct CueSwitchRow: View {
    let model: CueSettingsModel
    let here: String?
    let blocked: String?
    @Environment(\.palette) private var palette

    var body: some View {
        let note = model.failure ?? (model.isOn ? nil : blocked)
        HStack(spacing: Spacing.group) {
            CueAvatar(beat, size: .row)
            VStack(alignment: .leading, spacing: Spacing.hair) {
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
