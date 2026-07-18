<script lang="ts">
	import { onMount } from 'svelte';
	import { gsap, REDUCED } from '$lib/gsap';
	import { t } from '$lib/i18n.svelte';

	let band: HTMLElement;
	let video: HTMLVideoElement;

	onMount(() => {
		/* Ambient loop: pause offscreen; frozen poster with reduced motion */
		if (REDUCED()) {
			video.removeAttribute('autoplay');
			return;
		}
		const io = new IntersectionObserver(
			(entries) => {
				for (const e of entries) {
					if (e.isIntersecting) video.play().catch(() => {});
					else video.pause();
				}
			},
			{ threshold: 0.05 }
		);
		io.observe(video);

		const ctx = gsap.context(() => {
			gsap.fromTo(
				video,
				{ yPercent: -9 },
				{
					yPercent: 9,
					ease: 'none',
					scrollTrigger: { trigger: band, start: 'top bottom', end: 'bottom top', scrub: true }
				}
			);
		}, band);
		return () => {
			ctx.revert();
			io.disconnect();
		};
	});
</script>

<div class="desk" bind:this={band}>
	<video
		bind:this={video}
		src="/assets/loops/desk-loop.mp4"
		poster="/assets/loops/desk-loop.jpg"
		autoplay
		muted
		loop
		playsinline
		preload="metadata"
		aria-hidden="true"
		tabindex="-1"
	></video>
	<p class="desk-line">{t('desk.line')}</p>
</div>
