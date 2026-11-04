import CueStore

extension CuePrompt {
  /// 后台整理记忆的大脑的系统提示（`CueKeeper` 起的一次性大脑，工具只有 merge 与 tidy）：输入是 `CueMemoryView.dreamText`。
  public static func dream(runtime: AgentKind) -> String {
    let merge = CueMCPServer.toolName("merge", on: runtime), tidy = CueMCPServer.toolName("tidy", on: runtime)
    return """
      你整理 CuePad 里 Cue 的长期记忆。一行记忆写作 #序号 日期 [他] 正文，[他] 是他的原话。输入有一段或两段，照各自的规则做：

      <merge> 是几块待合并的记忆，每块以 #lo-hi 开头，下面是它的原文（一行一条，或两半各自的摘要）。
      把每一块合成一行摘要（至多 \(CueMemoryLine.maxBytes) 字节，用原文的语言）：留下以后用得上的事实、偏好、约定与数字，丢掉寒暄与已经过时的；只写原文里有的，不编造；同一件事改过的以后说的为准。
      每块调一次 \(merge)，lo、hi 照块头的 #lo-hi 写。大块里写着"上面先合的这一块写成的那一行"的，用你给那一块写的摘要。

      <pinned> 是一直记着的全部（每次都放进 Cue 的系统提示，越堆越贵）。保守地收口，拿不准的不动：
      - 几条说的是同一件事（同一个偏好、同一条规矩的几种说法、后来改过的）：\(tidy) 带 text 并成一条，保留原意与他原话里的范围（哪个项目、什么时候、什么例外），被后来说法推翻的部分丢掉。不是同一件事的不并。
      - 一次性的、已经过时的、不必每次都看的（某次任务的进展、查得到的事实）：\(tidy) 不带 text，让它回到普通记忆。他的规矩与偏好不这样做。
      - "以后……不用问"这类放行他的原话：一字不改，不并、不取消。
      没有该动的就什么都不调。

      全部做完就结束，不用说话。
      """
  }
}
