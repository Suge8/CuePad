/// 卡片记录里的旧字段 `numbering` 的取值（同步记录里还有，界面不再用；读到什么原样写回）。
public enum CueNumbering: String, Sendable, CaseIterable {
    case none, decimal, alpha, cjk
}
