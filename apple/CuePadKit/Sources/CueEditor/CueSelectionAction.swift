import Foundation

/// 选中文字时编辑菜单里的一项（"发送选中部分""转为任务"等由外部提供）：`perform` 拿到选中部分的存储格式。
public struct CueSelectionAction {
    public var title: String
    public var systemImage: String
    public var perform: @MainActor (String) -> Void

    public init(title: String, systemImage: String, perform: @escaping @MainActor (String) -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.perform = perform
    }
}
