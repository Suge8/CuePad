import CueStore

extension CueStoreError {
  static let choicesListed = 20

  var cueAdvice: String? {
    switch self {
    case .noSession: "先 \(TaskAction.start.rawValue) 开工，它的正文会作为第一句"
    case .alreadyStarted: "用 \(TaskAction.say.rawValue) 对它说话"
    case .stepsRemaining: "先把它们做完并 \(TaskAction.done.rawValue)（不用做的，evidence 写明为什么不用做）"
    case .agentUnavailable: "\(TaskAction.start.rawValue) 的 agent 换成系统提示里列着的那几家"
    case .noAgent: "用 tell 告诉用户"
    case .unknownModel(_, _, let choices):
      choices.count <= Self.choicesListed ? "能选的是 \(choices.joined(separator: "、"))，照抄其一" : "用 setup look agents 看能选的，照抄其一"
    case .cannotChangeModel: "用 \(TaskAction.start.rawValue) 带 fresh:true 和 model 开新会话"
    case .cannotSpeakNow: "这一轮停下也归他，不会叫醒你；要他知道的 tell 他"
    case .macOffline: "别重试，等它开机；急的用 tell 告诉他"
    case .sessionUnconfirmed: "等它报了再说；要看它最后在做什么用 task \(TaskAction.peek.rawValue)"
    case .turnSourceUnconfirmed: "等它歇下（会叫醒你）再说"
    case .sessionInUse: "那件事做完时 \(TaskAction.done.rawValue) 那件事"
    case .notStopped: "留给他回只用在它空闲、在等回答、出错或被打断时"
    case .questionIsHis: "\(TaskAction.leave.rawValue) 留给他；他明说交给你全权，先 \(TaskAction.tier.rawValue) 换成 full 再答"
    case .cueNotEnabled: "不能派活：等用户在 CuePad 里重新启用"
    case .shots: "show 只挑回答问题必须看的、证明结论的最终成果"
    case .shotMissing: "照 task \(TaskAction.peek.rawValue) 里列的 id 写"
    default: nil
    }
  }
}
