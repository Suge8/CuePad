#if os(macOS)
import CueStore
import SwiftUI

struct LibraryPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let library = workspace.library {
                LibraryDeck(library: library)
            } else {
                HStack(spacing: Spacing.item) {
                    Spinner(.small)
                    Text("正在读这台 Mac 上的技能与规则…")
                }
                .font(Typography.secondary).foregroundStyle(palette.ink3)
                .padding(.top, Spacing.vacant)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .safeAreaPadding(.top, Bars.contentGap)
    }
}
#endif
