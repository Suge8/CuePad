<script lang="ts">
	import { onMount } from 'svelte';
	import { gsap, REDUCED } from '$lib/gsap';
	import { t } from '$lib/i18n.svelte';
	import SplitH from './SplitH.svelte';

	let section: HTMLElement;
	let img: HTMLImageElement;
	let night: HTMLVideoElement;

	onMount(() => {
		/* Ambient loop: pause offscreen; frozen first frame with reduced motion */
		if (REDUCED()) {
			night.removeAttribute('autoplay');
			return;
		}
		const io = new IntersectionObserver(
			(entries) => {
				for (const e of entries) {
					if (e.isIntersecting) night.play().catch(() => {});
					else night.pause();
				}
			},
			{ threshold: 0.1 }
		);
		io.observe(night);

		const ctx = gsap.context(() => {
			gsap.fromTo(
				img,
				{ scale: 0.93, borderRadius: '30px' },
				{
					scale: 1,
					borderRadius: '16px',
					ease: 'none',
					scrollTrigger: {
						trigger: img,
						start: 'top 96%',
						end: 'top 45%',
						scrub: 1
					}
				}
			);
			gsap.fromTo(
				night,
				{ yPercent: 10 },
				{
					yPercent: -10,
					ease: 'none',
					scrollTrigger: { trigger: section, start: 'top bottom', end: 'bottom top', scrub: true }
				}
			);
		}, section);
		return () => {
			ctx.revert();
			io.disconnect();
		};
	});
</script>

<section class="cinema" bind:this={section}>
	<div class="sec-head" data-reveal>
		<SplitH text={t('cinema.h')} />
		<p>{t('cinema.p')}</p>
	</div>
	<div class="cinema-stage" data-reveal>
		<video
			bind:this={night}
			class="cinema-night"
			src="/assets/loops/night-loop.mp4"
			autoplay
			muted
			loop
			playsinline
			preload="metadata"
			aria-hidden="true"
			tabindex="-1"
		></video>
		<img
			bind:this={img}
			class="shot"
			src="/assets/shots/board-dark.webp"
			width="1920"
			height="1216"
			loading="lazy"
			decoding="async"
			alt={t('cinema.img')}
		/>
	</div>
</section>
