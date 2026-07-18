<script lang="ts">
	import { onMount } from 'svelte';
	import { gsap, REDUCED } from '$lib/gsap';
	import { t } from '$lib/i18n.svelte';

	let band: HTMLElement;
	let track: HTMLElement;

	onMount(() => {
		if (REDUCED()) return;
		const ctx = gsap.context(() => {
			gsap.fromTo(
				track,
				{ xPercent: 2 },
				{
					xPercent: -16,
					ease: 'none',
					scrollTrigger: { trigger: band, start: 'top bottom', end: 'bottom top', scrub: true }
				}
			);
		}, band);
		return () => ctx.revert();
	});
</script>

<div class="ghost" bind:this={band} aria-hidden="true">
	<div class="ghost-track" bind:this={track}>
		{#each [0, 1, 2, 3] as i}
			<span class={i % 2 === 1 ? 'fill' : ''}>{t('ghost.line')}</span>
		{/each}
	</div>
</div>
