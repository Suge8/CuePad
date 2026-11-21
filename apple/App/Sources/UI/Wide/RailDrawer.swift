import SwiftUI

struct RailDrawer<Rail: View>: View {
    let open: Bool
    let close: () -> Void
    @ViewBuilder let rail: Rail

    var body: some View {
        ZStack(alignment: .leading) {
            if open { DrawerCatcher(close: close).transition(.identity) }
            rail
                .modifier(DrawerSurface(edge: .leading, ground: \.sidebar))
                .environment(\.pageActive, open)
                .modifier(DrawerSlide(open: open))
                .readerHidden(!open)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
