<script lang="ts">
	import { onMount } from 'svelte';
	import { gsap, REDUCED } from '$lib/gsap';
	import { t } from '$lib/i18n.svelte';
	import SplitH from './SplitH.svelte';
	import Canvas from './Canvas.svelte';

	let section: HTMLElement;
	let stage: HTMLElement;
	let screen: HTMLElement;
	let video: HTMLVideoElement;
	let flightSvg: SVGSVGElement;
	let trail: SVGPathElement;
	let plane: SVGSVGElement;
	let burst: HTMLElement;

	onMount(() => {
		/* Ambient video: pause offscreen; manual with reduced motion */
		let videoIO: IntersectionObserver | undefined;
		if (REDUCED()) {
			video.removeAttribute('autoplay');
			video.setAttribute('controls', '');
		} else {
			videoIO = new IntersectionObserver(
				(entries) => {
					for (const e of entries) {
						if (e.isIntersecting) video.play().catch(() => {});
						else video.pause();
					}
				},
				{ threshold: 0.15 }
			);
			videoIO.observe(video);
		}

		if (REDUCED() || !window.matchMedia('(min-width: 48rem)').matches) {
			return () => videoIO?.disconnect();
		}

		const ctx = gsap.context(() => {
			const build = () => {
				const stageR = stage.getBoundingClientRect();
				const screenR = screen.getBoundingClientRect();
				const w = stageR.width;
				const h = stageR.height;
				flightSvg.setAttribute('viewBox', `0 0 ${w} ${h}`);
				const ex = screenR.left - stageR.left + screenR.width * 0.46;
				const ey = screenR.top - stageR.top + screenR.height * 0.5;
				trail.setAttribute(
					'd',
					`M ${-60} ${h * 0.74} C ${w * 0.16} ${h * 0.14}, ${w * 0.4} ${h * 0.98}, ${ex} ${ey}`
				);
				burst.style.left = `${ex}px`;
				burst.style.top = `${ey}px`;
			};
			build();

			const tl = gsap.timeline({
				scrollTrigger: {
					trigger: stage,
					start: 'top top',
					end: '+=150%',
					scrub: 1,
					pin: true,
					anticipatePin: 1,
					invalidateOnRefresh: true,
					onRefresh: build
				}
			});
			tl.from('.drench-copy > *', {
				y: 46,
				autoAlpha: 0,
				stagger: 0.05,
				duration: 0.15,
				ease: 'power3.out'
			})
				.fromTo(trail, { drawSVG: '0%' }, { drawSVG: '100%', duration: 0.5, ease: 'none' }, 0.18)
				.to(
					plane,
					{
						motionPath: { path: trail, align: trail, alignOrigin: [0.5, 0.5], autoRotate: true },
						duration: 0.5,
						ease: 'power1.inOut'
					},
					0.18
				)
				.fromTo(
					video,
					{ filter: 'brightness(0.45)', scale: 0.94 },
					{ filter: 'brightness(1)', scale: 1, duration: 0.2, ease: 'power2.out' },
					0.72
				)
				.to(plane, { scale: 0.2, autoAlpha: 0, duration: 0.05 }, 0.76)
				.fromTo(
					burst.children,
					{ scale: 0, autoAlpha: 1, x: 0, y: 0 },
					{
						scale: 1.5,
						autoAlpha: 0,
						x: (i) => Math.cos(i * 0.9) * (52 + (i % 4) * 18),
						y: (i) => Math.sin(i * 0.9) * (40 + (i % 3) * 15),
						duration: 0.14,
						stagger: 0.008,
						ease: 'power3.out'
					},
					0.78
				);
		}, section);

		return () => {
			ctx.revert();
			videoIO?.disconnect();
		};
	});
</script>

<section class="drench" id="dispatch" bind:this={section}>
	<Canvas kind="spark" />
	<div class="drench-stage" bind:this={stage}>
		<div class="drench-inner">
			<div class="drench-copy" data-reveal>
				<SplitH class="drench-h" text={t('drench.h')} />
				<p>{t('drench.p')}</p>
				<p class="meta-line">{t('drench.meta')}</p>
			</div>
			<div class="drench-screen" bind:this={screen} data-reveal style="--d: 0.12s">
				<video
					bind:this={video}
					src="/assets/demo-dispatch.mp4"
					poster="/assets/dispatch-poster.webp"
					autoplay
					muted
					loop
					playsinline
					preload="metadata"
					aria-label={t('drench.video')}
				></video>
			</div>
		</div>
		<svg class="flight-svg" bind:this={flightSvg} aria-hidden="true">
			<path class="trail" bind:this={trail} d="" />
		</svg>
		<svg class="plane" bind:this={plane} viewBox="0 0 48 48" aria-hidden="true">
			<path d="M3 25 45 5 29 43 23 29Z" fill="currentColor" />
			<path d="M23 29 45 5" stroke="oklch(82% 0.02 90)" stroke-width="1.6" fill="none" />
		</svg>
		<div class="burst" bind:this={burst} aria-hidden="true">
			{#each { length: 14 } as _}<i></i>{/each}
		</div>
	</div>
	<p class="local-line" data-reveal>
		<span class="brandmark" aria-hidden="true"></span>
		<span>{t('drench.local')}</span>
	</p>
</section>
