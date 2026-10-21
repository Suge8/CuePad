import CueStore
import CueSync
import CueText
import SwiftUI

/// 你的话到哪了（气泡自己画出来）：进了对话、在路上（会话这边的说法，`PiDelivery.Transit`）、已送达（来回用时）、没能送达。
/// 记号在气泡左下角外（`TripMark`）：路上只转圈（发送中、送达中你分不出也不用分，卡住了到点就是没能送达、写着原因），
/// 唤醒已结束的会话比送达多一步（后台起 Agent，手机上还隔着同步往返），带上说法，免得看着像卡住；已送达一架小纸飞机（用时给读屏与 Mac 的悬停说明）；没能送达胭脂叹号，点它是原因全文与重发、移除。
/// 只有没能送达在气泡下面多一行"未送达 · 重发"（`SpeechBubble`），原因不常驻：Mac 写回的原文长短不定，常驻就得折叠。
enum BubbleTrip: Hashable {
    case arrived
    case sending(PiDelivery.Transit)
    case delivered(String?)
    case failed(Undelivered)

    /// 在路上的话（字与图）整块淡一些，还没落进对话；送达那一刻显出实色。淡到字仍够 4.5:1（浅色 5.4、深色 6.0）：没网时它会停很久，要读得清。
    var opacity: CGFloat { if case .sending = self { 0.7 } else { 1 } }
}

/// 没能送达的这一句：原因全文与能做的事（叹号的菜单、气泡下那一行共用）。只按原因与能不能重发比较：动作随每次求值新建，比它们会让记号每次都重画。
struct Undelivered: Hashable {
    let reason: String
    let canResend: Bool
    let resend: () -> Void
    let remove: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.reason == rhs.reason && lhs.canResend == rhs.canResend }
    func hash(into hasher: inout Hasher) {
        hasher.combine(reason)
        hasher.combine(canResend)
    }
}

extension View {
    /// 挂在左边、不占排版（右缘离它 8 点，下沿离它的下沿 `above`，对着最后一行字）：状态一变气泡不重排，对话不跳。
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
                HStack(spacing: 4) {
                    Spinner(.mini)
                    if transit == .waking { Text(PiDelivery.Transit.waking.label).fixedSize() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(transit.label)
            case .delivered(let roundTrip):
                let said = Dotted("已送达", roundTrip)
                Image(.delivered).accessibilityLabel(Text(said))
                    #if os(macOS)
                    .help(said.visible)
                    #endif
            case .failed(let undelivered):
                Menu {
                    Section(undelivered.reason) {
                        Button(MessageMenu.Item.resend.title, icon: MessageMenu.Item.resend.icon, action: undelivered.resend)
                            .disabled(!undelivered.canResend)
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
                // 点按区放大到 44 点，记号本身不变大、不挪位
                .contentShape(.rect.inset(by: -14))
                .accessibilityLabel("没能送达")
                .accessibilityValue(undelivered.reason)
            }
        }
        .font(Typography.caption).foregroundStyle(palette.ink3)
        // 与气泡显出实色同一拍换记号（转圈 → 纸飞机），旧的先淡掉
        .transition(.handOff)
        .id(trip)
    }
}
