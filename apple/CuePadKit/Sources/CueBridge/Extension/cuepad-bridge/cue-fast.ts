// Pi 当 Cue 的大脑、开着加速时由 PiBrain 用 -e 另外加载（桥扩展本身不随大脑加载）。
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { prioritized } from "./fast.ts";

export default function (pi: ExtensionAPI) {
	pi.on("before_provider_request", (event, ctx) => prioritized(event.payload, ctx.model));
}
