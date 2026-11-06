import Foundation

extension CueStore {
  /// 这个会话还要不要按第一句话起名（`SessionNameSuggestion`）：任务标题是名字的唯一事实源，正在用它的任务有标题就不起；
  /// 你发过改名（`latestRenames`，不论送没送到）也不起。会话自己有没有名字由 Mac 上的桥看。起名前问一次，写回前再问一次。
  public func wantsSuggestedName(_ sessionID: String) throws -> Bool {
    guard try latestRenames(to: [sessionID]).isEmpty else { return false }
    return try !tasks(boundTo: sessionID).contains { $0.task.piSessionID == sessionID && !$0.task.heading.isEmpty }
  }
}
