import CueStore
import Foundation

extension CueTools {
  /// memory 的说明与参数（实现在 `CueTools+Memory`）。
  static var memoryDefinition: [String: Any] {
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
    ]
  }
}
