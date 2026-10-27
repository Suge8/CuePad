#if DEBUG
import Foundation

extension Task where Success == Never, Failure == Never {
    /// 调试驱动里的等待。`Task.sleep` 只在任务被取消时抛：那是驱动该收场了，等待提前结束并返回 false；
    /// 要停的循环写 `guard await Task.wait(for:) else { return }`，其余不在乎取消的直接忽略结果。
    @discardableResult
    static func wait(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }
}
#endif
