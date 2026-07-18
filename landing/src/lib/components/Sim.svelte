<script lang="ts">
	import { onMount } from 'svelte';
	import { i18n, t } from '$lib/i18n.svelte';
	import Icon from './Icon.svelte';

	let { stageEl = $bindable() }: { stageEl?: HTMLElement } = $props();

	let typedEl: HTMLElement;
	let landedEl: HTMLElement;
	let dispatchEl: HTMLElement;

	let running = false;
	let gen = 0;
	let flight: Animation | null = null;
	const timers = new Set<ReturnType<typeof setTimeout>>();
	const reduced = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;

	// Chip lives outside the component tree (fixed, flies across the viewport)
	let chip: HTMLElement;

	const after = (g: number, ms: number, fn: () => void) => {
		const id = setTimeout(() => {
			timers.delete(id);
			if (running && g === gen) fn();
		}, ms);
		timers.add(id);
	};

	function typeText(el: HTMLElement, text: string, speed: number, g: number, done: () => void) {
		let i = 0;
		const step = () => {
			if (!running || g !== gen) return;
			el.textContent = text.slice(0, ++i);
			if (i < text.length) after(g, speed, step);
			else done();
		};
		step();
	}

	function fly(g: number, done: () => void) {
		const from = typedEl.getBoundingClientRect();
		const to = landedEl.getBoundingClientRect();
		chip.textContent = t('sim.typed').slice(0, 16) + ' …';
		chip.style.left = `${from.left}px`;
		chip.style.top = `${from.top - 6}px`;
		chip.style.opacity = '1';
		const dx = to.left - from.left;
		const dy = to.top - from.top;
		flight = chip.animate(
			[
				{ transform: 'translate(0, 0) scale(1)', opacity: 1, offset: 0 },
				{
					transform: `translate(${dx * 0.5}px, ${dy * 0.5 - 64}px) scale(0.82)`,
					opacity: 1,
					offset: 0.55
				},
				{ transform: `translate(${dx}px, ${dy}px) scale(0.3)`, opacity: 0.85, offset: 1 }
			],
			{ duration: 640, easing: 'cubic-bezier(0.55, 0, 0.2, 1)', fill: 'forwards' }
		);
		flight.onfinish = () => {
			chip.style.opacity = '0';
			// fill:'forwards' would otherwise hold the final keyframe over inline styles
			flight?.cancel();
			done();
		};
	}

	function loop(g: number) {
		const text = t('sim.typed');
		typedEl.textContent = '';
		landedEl.textContent = '';
		typeText(typedEl, text, i18n.lang === 'zh' ? 62 : 26, g, () => {
			dispatchEl.classList.add('pulse');
			after(g, 600, () => {
				dispatchEl.classList.remove('pulse');
				fly(g, () => {
					typeText(landedEl, text, 13, g, () => after(g, 2600, () => loop(g)));
				});
			});
		});
	}

	function fillStatic() {
		typedEl.textContent = t('sim.typed');
		landedEl.textContent = t('sim.typed');
	}

	function start() {
		if (running || reduced()) return;
		running = true;
		loop(++gen);
	}
	function stop() {
		running = false;
		gen++;
		timers.forEach(clearTimeout);
		timers.clear();
		if (flight) flight.cancel();
		chip.style.opacity = '0';
	}

	// Restart with fresh copy when the language changes
	$effect(() => {
		i18n.lang;
		if (!typedEl || !chip) return;
		if (reduced()) fillStatic();
		else if (running) loop(++gen);
	});

	onMount(() => {
		chip = document.createElement('div');
		chip.className = 'chip';
		chip.setAttribute('aria-hidden', 'true');
		document.body.appendChild(chip);
		if (reduced()) fillStatic();

		let visible = false;
		const io = new IntersectionObserver(
			(entries) => {
				visible = entries[0].isIntersecting;
				if (visible && !document.hidden) start();
				else stop();
			},
			{ threshold: 0.2 }
		);
		io.observe(stageEl!);
		const onVis = () => {
			if (document.hidden) stop();
			else if (visible) start();
		};
		document.addEventListener('visibilitychange', onVis);

		return () => {
			stop();
			io.disconnect();
			document.removeEventListener('visibilitychange', onVis);
			chip.remove();
		};
	});
</script>

<div
	class="stage"
	bind:this={stageEl}
	role="img"
	aria-label={t('sim.aria')}
>
	<div class="cell pad-cell" data-px="8">
		<div class="window pad">
			<div class="wbar" aria-hidden="true">
				<span class="tl"></span><span class="tl"></span><span class="tl"></span>
				<span class="wmark"></span>
				<span class="wtitle">{t('sim.title')}</span>
			</div>
			<div class="pad-body">
				<p class="pad-text">
					<span bind:this={typedEl}></span><span class="caret" aria-hidden="true"></span>
				</p>
			</div>
			<div class="pad-foot">
				<span class="pin">
					<Icon name="terminal" />
					<span>{t('sim.pin')}</span>
				</span>
				<span class="dispatch" bind:this={dispatchEl}>
					<Icon name="send" />
					<span>{t('sim.send')}</span>
				</span>
			</div>
		</div>
	</div>
	<div class="cell term-cell" data-px="16">
		<div class="window term">
			<div class="wbar" aria-hidden="true">
				<span class="tl"></span><span class="tl"></span><span class="tl"></span>
				<span class="wtitle">zsh</span>
			</div>
			<div class="term-body">
				<p class="t-dim"><span class="t-prompt">❯</span>bun test</p>
				<p class="t-ok">✓ 42 pass, 0 fail</p>
				<p>
					<span class="t-prompt">❯</span><span bind:this={landedEl}></span><span
						class="t-cursor"
						aria-hidden="true"
					></span>
				</p>
			</div>
		</div>
	</div>
	<img class="mascot-hero bob" src="/assets/mascot-hello.webp" width="560" height="496" alt="" />
</div>
