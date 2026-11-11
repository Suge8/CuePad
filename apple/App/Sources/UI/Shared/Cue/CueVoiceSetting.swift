import CueStore
import SwiftUI

/// 设置里 Cue 那一组的音色：选了就写进 `CueProfile.voice`（经 iCloud 到值班的 Mac，下一通起用它），并放一遍它的样本；左边那颗试听、再点停。
/// 通话占着声音时两样都不放（`VoiceService.canPreview`）。
struct CueVoiceSetting: View {
    let model: CueSettingsModel
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    static var title: LocalizedStringResource { "声音" }

    var body: some View {
        let current = (model.settings ?? .empty).profile.callVoice
        let preview = services.voice.preview
        let label: LocalizedStringResource = preview.playing == nil ? "试听" : "停止试听"
        HStack(spacing: Spacing.tight) {
            Button(label, icon: preview.playing == nil ? .play : .stop) {
                if preview.playing == nil { play(current) } else { preview.stop() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
            .disabled(!services.voice.canPreview)
            MenuButton(sections: [section(current)], accessibilityLabel: Self.title, value: current.name) {
                HStack(spacing: Spacing.tight) {
                    Text(verbatim: current.name).lineLimit(1)
                    Chevron(.expand)
                }
                .foregroundStyle(palette.ink2)
            }
        }
    }

    private func section(_ current: CueVoice) -> ChoiceMenu.Section {
        ChoiceMenu.Section(choices: CueVoice.allCases.map { voice in
            ChoiceMenu.Choice(title: .verbatim(voice.name), checked: voice == current) {
                model.chooseVoice(voice, services)
                play(voice)
            }
        })
    }

    private func play(_ voice: CueVoice) {
        do { try services.voice.playPreview(voice) } catch { model.fail(error) }
    }
}
