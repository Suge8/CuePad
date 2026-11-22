import CueStore
import CueText
import Foundation

extension CueTools {
  static func definitions(_ toolset: Toolset) -> [[String: Any]] {
    catalog(toolset).map { tool in tool.definition().merging(["name": tool.name]) { $1 } }
  }

  static var mergeDefinition: [String: Any] {
    [
      "description": "把一块待合并的记忆写成一行摘要（≤\(CueMemoryLine.maxBytes) 字节）：range 原样复制块头的引用，绑定生成时输入；输入变化则拒绝写入；回执若带 <merge>，继续合并其中新就绪的父块。",
      "inputSchema": schema(["range": string, "text": string], required: ["range", "text"]),
      "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
    ]
  }

  static var saidDefinition: [String: Any] {
    [
      "description": "按词找他以前在各会话里说过的话（带会话名与时刻）：词之间空格隔开，命中任一个就算，词越少见越靠前。",
      "inputSchema": schema(["query": string], required: ["query"]),
      "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
    ]
  }

  static var keepDefinition: [String: Any] {
    [
      "description": "把他在各会话里反复交代的一条做法记成重点，并告诉他。text 是给他看的一句话；rule 是那条做法（一行、≤\(CueTools.ruleLimit) 字）。",
      "inputSchema": schema(["text": string, "rule": string], required: ["text", "rule"]),
      "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
    ]
  }

  static var taskDefinition: [String: Any] {
    [
      "description": """
        任务与会话。task 写任务的 id 前缀或标题，session 写会话的 id 前缀或会话名；写任务的也认，指它在做的会话（done 除外）。body、text 里原样写的 cuepad://file 引用作为图片与文件交给会话。
        add{title,project?,steps?,body?,session?,start?}：建任务。他这一轮的原话由 CuePad 原样放在正文最前面，body 是你补的、接在后面并标明是你补的；正文开工时连同标题作为会话的第一句（子任务开新会话时先带上顶层任务的标题与正文；子任务自己的话用 edit 写在子任务上）。同一项目里已有同名没做完的任务时返回那件、不另建。带 session 是把那个会话绑到新任务上：不写 body（话用 say 说），project 缺省是会话所在的项目。start:true 建好就开工，同 start（可带 agent、model、effort）；
        edit{task,title?,body?,steps?,project?,reopen?}：改标题、换掉正文（写 \(cleared) 清掉）、追加子任务、连同子任务挪到项目；追加子任务与 reopen:true 都让已完成的任务回到没做完；
        start{task,agent?,model?,effort?,fresh?}：开工叶子（有子任务时是第一个没做完的子任务）。同一任务的上一步有会话就接着用（已结束的先恢复），否则在项目文件夹开新会话：agent 缺省是那台 Mac 的默认，model 写 provider/id（claude、codex 只写 id）。叶子已有会话用 say；fresh:true 开新会话（上一步的会话随之结束）；
        bind{task,session}：把已有叶子任务关联到已有会话；unbind{task}：解除关联。只改变关联，不发送正文、不启动或结束会话；task 写叶子任务，session 写会话 id 或会话名；
        say{task|session,text,model?,effort?}：对会话说话（给 task 是它在做的叶子的会话；结束了的先恢复）。会话在等回答时 text 就是答案（选项原文、从 1 起的序号或 是/否；允许自己写的题才收别的话）；会话在跑时打断这一轮、以这句开新一轮，他发起的那一轮在跑时不能说（报错；那一轮停下归他，不叫醒你）。带 model、effort 先给会话换上；
        say 与接着用上一步会话的 start 至多等 \(Int(Speech.cueWait)) 秒，结果写明送没送到；
        peek{task?|session?}：只读。都不带：所有没做完的事、不归没做完的事的活会话，和最近完成的几件（各带会话）。带 task：叶子、正文、近况、最近几轮问答（"他"是用户，"你"是你）与最新回答（超 \(latestReplyLimit) 字截掉中间）、这一轮没答完时最后说的、发到手机的文件（带本机路径）。带 session：那个会话；
        stop{task|session}：停下会话这一轮；
        leave{task|session}：把停着的那一轮（歇下、等回答、出错或被打断）留给他回：进等你，空闲、出错、被打断的显示"新回复"；他或你再对它说话就作废；
        take{task|session}：收回留给他回的，出了等你；要推进直接 say，不用先收回；
        tier{task|session,tier}：换会话的档位：yours 他自己来，push 你推进，full 你全权；
        done{task|session,evidence?,show?}：做完。顶层任务要 evidence：1–\(evidenceCount) 条结论，每条宽不过 \(evidenceLimit)（约 20 个汉字，如"\(evidenceExample)"），CuePad 把标题与证据拼成结果告诉他。show 是结果上挂的图，至多 \(CueShot.limit) 张，按要他看的先后：file 写 peek 里"发到手机的"那一份的 id，look 写这张看什么（一行、≤\(CueShot.lookLimit) 字）；不带就不挂图。下一步还用它的会话就留着，否则结束会话（结束的照样能 say）；已完成的再 done 只结束没人再用的会话，不要 evidence、show。给 session 是收掉那个会话：没做完的事在用、或有话正送进去的不收。
        """,
      "inputSchema": schema(
        [
          "action": ["type": "string", "enum": TaskAction.allCases.map(\.rawValue)],
          "task": string, "session": string, "title": name, "project": string, "steps": ["type": "array", "items": name], "body": string,
          "agent": ["type": "string", "enum": AgentKind.allCases.map(\.rawValue)], "model": ["type": "string", "description": "provider/id"],
          "effort": ["type": "string", "enum": ThinkingLevel.allCases.map(\.rawValue)], "text": string,
          "evidence": ["type": "array", "items": ["type": "string", "description": "宽不过 \(evidenceLimit)"], "maxItems": evidenceCount],
          "show": show, "fresh": ["type": "boolean"], "reopen": ["type": "boolean"], "start": ["type": "boolean"],
          "tier": ["type": "string", "enum": CueTier.allCases.map(\.rawValue)],
        ], required: ["action"]),
      "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false],
    ]
  }

  static var tellDefinition: [String: Any] {
    [
      "description": "对他说一句（Cue 页里你的一行）。tell{text,urgent?,task?}，没有 action。urgent 推送到手机；task 关联一个任务。",
      "inputSchema": schema(["text": string, "urgent": ["type": "boolean"], "task": string], required: ["text"]),
      "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
    ]
  }

  static var string: [String: Any] { ["type": "string"] }
  static var show: [String: Any] {
    ["type": "array", "maxItems": CueShot.limit, "items": ["type": "object", "properties": ["file": string, "look": string], "required": ["file", "look"]]]
  }
  static var name: [String: Any] { ["type": "string", "description": "宽不过 \(CueName.limit)（汉字算 2）"] }

  static let evidenceCount = 3
  static let evidenceLimit = 40
  static let evidenceExample = "登录后进到首页"


  static func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
    ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
  }
}
