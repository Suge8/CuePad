<script lang="ts">
	import { onMount } from 'svelte';
	import { gsap, REDUCED } from '$lib/gsap';
	import { t } from '$lib/i18n.svelte';
	import Icon from './Icon.svelte';
	import SplitH from './SplitH.svelte';

	let section: HTMLElement;
	let list: HTMLOListElement;
	let svg: SVGSVGElement;
	let trail: SVGPathElement;
	let plane: SVGSVGElement;

	/* A dashed flight path weaving through the three steps, plane rides it on scroll */
	onMount(() => {
		if (REDUCED() || !window.matchMedia('(min-width: 48rem)').matches) return;

		const smooth = (pts: Array<{ x: number; y: number }>) => {
			let d = `M ${pts[0].x} ${pts[0].y}`;
			for (let i = 0; i < pts.length - 1; i++) {
				const p0 = pts[Math.max(0, i - 1)];
				const p1 = pts[i];
				const p2 = pts[i + 1];
				const p3 = pts[Math.min(pts.length - 1, i + 2)];
				d += ` C ${p1.x + (p2.x - p0.x) / 6} ${p1.y + (p2.y - p0.y) / 6}, ${p2.x - (p3.x - p1.x) / 6} ${p2.y - (p3.y - p1.y) / 6}, ${p2.x} ${p2.y}`;
			}
			return d;
		};

		const ctx = gsap.context(() => {
			const build = () => {
				const sr = section.getBoundingClientRect();
				const pts = Array.from(list.querySelectorAll('.step')).map((s) => {
					const r = s.getBoundingClientRect();
					return { x: r.left - sr.left + r.width / 2, y: r.top - sr.top + 56 };
				});
				if (pts.length < 2) return;
				const w = sr.width;
				const path = [
					{ x: -80, y: pts[0].y + 90 },
					{ x: pts[0].x, y: pts[0].y - 70 },
					{ x: pts[1].x, y: pts[1].y - 130 },
					{ x: pts[2].x, y: pts[2].y - 70 },
					{ x: w + 80, y: pts[2].y - 150 }
				];
				svg.setAttribute('viewBox', `0 0 ${w} ${sr.height}`);
				trail.setAttribute('d', smooth(path));
			};
			build();

			gsap
				.timeline({
					scrollTrigger: {
						trigger: list,
						start: 'top 78%',
						end: 'bottom 30%',
						scrub: 1,
						invalidateOnRefresh: true,
						onRefresh: build
					}
				})
				.fromTo(trail, { drawSVG: '0%' }, { drawSVG: '100%', ease: 'none', duration: 1 }, 0)
				.to(
					plane,
					{
						motionPath: { path: trail, align: trail, alignOrigin: [0.5, 0.5], autoRotate: true },
						ease: 'none',
						duration: 1
					},
					0
				);
		}, section);
		return () => ctx.revert();
	});
</script>

<section class="how" id="how" bind:this={section}>
	<div class="sec-head" data-reveal>
		<SplitH text={t('how.h')} />
	</div>
	<svg class="flightpath" bind:this={svg} aria-hidden="true">
		<path class="fp-trail" bind:this={trail} d="" />
	</svg>
	<svg class="fp-plane" bind:this={plane} viewBox="0 0 48 48" aria-hidden="true">
		<path d="M3 25 45 5 29 43 23 29Z" fill="currentColor" />
		<path d="M23 29 45 5" stroke="oklch(82% 0.02 90)" stroke-width="1.6" fill="none" />
	</svg>
	<ol class="steps" bind:this={list}>
		<li class="step" data-reveal style="--d: 0s">
			<h3>
				<Icon name="pen-line" class="step-ic" />
				<span>{t('how.1.h')}</span>
			</h3>
			<p>{t('how.1.p')}</p>
		</li>
		<li class="step" data-reveal style="--d: 0.1s">
			<h3>
				<Icon name="command" class="step-ic" />
				<span>{t('how.2.h')}</span>
			</h3>
			<p>{t('how.2.p')}</p>
			<span class="kbd">⌥ Space</span>
		</li>
		<li class="step" data-reveal style="--d: 0.2s">
			<h3>
				<Icon name="send" class="step-ic" />
				<span>{t('how.3.h')}</span>
			</h3>
			<p>{t('how.3.p')}</p>
			<span class="kbd">⇧ ↵</span>
		</li>
	</ol>
</section>
