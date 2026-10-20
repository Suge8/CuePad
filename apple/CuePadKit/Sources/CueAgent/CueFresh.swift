import CueStore
import Foundation

/// 原型开关（`CUEPAD_CUE_FRESH=1`）：平时同一个会话里只往后加信封，换新时开新会话、用对话视图（`CueView`）接上，不写交接。
/// 只为同一分支对比两种做法而存在，正式做时删掉它与它分出的旧路径。
public enum CueFresh {
  public static let on = ProcessInfo.processInfo.environment["CUEPAD_CUE_FRESH"] == "1"

  /// 软线：上下文过了它、提示缓存又已过期，下一次醒来就换新——反正整段都要重写缓存，不如换成更短的视图。
  /// 约换新线（`CueContext.renewAt`）的一半：换新后的起点（固定前缀约 1.1 万加视图至多 `CueView.budget`）在它之下，刚换过的不会一闲下来又换
  public static let softLine = 30_000
  /// 提示缓存的时长（两家大脑都开了 1 小时的，见 `ClaudeBrain`、`PiBrain`）
  public static let cacheLifetime: TimeInterval = 3600

  /// 这次醒来要不要先换新：上下文到了换新线，或过了软线且距上一次模型请求已超过缓存时长。`used`、`lastRequest` 是这个会话最近一次请求的。
  public static func renewDue(used: Int?, lastRequest: Date?, now: Date) -> Bool {
    guard let used else { return false }
    if used >= CueContext.renewAt { return true }
    guard used >= softLine, let lastRequest else { return false }
    return now.timeIntervalSince(lastRequest) > cacheLifetime
  }
}
