import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 选中文字时编辑菜单里的一项（"发送选中部分""转为任务"等由外部提供）：图由 App 给（App 的图标只在它自己那里定），
/// `perform` 拿到选中部分的存储格式。
public struct CueSelectionAction {
    #if canImport(UIKit)
    public typealias PlatformImage = UIImage
    #else
    public typealias PlatformImage = NSImage
    #endif

    public var title: String
    public var image: PlatformImage?
    public var perform: @MainActor (String) -> Void

    public init(title: String, image: PlatformImage?, perform: @escaping @MainActor (String) -> Void) {
        self.title = title
        self.image = image
        self.perform = perform
    }
}
