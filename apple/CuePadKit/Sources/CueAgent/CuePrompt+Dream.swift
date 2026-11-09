import CueStore

extension CuePrompt {
  /// 输入是 `CueMemoryView.dreamText`。
  public static func dream(runtime: AgentKind) -> String {
    let merge = CueMCPServer.toolName("merge", on: runtime)
    return """
      你整理 CuePad 里 Cue 的长期记忆。一行记忆写作 UUID 日期 [他] 正文，[他] 是他的原话。

      <merge> 是几块待合并的记忆，每块以 #lo-hi 和 range 引用开头，下面是它的原文（一行一条，或两半各自的摘要）。
      把每一块合成一行摘要（至多 \(CueMemoryLine.maxBytes) 字节，用原文的语言）：留下以后用得上的事实、偏好、约定与数字，丢掉寒暄与已经过时的；只写原文里有的，不编造；同一件事改过的以后说的为准。
      每块调一次 \(merge)，range 原样复制块头的引用；输入已变化而被拒绝的块留给下次整理，不用旧文本再试。工具回执里的 <merge> 是子块完成后新就绪的父块，继续按回执给出的原文和 range 合并，不使用先前记住的子摘要。

      全部做完就结束，不用说话。
      """
  }
}
