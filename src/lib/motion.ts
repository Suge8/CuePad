import { backOut, cubicOut } from 'svelte/easing';
import {
	fade,
	fly,
	scale,
	type FadeParams,
	type FlyParams,
	type ScaleParams,
	type TransitionConfig
} from 'svelte/transition';

/** CSS 侧对应 layout.css 的 --duration-* / --ease-*，两侧数值保持一致。 */
export const DURATION = {
	fast: 120,
	base: 180,
	overlay: 220,
	view: 260,
	emphasis: 420,
	press: 80
} as const;

export const EASE = cubicOut;
export const EASE_SPRING = backOut;
const EASE_ENTER_CSS = 'cubic-bezier(0.16, 1, 0.3, 1)';
type MotionOptions = { direction?: 'in' | 'out' | 'both' };

let reducedMotion = false;
if (typeof window !== 'undefined') {
	const query = window.matchMedia('(prefers-reduced-motion: reduce)');
	reducedMotion = query.matches;
	query.addEventListener('change', (event) => (reducedMotion = event.matches));
}
export const prefersReducedMotion = () => reducedMotion;

function fadeOnly(duration = DURATION.fast): TransitionConfig {
	return { duration, css: (progress: number) => `opacity: ${progress}` };
}

function transitionDuration(
	duration: number | undefined,
	options: MotionOptions | undefined
): number {
	return duration ?? (options?.direction === 'out' ? DURATION.fast : DURATION.base);
}

export function motionFade(node: Element, params: FadeParams = {}, options?: MotionOptions) {
	return fade(node, {
		...params,
		duration: transitionDuration(params.duration, options),
		easing: params.easing ?? EASE
	});
}

export function motionFly(node: Element, params: FlyParams = {}, options?: MotionOptions) {
	if (reducedMotion) return fadeOnly();
	return fly(node, {
		...params,
		duration: transitionDuration(params.duration, options),
		easing: params.easing ?? EASE
	});
}

export function motionScale(node: Element, params: ScaleParams = {}, options?: MotionOptions) {
	if (reducedMotion) return fadeOnly();
	return scale(node, {
		...params,
		duration: transitionDuration(params.duration, options),
		easing: params.easing ?? EASE
	});
}

/** Dialog 进场有重量，退场更短更浅；translate 使用独立 CSS 属性时不受 transform 覆盖。
 * 不用 blur 动画：实测（Playwright rAF 采样）整卡 blur(4px) 动画把打开帧率压到 ~25fps。 */
export function motionDialog(node: Element, _params = {}, options?: MotionOptions) {
	void node;
	void _params;
	const exiting = options?.direction === 'out';
	if (reducedMotion) return fadeOnly();
	const duration = exiting ? DURATION.fast : DURATION.view;
	const y = exiting ? 6 : 14;
	const start = exiting ? 0.98 : 0.96;
	return {
		duration,
		easing: EASE,
		css: (progress: number) =>
			`opacity: ${progress}; transform: translateY(${(1 - progress) * y}px) scale(${start + (1 - start) * progress})`
	};
}

export function motionMenu(
	node: Element,
	{ x = 0, y = -6 }: { x?: number; y?: number } = {},
	options?: MotionOptions
) {
	void node;
	const exiting = options?.direction === 'out';
	if (reducedMotion) return fadeOnly();
	const distance = exiting ? 0.65 : 1;
	return {
		duration: exiting ? DURATION.fast : DURATION.base,
		easing: EASE,
		css: (progress: number) =>
			`opacity: ${progress}; transform: translate(${(1 - progress) * x * distance}px, ${(1 - progress) * y * distance}px) scale(${0.97 + 0.03 * progress})`
	};
}

export function motionFlip(duration: number = DURATION.overlay) {
	return { duration: reducedMotion ? 0 : duration, easing: EASE };
}

/** 两态图标常驻同一槽位；WAAPI 与列表 FLIP 分离，快速切换会中断上一轮。 */
export function motionIconSwitch(node: HTMLElement, active: boolean) {
	let current = active;
	let animations: Animation[] = [];

	function play(next: boolean) {
		for (const animation of animations) animation.cancel();
		const shown = node.querySelector<SVGElement>(next ? '.fx-icon-on' : '.fx-icon-off');
		const hidden = node.querySelector<SVGElement>(next ? '.fx-icon-off' : '.fx-icon-on');
		if (!shown || !hidden) return;
		const showFrames: Keyframe[] = reducedMotion
			? [{ opacity: 0 }, { opacity: 1 }]
			: [
					{ opacity: 0, transform: 'scale(0.35) rotate(-10deg)', filter: 'blur(4px)' },
					{ opacity: 1, transform: 'scale(1) rotate(0)', filter: 'blur(0)' }
				];
		const hideFrames: Keyframe[] = reducedMotion
			? [{ opacity: 1 }, { opacity: 0 }]
			: [
					{ opacity: 1, transform: 'scale(1) rotate(0)', filter: 'blur(0)' },
					{ opacity: 0, transform: 'scale(0.55) rotate(8deg)', filter: 'blur(3px)' }
				];
		const options: KeyframeAnimationOptions = {
			duration: reducedMotion ? DURATION.fast : DURATION.base,
			easing: EASE_ENTER_CSS
		};
		animations = [shown.animate(showFrames, options), hidden.animate(hideFrames, options)];
	}

	return {
		update(next: boolean) {
			if (next === current) return;
			current = next;
			play(next);
		},
		destroy() {
			for (const animation of animations) animation.cancel();
		}
	};
}

export const STAGGER_MS = { group: 55, card: 24 } as const;
const STAGGER_CAP = 6;

export function staggerDelay(index: number, step: number): number {
	if (reducedMotion) return 0;
	return Math.min(index, STAGGER_CAP) * step;
}

/** 覆盖层入场全程不透明，避免新卡入列时背景剧变从透明期漏出。 */
export function overlayEnter(node: Element) {
	void node;
	if (reducedMotion) return { duration: 0 };
	return {
		duration: DURATION.overlay,
		easing: EASE,
		css: (progress: number) =>
			`transform: scale(${1.015 - 0.015 * progress}); opacity: 1`
	};
}

/**
 * 展开/收起：高度 + 透明度。高度动画逐帧重排，仅限短列表小面板（任务栈类），
 * 不用于长列表或高频流式更新。
 */
export function motionExpand(node: Element, _params = {}, options?: MotionOptions) {
	void _params;
	if (reducedMotion) return fadeOnly();
	const height = (node as HTMLElement).offsetHeight;
	const exiting = options?.direction === 'out';
	return {
		duration: exiting ? DURATION.base : DURATION.overlay,
		easing: EASE,
		css: (progress: number) =>
			`overflow: hidden; height: ${progress * height}px; opacity: ${Math.min(1, progress * 1.4)}`
	};
}

export function popRise(
	node: Element,
	{ delay = 0, y = 10, duration }: { delay?: number; y?: number; duration?: number } = {},
	options?: MotionOptions
) {
	void node;
	const exiting = options?.direction === 'out';
	if (reducedMotion) return fadeOnly();
	const actualDuration = duration ?? (exiting ? DURATION.fast : DURATION.overlay);
	const distance = exiting ? Math.min(y, 5) : y;
	const start = exiting ? 0.98 : 0.94;
	return {
		delay: exiting ? 0 : delay,
		duration: actualDuration,
		easing: EASE,
		css: (progress: number) =>
			`opacity: ${progress}; transform: translateY(${(1 - progress) * distance}px) scale(${start + (1 - start) * progress})`
	};
}

export const POP_SCALE = { start: 0.97 } as const;
