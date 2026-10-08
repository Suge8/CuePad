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
         .quota, 429, "额度用完", nil),
        (#"402 {"error":{"message":"Insufficient credits. Add more using https://openrouter.ai/settings/credits","code":402}}"#,
         .quota, 402, "额度用完", "Insufficient credits. Add more using https://openrouter.ai/settings/credits"),
        // 额度类按消息内容识别，不论状态码（Anthropic 用量上限与余额不足都是 400 invalid_request_error）
        (#"400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API usage limits. You will regain access on 2026-11-01 at 00:00 UTC."},"request_id":"req_2"}"#,
         .quota, 400, "额度用完", "You have reached your specified API usage limits. You will regain access on 2026-11-01 at 00:00 UTC."),
        (#"400 {"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}"#,
         .quota, 400, "额度用完", "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."),
        // 挑刺官第 5 轮实际遇到的 Anthropic 订阅额度报错（原文开头与结尾取自记录，中间按 Anthropic 的措辞补全）
        (#"400 {"type":"error","error":{"type":"invalid_request_error","message":"Third-party apps now draw from your extra usage, not your plan limits. Add more at claude.ai/settings/usage and keep going."},"request_id":"req_5"}"#,
         .quota, 400, "额度用完", "Third-party apps now draw from your extra usage, not your plan limits. Add more at claude.ai/settings/usage and keep going."),
        // Pi 自己判为"不可重试的额度上限"的说法（packages/ai/src/utils/retry.ts）
        (#"429 {"type":"error","error":{"type":"GoUsageLimitError","message":"Monthly usage limit reached. Enable available balance usage to continue."}}"#,
         .quota, 429, "额度用完", "Monthly usage limit reached. Enable available balance usage to continue."),
        (#"429 {"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}"#,
         .quota, 429, "额度用完", "You exceeded your current quota, please check your plan and billing details."),
        ("You have hit your ChatGPT usage limit (plus plan). Try again in ~42 min.", .quota, nil, "额度用完", nil),
        (#"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"plus","resets_at":1790000000}}"#,
         .quota, nil, "额度用完", "The usage limit has been reached"),
        (#"OpenAI API error (429): {"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Usage limit reached for your ChatGPT subscription."}}"#,
         .quota, 429, "额度用完", "Usage limit reached for your ChatGPT subscription."),
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

    @Test func lineAddsTheProviderMessageWhenThereIsOne() {
        #expect(PiErrorSummary(#"401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#).line
            == "认证失败，检查 API 密钥或重新登录（401）：invalid x-api-key")
        #expect(PiErrorSummary("fetch failed").line == "网络连接中断")
    }
}
#endif
