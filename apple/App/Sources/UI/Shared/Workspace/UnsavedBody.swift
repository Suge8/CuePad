/// 离开时没能写进库的正文（`Workspace.unsavedBodies`）：`base` 是当时库里这条的正文。
/// 再打开时库里的正文已不是它，说明这条的正文在别处被改过，旧字不能盖过去、也不能丢：接在新正文后面（`CardEditing`）。
/// 只比正文：完成、置顶这类别的改动不算。
struct UnsavedBody {
    let text: String
    let base: String?
}
