import Foundation

/// 离开时没能写进库的正文（`Workspace.unsavedBodies`）：`base` 是当时库里这条的修改时刻。
/// 再打开时库里的修改时刻晚于它，说明这条在别处被改过，旧字不能盖过去（`CardEditing`）。
struct UnsavedBody {
    let text: String
    let base: Date?
}
