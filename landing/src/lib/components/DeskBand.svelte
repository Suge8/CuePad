<script lang="ts">
	import { onMount } from 'svelte';
	import { observeVideo } from '$lib/video';
	import { gsap, REDUCED } from '$lib/gsap';
	import { t } from '$lib/i18n.svelte';

	let band: HTMLElement;
	let video: HTMLVideoElement;

	onMount(() => {
		const stopVideo = observeVideo(video, 0.05, 'static');
		if (REDUCED()) return stopVideo;

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
			stopVideo();
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
