#if os(macOS)
import CueStore
import SwiftUI

/// Mac 的技能与规则页（侧栏底下那一排的那颗，`Route.library`）：读这台 Mac 写下的快照（`Workspace.library`），文件改了它就跟着变。
/// 页里不另起一排：规则｜技能两段在窗口最顶那一排左上（`LibraryPanesSlot`），说明的问号在右上（`LibraryHelpSlot`）；
/// 两段（`LibraryDeck`）各一列居中，一直滚到工具栏后面。这台还没写下快照时（刚升级、第一次扫还没完）只写一句在读。
struct LibraryPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let library = workspace.library {
                LibraryDeck(library: library)
            } else {
                HStack(spacing: 8) {
                    Spinner(.small)
                    Text("正在读这台 Mac 上的技能与规则…")
                }
                .font(Typography.secondary).foregroundStyle(palette.ink3)
                .padding(.top, 120)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .safeAreaPadding(.top, Bars.contentGap)
    }
}
#endif
