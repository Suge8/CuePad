#if os(macOS)
import Testing
@testable import CuePi

/// Pi 上报的模型调用错误是一段原文（常见是"状态码 + 提供方 JSON"）。界面要一句人话，原文留着悬停看。
/// 样本取自各提供方 SDK 经 Pi 格式化后的真实报错。
struct PiErrorSummaryTests {
    @Test(arguments: [
        (#"400 {"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0.image.source.base64: image exceeds 5 MB maximum"},"request_id":"req_011CXyz"}"#,
         PiErrorSummary.Kind.rejected, 400, "模型拒绝了请求（400）", "messages.1.content.0.image.source.base64: image exceeds 5 MB maximum"),
        (#"401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_1"}"#,
         .authentication, 401, "认证失败，检查 API 密钥或重新登录（401）", "invalid x-api-key"),
        ("429 You exceeded your current quota, please check your plan and billing details. For more information on this error, read the docs: https://platform.openai.com/docs/guides/error-codes/api-errors.",
         .quota, 429, "额度不足", nil),
        (#"402 {"error":{"message":"Insufficient credits. Add more using https://openrouter.ai/settings/credits","code":402}}"#,
         .quota, 402, "额度不足", "Insufficient credits. Add more using https://openrouter.ai/settings/credits"),
        (#"429 {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed the rate limit for your organization of 50 requests per minute."}}"#,
         .rateLimited, 429, "请求太频繁，稍后再试", "This request would exceed the rate limit for your organization of 50 requests per minute."),
        (#"529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
         .server, 529, "模型服务繁忙或出错，稍后再试（529）", "Overloaded"),
        (#"500: {"error":{"message":"Internal Server Error","code":500}}"#,
         .server, 500, "模型服务繁忙或出错，稍后再试（500）", "Internal Server Error"),
        ("Connection error.", .network, nil, "网络连接中断", nil),
        ("getaddrinfo ENOTFOUND api.anthropic.com", .network, nil, "网络连接中断", nil),
        (#"418 {"type":"error","error":{"type":"teapot","message":"short and stout"}}"#,
         .other, 418, "模型调用出错（418）", "short and stout"),
        ("Model returned no content\n    at stream (index.js:1:1)", .other, nil, "Model returned no content", nil),
    ] as [(String, PiErrorSummary.Kind, Int?, String, String?)])
    func summarizesRealProviderErrors(raw: String, kind: PiErrorSummary.Kind, status: Int?, title: String, message: String?) {
        let summary = PiErrorSummary(raw)
        #expect(summary.kind == kind)
        #expect(summary.status == status)
        #expect(summary.title == title)
        #expect(summary.providerMessage == message)
        #expect(summary.raw == raw)  // 原文保留，供悬停显示
    }

    @Test func agentStateExposesTheSummaryOnlyForErrors() {
        #expect(PiAgentState.error(message: "fetch failed").errorSummary?.kind == .network)
        #expect(PiAgentState.thinking.errorSummary == nil)
    }
}
#endif
