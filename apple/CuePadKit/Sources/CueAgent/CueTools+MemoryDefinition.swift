import CueStore
import Foundation

extension CueTools {
  static var memoryDefinition: [String: Any] {
    [
        "description": """
          你的长期记忆，一行一条（≤\(CueMemoryLine.maxBytes) 字节），UUID 是身份。text 只写事情本身，不写日期时刻与"他说""他问"这类前缀（日期与是不是他的原话另存，记忆里看得到）。
          note{text,pin?,his?,replaces?}：记一条；pin 标为重点（不 pin 的旧行会被并成摘要），his 是照他的原话记的；replaces 写被它取代的几条的 UUID，同时忘掉它们（不给 pin 时有一条是重点就是重点；不能替换定时）。重点每个班次都在系统提示里、合计限 \(CueMemoryLine.pinnedHard / 1024)KB：改规矩用 replaces 换掉旧的，不追加；超了合并或取消钉不再要的；
          recall{query} 只读：全文找记忆、对话、任务，与你管过的会话里 Agent 的回复原话（带会话名与短 id，可接着 peek）；词之间空格隔开，命中任一个就算，词越少见、命中越多越靠前（太常见的词不算），列不下的报条数；
          zoom{range?|line?} 只读：range 原样复制摘要块头的引用，展开它的两半；line 是单条记忆的完整 UUID；都不给读取当前记忆视图。旧范围失效时重新读取视图；
          forget{line}；pin{line,pinned}；
          remind{text,at,repeat?,task?}：定时，到点叫醒你。text 到点前也在记忆里：日子写日期与星期（11-11 周三），不写今天、明天这类到点前后意思不同的词。at 是第一次（ISO 8601 或 yyyy-MM-dd HH:mm）；repeat 照 RRULE 写（FREQ=DAILY、FREQ=WEEKLY;BYDAY=MO,TH、FREQ=MONTHLY;BYMONTHDAY=1，时刻取 at 的），不带只这一次；task 写没完成的任务，到点你开工它。不再定时就 forget 那一条；任务完成、归档或进回收站时它上面的定时自动不再定时；
          schedules{} 只读：全部定时（UUID、下一次、怎么重复、挂的任务）。
          """,
        "inputSchema": schema(
          [
            "action": ["type": "string", "enum": ["note", "recall", "zoom", "forget", "pin", "remind", "schedules"]],
            "text": string, "pin": ["type": "boolean"], "his": ["type": "boolean"], "replaces": ["type": "array", "items": string],
            "query": string, "line": string,
            "pinned": ["type": "boolean"], "at": string, "repeat": string, "task": string, "range": string,
          ], required: ["action"]),
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
    ]
  }
}
