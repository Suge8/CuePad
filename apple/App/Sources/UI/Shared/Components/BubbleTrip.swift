import CueStore
import SwiftUI

enum BubbleTrip: Hashable {
    case arrived
    case sending(DeliveryShown.Transit)
    case delivered(String?)
    case failed(Undelivered)

    var opacity: CGFloat { if case .sending = self { 0.7 } else { 1 } }
}

struct Undelivered: Hashable {
    let reason: String
    let resend: () -> Void
    let remove: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.reason == rhs.reason }
    func hash(into hasher: inout Hasher) { hasher.combine(reason) }
}

extension View {
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
                    StateGlyph.undelivered
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

