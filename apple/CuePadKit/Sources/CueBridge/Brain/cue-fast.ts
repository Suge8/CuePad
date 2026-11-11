import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { supportsFast } from "./Extension/cuepad-bridge/fast.ts";

export default function (pi: ExtensionAPI) {
	pi.on("before_provider_request", (event, ctx) => {
		if (!supportsFast(ctx.model)) return;
		if (!event.payload || typeof event.payload !== "object" || Array.isArray(event.payload)) return;
		return { ...event.payload, service_tier: "priority" };
	});
}
