import CueStore
import CueText
import Foundation

extension CueTools {
  static func definitions(_ toolset: Toolset) -> [[String: Any]] {
    switch toolset {
    case .cue: definitions
    case .dream: [merge]
    }
  }

  private static var merge: [String: Any] {
    [
      "name": "merge",
      "description": "把一块待合并的记忆写成一行摘要（≤\(CueMemoryLine.maxBytes) 字节）：range 原样复制块头的引用，绑定生成时输入；输入变化则拒绝写入；回执若带 <merge>，继续合并其中新就绪的父块。",
      "inputSchema": schema(["range": string, "text": string], required: ["range", "text"]),
      "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
    ]
  }

  private static var definitions: [[String: Any]] {
    [
      ideaDefinition,
      [
        "name": "task",
        "description": """
          任务与会话。task 写任务的 id 前缀或标题，session 写会话的 id 前缀或会话名；写任务的也认，指它在做的会话（done 除外）。body、text 里原样写的 cuepad://file 引用作为图片与文件交给会话。
          add{title,project?,steps?,body?,session?,start?}：建任务。body 是正文，开工时连同标题作为会话的第一句（子任务开新会话时先带上顶层任务的标题与正文；子任务自己的话用 edit 写在子任务上）。同一项目里已有同名没做完的任务时返回那件、不另建。带 session 是把那个会话绑到新任务上：不写 body（话用 say 说），project 缺省是会话所在的项目。start:true 建好就开工，同 start（可带 agent、model、effort）；
          edit{task,title?,body?,steps?,project?,reopen?}：改标题、换掉正文（写 \(cleared) 清掉）、追加子任务、连同子任务挪到项目；追加子任务与 reopen:true 都让已完成的任务回到没做完；
          start{task,agent?,model?,effort?,fresh?}：开工叶子（有子任务时是第一个没做完的子任务）。同一任务的上一步有会话就接着用（已结束的先恢复），否则在项目文件夹开新会话：agent 缺省是那台 Mac 的默认，model 写 provider/id（claude、codex 只写 id）。叶子已有会话用 say；fresh:true 开新会话（上一步的会话随之结束）；
          bind{task,session}：把已有叶子任务关联到已有会话；unbind{task}：解除关联。只改变关联，不发送正文、不启动或结束会话；task 写叶子任务，session 写会话 id 或会话名；
          say{task|session,text,model?,effort?}：对会话说话（给 task 是它在做的叶子的会话；结束了的先恢复）。会话在等回答时 text 就是答案（选项原文、从 1 起的序号或 是/否；允许自己写的题才收别的话）；会话在跑时打断这一轮、以这句开新一轮，他发起的那一轮在跑时不能说（报错，歇下会叫醒你）。带 model、effort 先给会话换上；
          say 与接着用上一步会话的 start 至多等 \(Int(Speech.cueWait)) 秒，结果写明送没送到；
          peek{task?|session?}：只读。都不带：所有没做完的事、不归没做完的事的活会话，和最近完成的几件（各带会话）。带 task：叶子、正文、近况、最近几轮问答（"他"是用户，"你"是你）与最新回答（超 \(latestReplyLimit) 字截掉中间）、这一轮没答完时最后说的、发到手机的文件（带本机路径）。带 session：那个会话；
          stop{task|session}：停下会话这一轮；
          leave{task|session}：把你发起的、停着的那一轮（歇下、等回答或出错）留给他回：歇着、出错的显示"待回复"，等回答的成了他的拍板，都进等你；他或你再对它说话就作废。已 tell 带 ask 问他的不用再 leave；
          take{task|session}：收回留给他回的（待回复，或成了他拍板的等回答），出了等你；要推进直接 say，不用先收回；
          done{task|session,evidence?,show?}：做完。顶层任务要 evidence：1–\(evidenceCount) 条结论，每条宽不过 \(evidenceLimit)（约 20 个汉字，如"\(evidenceExample)"），CuePad 把标题与证据拼成结果告诉他。show 是结果上挂的图，写法同 tell 的 show；不带就不挂图。下一步还用它的会话就留着，否则结束会话（结束的照样能 say）；已完成的再 done 只结束没人再用的会话，不要 evidence、show。给 session 是收掉那个会话：没做完的事在用、或有话正送进去的不收。
          """,
        "inputSchema": schema(
          [
            "action": ["type": "string", "enum": TaskAction.allCases.map(\.rawValue)],
            "task": string, "session": string, "title": name, "project": string, "steps": ["type": "array", "items": name], "body": string,
            "agent": ["type": "string", "enum": AgentKind.allCases.map(\.rawValue)], "model": ["type": "string", "description": "provider/id"],
            "effort": ["type": "string", "enum": PiThinkingLevel.allCases.map(\.rawValue)], "text": string,
            "evidence": ["type": "array", "items": ["type": "string", "description": "宽不过 \(evidenceLimit)"], "maxItems": evidenceCount],
            "show": show, "fresh": ["type": "boolean"], "reopen": ["type": "boolean"], "start": ["type": "boolean"],
          ], required: ["action"]),
        "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false],
      ],
      [
        "name": "tell",
        "description": """
          对他说一句（Cue 页里你的一行）。tell{text?,ask?,doing?,rule?,show?,urgent?,task?,withdraw?,restore?}，没有 action。ask 是请他允许、等他回答（进"等你"），只用于系统提示里先问的那几类。带 ask 必写 doing：一句说清要他定什么，动词开头写清对象，一行、≤\(CueAsking.phraseLimit) 字（如"推送 scheduler 的重连修复"；几个方案里挑时写推荐的那个）；ask=rule 还必写 rule：他那条规矩的原话。
          卡片、摘要与通知只显示"可以<doing>吗？"、rule、show 的图与选项，不显示 text。text 先一句要做的动作，再一句依据和不做会怎样；不写 push、rule 这类分类名。
          show 是回答必须看的图，至多 \(CueShot.limit) 张，按要他看的先后：file 写 peek 里"发到手机的"那一份的 id，look 写这张看什么（一行、≤\(CueShot.lookLimit) 字，如"方案 1：大按钮占满一行"）。几个方案就只放方案、每个一张（不带原样作对比）、同一台设备同一种样子，推荐的在前；不用看图就能答的不带。
          选项由 CuePad 给（如推送：\(CueAsk.push.choices(in: "项目名").joined(separator: " / "))；不带 task 时第二项是"\(CueAsk.push.always ?? "")"；\(CueAsk.allCases.filter { !$0.allowable }.map(\.rawValue).joined(separator: "、")) 只有第一项），他选第二项就照原话记成一条重点记忆。
          urgent 推送到手机；task 关联一个任务（第二项的范围是它的项目）；withdraw 写"等你"里一条的 id，撤回它，可同时带 text 说明；restore 写他在 Cue 页开口收起的那条的 id，放回"等你"。
          """,
        "inputSchema": schema(
          [
            "text": string, "ask": ["type": "string", "enum": CueAsk.allCases.map(\.rawValue)], "doing": string, "rule": string,
            "urgent": ["type": "boolean"], "task": string, "withdraw": string, "restore": string, "show": show,
          ],
          required: []),
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
      ],
      memoryDefinition,
      setupDefinition,
    ]
  }

  static var string: [String: Any] { ["type": "string"] }
  /// 点名要他看的图（tell 的提问与 done 的结果共用）：发到手机的那一份的 id 与看什么。
  static var show: [String: Any] {
    ["type": "array", "maxItems": CueShot.limit, "items": ["type": "object", "properties": ["file": string, "look": string], "required": ["file", "look"]]]
  }
  static var name: [String: Any] { ["type": "string", "description": "宽不过 \(CueName.limit)（汉字算 2）"] }

  /// done 的证据：至多这么多条，每条宽不过 `evidenceLimit`（`CueName.width`）。结果消息由 Store 拼（`CueReport.text`）。
  static let evidenceCount = 3
  static let evidenceLimit = 40
  /// 证据的示例（工具说明与证据超长的报错共用）：一句行为上的结论。
  static let evidenceExample = "登录后进到首页"


  static func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
    ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
  }
}
