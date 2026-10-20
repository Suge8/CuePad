import CueStore
import Foundation

/// 原型开关（`CUEPAD_CUE_FRESH=1`）：平时同一个会话里只往后加信封，换新时开新会话、用对话视图（`CueView`）接上，不写交接。
/// 只为同一分支对比两种做法而存在，正式做时删掉它与它分出的旧路径。
public enum CueFresh {
  public static let on = ProcessInfo.processInfo.environment["CUEPAD_CUE_FRESH"] == "1"

  /// 这次醒来要不要先换新：上下文到了换新线，或距上一次模型请求已超过缓存时长（`cacheLifetime`，秒）。缓存过期时接着用要把整段原价重写，
  /// 换新只写固定前缀与视图，而换新后的起点就是它们，所以过期时换新从不更贵。`used`、`lastRequest` 是这个会话最近一次请求的。
  public static func renewDue(used: Int?, lastRequest: Date?, now: Date, cacheLifetime: TimeInterval) -> Bool {
    guard let used else { return false }
    if used >= CueContext.renewAt { return true }
    guard let lastRequest else { return false }
    return now.timeIntervalSince(lastRequest) > cacheLifetime
  }
}
