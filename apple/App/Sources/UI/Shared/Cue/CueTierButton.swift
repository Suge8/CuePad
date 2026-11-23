import CueStore
import SwiftUI

/// 会话页头尾巴上的小人：这个会话交给 Cue 到哪一档，点开换档。
struct CueTierButton: View {
    let sessionID: String
    let tier: CueTier
    /// 手机页头的玻璃圆钮里只放小人，档靠底色认。
    var compact = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let name = workspace.cue.name
        MenuButton(
            sections: [ChoiceMenu.Section(choices: CueTier.allCases.map { option in
                ChoiceMenu.Choice(title: option.title(name), subtitle: option.detail, checked: option == tier) {
                    workspace.perform { [sessionID] in try await $0.setTier(option, of: sessionID) }
                }
            })],
            press: compact ? .inline : .control, accessibilityLabel: "交给 \(name)", value: String(localized: tier.title(name))
        ) {
            label(name)
        }
        .animation(Motion.fade, value: tier)
    }

    private func label(_ name: String) -> some View {
        HStack(spacing: Spacing.tight) {
            CueAvatar(.resting, size: .inline, plate: false).saturation(tier == .yours ? 0 : 1)
            if tier != .yours, !compact {
                Text(tier.title(name)).font(Typography.caption.weight(.semibold)).lineLimit(1).fixedSize()
                    .transition(.opacity)
            }
        }
        .foregroundStyle(tier == .full ? palette.onFill : palette.signature)
        .padding(.leading, Spacing.tight)
        .padding(.trailing, tier == .yours || compact ? Spacing.tight : Spacing.item)
        .padding(.vertical, Spacing.tight)
        .background(fill, in: .capsule)
    }

    private var fill: Color {
        switch tier {
        case .yours: .clear
        case .push: palette.signatureWash
        case .full: palette.signatureFill
        }
    }
}

extension CueTier {
    func title(_ name: String) -> LocalizedStringResource {
        switch self {
        case .yours: "自己来"
        case .push: "\(name) 推进"
        case .full: "\(name) 全权"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .yours: "留给你"
        case .push: "不做判断，帮你推进"
        case .full: "按你的习惯判断，直到做完"
        }
    }
}
