import CueStore

extension CuePrompt {
  /// 后台整理记忆的大脑的系统提示（`CueKeeper` 起的一次性大脑，工具只有 merge）：输入是待合并的块（`CueMemoryView.mergeText`）。
  public static func dream(runtime: AgentKind) -> String {
    """
    你整理 CuePad 里 Cue 的长期记忆。输入是几块待合并的记忆，每块以 #lo-hi 开头，下面是它的原文（#序号 日期 [他] 正文，一行一条，[他] 是他的原话；或两半各自的摘要）。
    把每一块合成一行摘要（至多 \(CueMemoryLine.maxBytes) 字节，用原文的语言）：留下以后用得上的事实、偏好、约定与数字，丢掉寒暄与已经过时的；只写原文里有的，不编造；同一件事改过的以后说的为准。
    每块调一次 \(CueMCPServer.toolName("merge", on: runtime))，lo、hi 照块头的 #lo-hi 写。大块里写着"上面先合的这一块写成的那一行"的，用你给那一块写的摘要。
    全部写完就结束，不用说话。
    """
  }
}
