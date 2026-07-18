<script lang="ts">
	import { onMount } from 'svelte';
	import { gsap, REDUCED } from '$lib/gsap';
	import { t, LINKS } from '$lib/i18n.svelte';
	import Icon from './Icon.svelte';
	import SplitH from './SplitH.svelte';

	let section: HTMLElement;
	let burst: HTMLElement;
	let cheer: HTMLVideoElement;

	onMount(() => {
		/* Ambient loop: pause offscreen; frozen poster with reduced motion */
		if (REDUCED()) {
			cheer.removeAttribute('autoplay');
			return;
		}
		const io = new IntersectionObserver(
			(entries) => {
				for (const e of entries) {
					if (e.isIntersecting) cheer.play().catch(() => {});
					else cheer.pause();
				}
			},
			{ threshold: 0.1 }
		);
		io.observe(cheer);

		const ctx = gsap.context(() => {
			/* One celebration burst when the section enters */
			gsap.fromTo(
				burst.children,
				{ scale: 0, autoAlpha: 1, x: 0, y: 0 },
				{
					scale: 1.4,
					autoAlpha: 0,
					x: (i) => Math.cos(i * 0.7) * (70 + (i % 5) * 26),
					y: (i) => Math.sin(i * 0.7) * (54 + (i % 4) * 22) - 30,
					duration: 1.2,
					stagger: 0.035,
					ease: 'power3.out',
					scrollTrigger: { trigger: section, start: 'top 62%', once: true }
				}
			);
		}, section);
		return () => {
			ctx.revert();
			io.disconnect();
		};
	});
</script>

<section class="download" id="download" bind:this={section}>
	<div data-reveal>
		<div class="dl-burst" bind:this={burst} aria-hidden="true">
			{#each { length: 16 } as _}<i></i>{/each}
		</div>
		<video
			bind:this={cheer}
			class="mascot-dl"
			src="/assets/loops/cheer-loop.mp4"
			poster="/assets/loops/cheer-loop.jpg"
			autoplay
			muted
			loop
			playsinline
			preload="metadata"
			aria-hidden="true"
			tabindex="-1"
		></video>
		<SplitH text={t('dl.h')} />
		<p>{t('dl.p')}</p>
		<div class="dl-ctas">
			<a class="btn btn-primary" href={LINKS.download} download>
				<Icon name="download" /><span>{t('dl.cta1')}</span>
			</a>
			<a class="btn btn-ghost" href={LINKS.repo} target="_blank" rel="noopener">
				<Icon name="star" /><span>{t('dl.cta2')}</span>
			</a>
		</div>
		<div class="reqs">
			<span class="req">{t('dl.req1')}</span>
			<span class="req">{t('dl.req2')}</span>
			<span class="req">{t('dl.req3')}</span>
		</div>
		<p class="note">{t('dl.note')}</p>
		<p class="dl-source">
			<a href={LINKS.repo} target="_blank" rel="noopener">{t('dl.source')}</a>
		</p>
	</div>
</section>
