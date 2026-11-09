import Foundation

public enum AttachmentName {
    /// 系统临时副本的显示名：分享方给的名字缺少该文件扩展名时补齐；不改用户提供的大小写。
    public static func suggested(_ name: String?, for file: URL) -> String {
        guard let name else { return file.lastPathComponent }
        let ext = file.pathExtension
        return ext.isEmpty || name.lowercased().hasSuffix("." + ext.lowercased()) ? name : name + "." + ext
    }
}
