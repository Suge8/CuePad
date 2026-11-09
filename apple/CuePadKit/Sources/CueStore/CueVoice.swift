/// Cue 通话的音色，建通话时会话体里的 `audio.output.voice` 只取自这份清单（`VoiceWire.createCall`）。
/// 服务端（gpt-live-1-codex）收到不认识的音色照样回 201，约 15 秒后通话以媒体失败结束、不给错误原文，所以只给实测过的这几个：
/// 库里读到清单外的值（别的版本写的）原样存着、写回不盖掉（`Open`），用的时候按默认（`CueProfile.callVoice`）。
/// 服务端还接受、这里不列的：bubbie 自带"奶奶"人设，委派会漏并谎称已办；neer 说中文时把 Cue、Mac 读错；breeze 中文咬字最含混（#133）。
public enum CueVoice: String, CaseIterable, Sendable {
  case arbor, arrullo, aube, cove, ember, haetsal, hanul, himari, juniper, leher, maple, miko, porto, rindo, rio, rivage, selva, sol, sonna, spruce, tinta, vale, viola

  public static let `default` = CueVoice.cove

  public var name: String { rawValue.capitalized }
}
