import CueStore
import CueText

extension CuePrompt {
  /// 输入是 `dreamInput`。找反复交代的做法不放在 Cue 的轮里：那里只看得到手头这一个会话，查别的会话要占它的一轮与常驻提示。他答了由 Cue 记：重点只归 Cue 写。
  public static func dream(runtime: AgentKind) -> String {
    let merge = CueMCPServer.toolName("merge", on: runtime), said = CueMCPServer.toolName("said", on: runtime)
    let ask = CueMCPServer.toolName("ask", on: runtime)
    return """
      你整理 CuePad 里 Cue 的长期记忆。一行记忆写作 UUID 日期 [他] 正文，[他] 是他的原话。

      <merge> 是几块待合并的记忆，每块以 #lo-hi 和 range 引用开头，下面是它的原文（一行一条，或两半各自的摘要）。
      把每一块合成一行摘要（至多 \(CueMemoryLine.maxBytes) 字节，用原文的语言）：留下以后用得上的事实、偏好、约定与数字，丢掉寒暄与已经过时的；只写原文里有的，不编造；同一件事改过的以后说的为准。
      每块调一次 \(merge)，range 原样复制块头的引用；输入已变化而被拒绝的块留给下次整理，不用旧文本再试。工具回执里的 <merge> 是子块完成后新就绪的父块，继续按回执给出的原文和 range 合并，不使用先前记住的子摘要。

      <said> 是他新近在各会话里对 Agent 说的话，按会话分开。找其中管以后每件事的做法、标准（只管手头那一件的要求不算）；<pinned>（已是重点的）与 <asked>（问过他的）里有的跳过。
      剩下的各用 \(said) 查他以前说过没有，同一个意思换几种说法查。连 <said> 里的在内，三个以上的会话里说过，就调一次 \(ask) 问他要不要记成重点：text 一句话，说他在几个会话里说过、引他说得最全的那一遍原话；rule 写原话的要点，doing 写"把它记成重点"；都用他那句话的语言。

      全部做完就结束，不用说话。
      """
  }

  /// 交给它的输入：待合并的块（`CueMemoryView.mergeText`），与他在会话里新说的一批话（`said`，没有就不带后面三块）、
  /// 已是重点的、问过他的（`asked`，`CueStore.cueHabitQuestions`）；都没有为 nil。
  public static func dreamInput(_ view: CueMemoryView, said: [CueRecall.Reply] = [], asked: [CueMessage] = []) -> String? {
    var blocks = view.mergeText.map { ["<merge>\n\($0)\n</merge>"] } ?? []
    if !said.isEmpty {
      var lines: [String] = []
      for (session, group) in Dictionary(grouping: said, by: \.message.sessionID).sorted(by: { $0.value[0].message.at < $1.value[0].message.at }) {
        lines.append(group[0].session.map(CueEnvelope.sessionName) ?? "会话（\(session.prefix(8))）")
        lines += group.map { "- \($0.message.at.formatted(CueEnvelope.monthDay)) \(utterance($0.message.text))" }
      }
      blocks.append("<said>\n\(lines.joined(separator: "\n"))\n</said>")
      for (tag, items) in [("pinned", view.pinned.map(\.text)), ("asked", asked.map { CueEnvelope.clip(CueFormat.plainText($0.text), saidLimit) })] where !items.isEmpty {
        blocks.append("<\(tag)>\n\(items.map { "- " + $0 }.joined(separator: "\n"))\n</\(tag)>")
      }
    }
    return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
  }

  /// 他的一句话最多给这么多字：超了留头尾各一半、截掉中间。交代做法的话多在一段话的开头或结尾，中间多是贴的日志与代码。
  static let saidLimit = 600

  private static func utterance(_ text: String) -> String {
    let flat = CueEnvelope.clip(CueFormat.plainText(text), Int.max)
    return flat.count > saidLimit ? "\(flat.prefix(saidLimit / 2))…\(flat.suffix(saidLimit / 2))" : flat
  }
}
