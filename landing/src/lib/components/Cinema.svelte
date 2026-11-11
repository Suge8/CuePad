<script lang="ts">
	import { onMount } from 'svelte';
	import { observeVideo } from '$lib/video';
	import { gsap, REDUCED } from '$lib/gsap';
	import { t } from '$lib/i18n.svelte';
	import SplitH from './SplitH.svelte';

	let section: HTMLElement;
	let img: HTMLImageElement;
	let night: HTMLVideoElement;

	onMount(() => {
		const stopVideo = observeVideo(night, 0.1, 'static');
		if (REDUCED()) return stopVideo;

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
			stopVideo();
		};
	});
</script>

<section class="cinema night" bind:this={section}>
	<div class="sec-head" data-reveal>
		<SplitH text={t('cinema.h')} />
		<p>{t('cinema.p')}</p>
	</div>
	<div class="cinema-stage" data-reveal>
		<video
			bind:this={night}
			class="cinema-night"
			src="/assets/loops/night-loop.mp4"
			poster="/assets/loops/night-loop.jpg"
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
			width="1600"
			height="1000"
			loading="lazy"
			decoding="async"
			alt={t('cinema.img')}
		/>
	</div>
</section>
