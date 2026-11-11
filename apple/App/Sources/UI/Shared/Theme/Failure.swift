import SwiftUI

/// "出错"的样子，全 App 只此一份：胭脂（`Palette.failure`）圆叹号（`Icon.failure`），同一个意思一个样子，用户只学一次。与它并列的"等你"见 `Palette.waiting`。
struct FailureMark: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.failure).foregroundStyle(palette.failure).readerHidden(true)
    }
}
