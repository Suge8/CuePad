// 动画记录器：patch Element.prototype.animate（Svelte transition/animate 走 WAAPI），
// 并监听 CSS transitionrun；把目标 class 与属性记入 window.__ANIM_LOG__。
// 断言查事件记录而非实时采样 getAnimations()，避免 120–220ms 窗口的采样竞态。
(() => {
	const log = [];
	window.__ANIM_LOG__ = log;

	const targetName = (element) =>
		typeof element.className === 'string'
			? element.className
			: (element.getAttribute('class') ?? '');
	const record = (element, props) => {
		const entry = { target: targetName(element), props };
		log.push(entry);
		window.dispatchEvent(new CustomEvent('cuepad:animation', { detail: entry }));
	};

	const original = Element.prototype.animate;
	Element.prototype.animate = function (keyframes, options) {
		const frames = Array.isArray(keyframes) ? keyframes : keyframes ? [keyframes] : [];
		const props = [
			...new Set(
				frames.flatMap((frame) =>
					Object.keys(frame).filter(
						(key) => !['offset', 'computedOffset', 'easing', 'composite'].includes(key)
					)
				)
			)
		];
		record(this, props);
		return original.call(this, keyframes, options);
	};

	document.addEventListener(
		'transitionrun',
		(event) => {
			if (event.target instanceof Element) record(event.target, [event.propertyName]);
		},
		true
	);
})();
