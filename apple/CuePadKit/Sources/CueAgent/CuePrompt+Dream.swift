import CueStore
import CueText

extension CuePrompt {
  public static func dream(runtime: AgentKind) -> String {
    func name(_ tool: CueTools.DreamTool) -> String { CueMCPServer.toolName(tool.rawValue, on: runtime) }
    let (merge, said, keep) = (name(.merge), name(.said), name(.keep))
    return """
      你整理 CuePad 里 Cue 的长期记忆。一行记忆写作 UUID 日期 [他] 正文，[他] 是他的原话。

      <merge> 是几块待合并的记忆，每块以 #lo-hi 和 range 引用开头，下面是它的原文（一行一条，或两半各自的摘要）。
      把每一块合成一行摘要（至多 \(CueMemoryLine.maxBytes) 字节，用原文的语言）：留下以后用得上的事实、偏好、约定与数字，丢掉寒暄与已经过时的；只写原文里有的，不编造；同一件事改过的以后说的为准。
      每块调一次 \(merge)，range 原样复制块头的引用；输入已变化而被拒绝的块留给下次整理，不用旧文本再试。工具回执里的 <merge> 是子块完成后新就绪的父块，继续按回执给出的原文和 range 合并，不使用先前记住的子摘要。

      <said> 是他新近在各会话里对 Agent 说的话，按会话分开。找其中管以后每件事的做法、标准（只管手头那一件的要求不算）；<pinned>（已是重点的）里有的跳过。
      剩下的各用 \(said) 查他以前说过没有，同一个意思换几种说法查。连 <said> 里的在内，三个以上的会话里说过，就调一次 \(keep) 记成重点并告诉他：text 一句话，说他在几个会话里说过、引他说得最全的那一遍原话、已记成重点，不要就跟你说一声；rule 写这条做法本身，照他的话；都用他那句话的语言。

      全部做完就结束，不用说话。
      """
  }

  public static func dreamInput(_ view: CueMemoryView, said: [CueRecall.Reply] = []) -> String? {
    var blocks = view.mergeText.map { ["<merge>\n\($0)\n</merge>"] } ?? []
    if !said.isEmpty {
      var lines: [String] = []
      for (session, group) in Dictionary(grouping: said, by: \.message.sessionID).sorted(by: { $0.value[0].message.at < $1.value[0].message.at }) {
        lines.append(group[0].session.map(CueEnvelope.sessionName) ?? "会话（\(session.prefix(8))）")
        lines += group.map { "- \($0.message.at.formatted(CueEnvelope.monthDay)) \(utterance($0.message.text))" }
      }
      blocks.append("<said>\n\(lines.joined(separator: "\n"))\n</said>")
      if !view.pinned.isEmpty { blocks.append("<pinned>\n\(view.pinned.map { "- " + $0.text }.joined(separator: "\n"))\n</pinned>") }
    }
    return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
  }

  static let saidLimit = 600

  private static func utterance(_ text: String) -> String {
    let flat = CueEnvelope.clip(CueFormat.plainText(text), Int.max)
    return flat.count > saidLimit ? "\(flat.prefix(saidLimit / 2))…\(flat.suffix(saidLimit / 2))" : flat
  }
}
