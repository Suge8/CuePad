import CueStore
import SwiftUI

/// 宽屏会话胶囊里的小人：这个会话交给 Cue 到哪一档，点开换档。
struct CueTierButton: View {
    let sessionID: String
    let tier: CueTier
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let name = workspace.cue.name
        MenuButton(sections: tier.choices(of: sessionID, in: workspace), accessibilityLabel: "交给 \(name)", value: String(localized: tier.title(name))) {
            label(name)
        }
        .animation(Motion.fade, value: tier)
    }

    private func label(_ name: String) -> some View {
        HStack(spacing: Spacing.tight) {
            CueAvatar(.resting, size: .inline, plate: false).saturation(tier == .yours ? 0 : 1)
            if tier != .yours {
                Text(tier.title(name)).font(Typography.captionBold).lineLimit(1).fixedSize()
                    .transition(.opacity)
            }
        }
        .foregroundStyle(tier == .full ? palette.onFill : palette.signature)
        .padding(.leading, Spacing.tight)
        .padding(.trailing, tier == .yours ? Spacing.tight : Spacing.item)
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

/// 手机会话页点标题出的菜单里换档的那一项：页头右边只放直接可点的工具，档写在副标题里（`SessionSubtitle`）。
struct CueTierMenu: View {
    let sessionID: String
    let tier: CueTier
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let name = workspace.cue.name
        Menu {
            ChoiceMenuItems(sections: tier.choices(of: sessionID, in: workspace))
        } label: {
            Label("交给 \(name)", icon: .cue)
            Text(tier.title(name))
        }
    }
}

extension CueTier {
    func choices(of sessionID: String, in workspace: Workspace) -> [ChoiceMenu.Section] {
        let name = workspace.cue.name
        return [ChoiceMenu.Section(choices: CueTier.allCases.map { option in
            ChoiceMenu.Choice(title: option.title(name), subtitle: option.detail, checked: option == self) {
                workspace.perform { try await $0.setTier(option, of: sessionID) }
            }
        })]
    }

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
