import CueStore
import CueText
import Foundation

extension CueTools {
  /// 给这一组用的工具（`Toolset`）。
  static func definitions(_ toolset: Toolset) -> [[String: Any]] {
    switch toolset {
    case .cue: definitions
    case .dream: [merge]
    }
  }

  private static var merge: [String: Any] {
    [
      "name": "merge",
      "description": "把一块待合并的记忆写成一行摘要（≤\(CueMemoryLine.maxBytes) 字节）：lo、hi 照块头的 #lo-hi 写（hi 含在内）。",
      "inputSchema": schema(["lo": ["type": "integer"], "hi": ["type": "integer"], "text": string], required: ["lo", "hi", "text"]),
      "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
    ]
  }

  private static var definitions: [[String: Any]] {
    [
      [
        "name": "task",
        "description": """
          任务与会话。task 写任务的 id 前缀或标题，session 写会话的 id 前缀或会话名（信封与 peek 里有），写任务的也认、指它在做的会话（done 除外）。body、text 里原样写的 ![](cuepad://file/<key>) 与 [文件名](cuepad://file/<key>) 作为图片与文件交给会话。
          add{title,project?,steps?,body?,session?}：建任务。body 是正文，开工时连同标题作为会话的第一句（子任务开新会话时先带上顶层任务的标题与正文）；子任务自己的话用 edit 写在子任务上。同一项目里已有同名没做完的任务时不另建，返回那件。带 session 把那个会话绑到新任务上：不写 body（话用 say 说），project 缺省是会话所在的项目；
          edit{task,title?,body?,steps?,project?,reopen?}：改标题、换掉正文、追加子任务、连同子任务挪到项目；追加子任务与 reopen:true 都让已完成的任务回到没做完；
          start{task,agent?,model?,effort?,fresh?}：开工叶子（task 有子任务时是第一个没做完的子任务）。同一任务的上一步有会话就接着用它（已结束的先恢复），否则在项目文件夹开新会话：agent 缺省是那台 Mac 的默认，model 写 provider/id（claude、codex 只写 id）。叶子已有会话用 say；fresh:true 开新会话（上一步的会话随之结束）；
          say{task|session,text,model?,effort?}：对会话说话（给 task 是它在做的叶子的会话；结束了的先恢复）。会话在等回答时 text 就是答案（选项原文、从 1 起的序号或 是/否；允许自己写的题才收别的话）；否则会话在跑时打断这一轮、以这句开新一轮，他发起的那一轮在跑时不说（报错，歇下会叫醒你）。带 model、effort 先给会话换上；
          say 与接着用上一步会话的 start 等送达结果至多 \(Int(Speech.cueWait)) 秒：已送达、没送到（出错，带原因），或还没结果（之后没送到会作为 [发送失败] 叫醒你）；
          peek{task?|session?}：只读。都不带：所有没做完的事、不归没做完的事的活会话，和最近完成的几件（各带会话）。带 task：叶子、正文、近况、最近几轮问答（"他"是用户，"你"是你）与最新回答全文、发到手机的文件（带本机路径）。带 session：那个会话；
          stop{task|session}：停下会话这一轮；
          leave{task|session}：你发起的那一轮停着（歇下、等回答或出错）、这次该他接手时用，把它留给他回：歇着、出错的显示"待回复"，等回答的成了他的拍板，都进等你；你已 tell 带 ask 问他的不再 leave；他或你再对它说话就作废。他发起的一轮停下 CuePad 已当场留给他，不用 leave；
          take{task|session}：收回留给他回的（待回复，或成了他拍板的等回答），出了等你：只是应他一声、他不用回时用；要推进直接 say，不用先收回；
          done{task|session,evidence?,show?}：做完。顶层任务要 evidence：1–\(evidenceCount) 条结论，每条宽不过 \(evidenceLimit)（约 20 个汉字，如"\(evidenceExample)"），CuePad 把标题与证据拼成结果告诉用户。show 是结果上挂的图，写法同 tell 的 show（如 look 写"最终版：分组标题"）；不带就不挂图，没点名的仍在会话里。下一步还用它的会话就留着，否则结束会话（结束的照样能 say）；已完成的再 done 只结束没人再用的会话，不要 evidence、show。给 session 是收掉那个会话：没做完的事在用、或有话正送进去的不收。
          """,
        "inputSchema": schema(
          [
            "action": ["type": "string", "enum": ["add", "edit", "start", "say", "peek", "stop", "leave", "take", "done"]],
            "task": string, "session": string, "title": name, "project": string, "steps": ["type": "array", "items": name], "body": string,
            "agent": ["type": "string", "enum": AgentKind.allCases.map(\.rawValue)], "model": ["type": "string", "description": "provider/id"],
            "effort": ["type": "string", "enum": PiThinkingLevel.allCases.map(\.rawValue)], "text": string,
            "evidence": ["type": "array", "items": ["type": "string", "description": "宽不过 \(evidenceLimit)"], "maxItems": evidenceCount],
            "show": show, "fresh": ["type": "boolean"], "reopen": ["type": "boolean"],
          ], required: ["action"]),
        "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false],
      ],
      [
        "name": "tell",
        "description": """
          对用户说一句（Cue 页里你的一行）。ask 是请他允许、等他回答（进"等你"），只能是这几类：\(CuePrompt.asks)。
          带 ask 必写 doing：一句说清要他定什么，动词开头写清对象，一行、≤\(CueAsking.phraseLimit) 字（如"推送 scheduler 的重连修复"；几个方案里挑时写你推荐的那个，如"按方案 1 决定单改提问卡"）；ask=rule 还必写 rule：依据他的哪条规矩，照他的原话（如"改数据库结构前先问我"）。
          卡片、摘要与通知只显示"可以<doing>吗？"、rule 那类的这条规矩、show 的图与选项，不显示 text。
          show 是回答这个问题必须看的图，至多 \(CueShot.limit) 张，按要他看的先后：file 写 task peek 里"发到手机的"那一份的 id，look 写这张看什么（一行、≤\(CueShot.lookLimit) 字，如"方案 1：大按钮占满一行"）。几个方案就只放方案、每个一张（不带原样作对比）、同一台设备同一种样子，推荐的在前；不用看图就能答的不带。只有 show 里的图上卡片。
          text 先一句要做的动作，再一句依据（rule 那类写哪条规矩）和不做会怎样；不写 push、rule 这类分类名。
          选项由 CuePad 给（如推送：\(CueAsk.push.choices(in: "项目名").joined(separator: " / "))；不带 task 时第二项是"\(CueAsk.push.always ?? "")"；\(CueAsk.allCases.filter { !$0.allowable }.map(\.rawValue).joined(separator: "、")) 只有第一项），他选第二项就照原话记成一条一直记着的记忆。
          urgent 推送到手机；task 关联一个任务（第二项的范围是它的项目）；withdraw 写"等你"里一条的 id，撤回它（你不用再问了），可同时带 text 说明；restore 写他在 Cue 页开口收起的那条的 id，放回"等你"。
          """,
        "inputSchema": schema(
          [
            "text": string, "ask": ["type": "string", "enum": CueAsk.allCases.map(\.rawValue)], "doing": string, "rule": string,
            "urgent": ["type": "boolean"], "task": string, "withdraw": string, "restore": string, "show": show,
          ],
          required: []),
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
      ],
      [
        "name": "memory",
        "description": """
          你的长期记忆，一行一条（≤\(CueMemoryLine.maxBytes) 字节），序号就是身份。note{text,pin?,his?} 记一条，pin 一直记着（不 pin 的旧行会被并成摘要），his 是照他的原话记的；text 只写事情本身，不写日期时刻，不写"他说""他问"这类前缀（记下的日期与是不是他的原话另存，记忆里看得到）；
          recall{query} 只读：全文找记忆、对话、任务，与你管过的会话里 Agent 的回复原话（带会话名与短 id，可接着 peek）；词之间空格隔开，命中任一个就算，命中的词越少见、越多越靠前（太常见的词不算），列不下的报条数；
          zoom{lo,hi?} 只读：展开记忆视图里的摘要 #lo-hi，给它的两半（摘要或原行）；只给 lo 是那一行；
          forget{line}；pin{line,pinned}；
          remind{text,at,repeat?,task?} 定时，到点叫醒你：at 是第一次（ISO 8601 或 yyyy-MM-dd HH:mm）；repeat 是重复，照 RRULE 写（FREQ=DAILY、FREQ=WEEKLY;BYDAY=MO,TH、FREQ=MONTHLY;BYMONTHDAY=1，时刻取 at 的），不带只这一次；task 写没完成的任务，到点你开工它。不再定时就 forget 那一条；任务完成、归档或进回收站时它上面的定时自动不再定时。
          """,
        "inputSchema": schema(
          [
            "action": ["type": "string", "enum": ["note", "recall", "zoom", "forget", "pin", "remind"]],
            "text": string, "pin": ["type": "boolean"], "his": ["type": "boolean"], "query": string, "line": ["type": ["string", "integer"]],
            "pinned": ["type": "boolean"], "at": string, "repeat": string, "task": string, "lo": ["type": "integer"], "hi": ["type": "integer"],
          ], required: ["action"]),
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
      ],
    ]
  }

  private static var string: [String: Any] { ["type": "string"] }
  /// 点名要他看的图（tell 的提问与 done 的结果共用）：发到手机的那一份的 id 与看什么。
  private static var show: [String: Any] {
    ["type": "array", "maxItems": CueShot.limit, "items": ["type": "object", "properties": ["file": string, "look": string], "required": ["file", "look"]]]
  }
  private static var name: [String: Any] { ["type": "string", "description": "宽不过 \(CueName.limit)（汉字算 2）"] }

  /// done 的证据：至多这么多条，每条宽不过 `evidenceLimit`（`CueName.width`）。结果消息由 Store 拼（`CueReport.text`）。
  static let evidenceCount = 3
  static let evidenceLimit = 40
  /// 证据的示例（工具说明与证据超长的报错共用）：一句行为上的结论。
  static let evidenceExample = "登录后进到首页"


  private static func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
    ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
  }
}
