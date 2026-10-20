import Foundation

/// 原型开关（`CUEPAD_CUE_FRESH=1`）：Cue 每次醒来开新会话，输入是对话视图（`CueView`）加信封，不再换新。
/// 只为同一分支对比两种做法而存在，正式做时删掉它与它分出的旧路径。
public enum CueFresh {
  public static let on = ProcessInfo.processInfo.environment["CUEPAD_CUE_FRESH"] == "1"
}
