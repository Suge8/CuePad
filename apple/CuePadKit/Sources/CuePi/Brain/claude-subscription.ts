// Pi 当 Cue 的大脑时加载的扩展（PiBrain 带 -ne，Pi 自己发现的扩展都不加载，这份由 CuePad 用 -e 指给它）：
// 用 Claude 订阅（Anthropic OAuth 令牌）时把请求标成 Claude Code 的，归到订阅额度，不扣额外用量。
// 做法同 FireCode 的 provider/claude-sub.ts：请求头 user-agent 用本机 Claude Code 的版本号（Pi 自带的是写死的旧版本），
// 系统提示首块加 billing header（cc_version 与 user-agent 同一个版本）；已有 billing header 的原样通过。
// 只认 OAuth 令牌本身（sk-ant-oat，与 Pi 决定走 OAuth 的判断同一条）：令牌可能来自 auth.json，也可能来自 ANTHROPIC_OAUTH_TOKEN，
// 后者在 Pi 眼里不是 OAuth 登录（isUsingOAuth 为假），只看登录类型会漏掉。API 密钥与别的提供方不动。
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";

const BILLING_PREFIX = "x-anthropic-billing-header:";
const BILLING_SALT = "59cf53e54c78";
// 本机的 Claude Code 由 PiBrain 经 CUEPAD_CLAUDE 给；没装（或跑不起来）时用的版本号
const FALLBACK_VERSION = "2.1.281";

function claudeCodeVersion(): string {
	try {
		const output = execFileSync(process.env.CUEPAD_CLAUDE || "claude", ["--version"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 2000 });
		return output.match(/\b\d+\.\d+\.\d+\b/)?.[0] ?? FALLBACK_VERSION;
	} catch {
		return FALLBACK_VERSION;
	}
}

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((block) => (block?.type === "text" && typeof block.text === "string" ? block.text : "")).join("");
}

function billingHeader(messages: unknown, version: string): string {
	const first = (Array.isArray(messages) ? messages : []).find((message) => message?.role === "user");
	const text = textOf(first?.content);
	const sampled = [4, 7, 20].map((index) => text[index] ?? "0").join("");
	const suffix = createHash("sha256").update(`${BILLING_SALT}${sampled}${version}`).digest("hex").slice(0, 3);
	return `${BILLING_PREFIX} cc_version=${version}.${suffix}; cc_entrypoint=cli; cch=00000;`;
}

export default function (pi: any) {
	// 每个运行时（开新会话会重建）探测一次
	const version = claudeCodeVersion();
	const subscribed = async (ctx: any): Promise<boolean> => {
		const model = ctx.model;
		if (model?.provider !== "anthropic") return false;
		const { apiKey } = await ctx.modelRegistry.getApiKeyAndHeaders(model);
		return typeof apiKey === "string" && apiKey.includes("sk-ant-oat");
	};

	pi.on("before_provider_headers", async (event: any, ctx: any) => {
		if (await subscribed(ctx)) event.headers["user-agent"] = `claude-cli/${version} (external, cli)`;
	});

	pi.on("before_provider_request", async (event: any, ctx: any) => {
		const payload = event.payload;
		if (!payload || typeof payload !== "object" || !(await subscribed(ctx))) return;
		const blocks = Array.isArray(payload.system) ? payload.system : [];
		if (blocks.some((block: any) => typeof block?.text === "string" && block.text.startsWith(BILLING_PREFIX))) return;
		return { ...payload, system: [{ type: "text", text: billingHeader(payload.messages, version) }, ...blocks] };
	});
}
