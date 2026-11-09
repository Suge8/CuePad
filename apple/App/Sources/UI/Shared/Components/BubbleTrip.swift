import CueStore
import SwiftUI

/// 出了这台（已发出、送达中）飞机停下、旁边写着到了哪一步：话 0.4 秒就到服务器，回执要等那台 Mac，看得出不是卡在本机。
/// 唤醒已结束的会话比送达多一步（后台起 Agent，手机上还隔着同步往返），飞着带上说法，免得看着像卡住。
/// 等待到点只显示静态未确认，不提供安全重发。
enum BubbleTrip: Hashable {
    case arrived
    case sending(PiDelivery.Transit)
    case delivered(String?)
    case failed(Undelivered)

    /// 淡到字仍够 4.5:1（浅色 5.4、深色 6.0）：没网时它会停很久，要读得清。
    var opacity: CGFloat { if case .sending = self { 0.7 } else { 1 } }
}

/// 只按原因比较：动作随每次求值新建，比它们会让记号每次都重画。
struct Undelivered: Hashable {
    let reason: String
    let resend: () -> Void
    let remove: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.reason == rhs.reason }
    func hash(into hasher: inout Hasher) { hasher.combine(reason) }
}

extension View {
    /// 不占排版：状态一变气泡不重排，对话不跳。
    func tripMark(_ trip: BubbleTrip, above: CGFloat) -> some View {
        overlay(alignment: .bottomLeading) {
            TripMark(trip: trip).alignmentGuide(.leading) { $0[.trailing] + 8 }.padding(.bottom, above)
        }
    }
}

private struct TripMark: View {
    let trip: BubbleTrip
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch trip {
            case .arrived: EmptyView()
            case .sending(let transit):
                HStack(spacing: Spacing.tight) {
                    OnTheWay(size: 13, color: palette.ink3, landed: transit == .sent || transit == .delivering || transit == .unconfirmed)
                    if transit != .sending { Text(transit.label).fixedSize() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(transit.label)
            case .delivered(let roundTrip):
                let said = Dotted(String(localized: "已送达"), roundTrip)
                Image(.delivered).iconLabel(Text(said))
                    #if os(macOS)
                    .help(said.visible)
                    #endif
            case .failed(let undelivered):
                Menu {
                    Section(undelivered.reason) {
                        Button(MessageMenu.Item.resend.title, icon: MessageMenu.Item.resend.icon, action: undelivered.resend)
                        Button(MessageMenu.Item.remove.title, icon: MessageMenu.Item.remove.icon, role: .destructive, action: undelivered.remove)
                    }
                } label: {
                    PiStateGlyph.undelivered
                }
                .menuStyle(.button).buttonStyle(PressStyle(.inline))
                #if os(macOS)
                .menuIndicator(.hidden)
                #endif
                .fixedSize()
                .contentShape(.rect.inset(by: -14))
                .accessibilityLabel("没能送达")
                .accessibilityValue(undelivered.reason)
            }
        }
        .font(Typography.caption).foregroundStyle(palette.ink3)
        .transition(.handOff)
        .id(trip)
    }
}

