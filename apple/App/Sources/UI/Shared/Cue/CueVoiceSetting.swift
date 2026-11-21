import CueStore
import SwiftUI

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
