<script lang="ts">
	import { onMount } from 'svelte';
	import { gsap, REDUCED } from '$lib/gsap';
	import { t } from '$lib/i18n.svelte';
	import SplitH from './SplitH.svelte';

	let section: HTMLElement;

	onMount(() => {
		if (REDUCED()) return;
		const ctx = gsap.context(() => {
			section.querySelectorAll<HTMLElement>('.feat').forEach((row) => {
				const frame = row.querySelector('.clipframe');
				if (frame) {
					gsap.fromTo(
						frame,
						{ clipPath: 'inset(12% 7% 12% 7% round 28px)' },
						{
							clipPath: 'inset(0% 0% 0% 0% round 18px)',
							duration: 1.1,
							ease: 'power3.out',
							scrollTrigger: { trigger: row, start: 'top 72%', once: true }
						}
					);
				}
				row.querySelectorAll('.par').forEach((media) => {
					gsap.fromTo(
						media,
						{ yPercent: -5 },
						{
							yPercent: 5,
							ease: 'none',
							scrollTrigger: { trigger: row, start: 'top bottom', end: 'bottom top', scrub: true }
						}
					);
				});
			});
		}, section);
		return () => ctx.revert();
	});
</script>

<section class="features" id="features" bind:this={section}>
	<div class="sec-head" data-reveal>
		<SplitH text={t('feat.h')} />
	</div>

	<article class="feat" data-reveal>
		<div class="feat-copy">
			<h3>{t('f1.h')}</h3>
			<p>{@html t('f1.p')}</p>
			<ul class="ticks">
				<li>{t('f1.t1')}</li>
				<li>{t('f1.t2')}</li>
				<li>{t('f1.t3')}</li>
			</ul>
		</div>
		<div class="feat-media duo-media">
			<div class="clipframe">
				<video
					class="par"
					src="/assets/pan-editor.mp4"
					poster="/assets/shots/editor-light.webp"
					autoplay
					muted
					loop
					playsinline
					preload="metadata"
					width="1600"
					height="1014"
					aria-label={t('f1.img1')}
				></video>
			</div>
			<img
				class="shot float"
				src="/assets/shots/segments-light.webp"
				width="1600"
				height="1013"
				loading="lazy"
				decoding="async"
				alt={t('f1.img2')}
			/>
		</div>
	</article>

	<article class="feat rev" data-reveal>
		<div class="feat-copy">
			<h3>{t('f2.h')}</h3>
			<p>{@html t('f2.p')}</p>
			<ul class="ticks">
				<li>{t('f2.t1')}</li>
				<li>{t('f2.t2')}</li>
			</ul>
		</div>
		<div class="feat-media">
			<div class="clipframe">
				<img
					class="par"
					src="/assets/shots/variables-light.webp"
					width="1600"
					height="1013"
					loading="lazy"
					decoding="async"
					alt={t('f2.img')}
				/>
			</div>
		</div>
	</article>

	<article class="feat" data-reveal>
		<div class="feat-copy">
			<h3>{t('f3.h')}</h3>
			<p>{@html t('f3.p')}</p>
		</div>
		<div class="feat-media">
			<div class="clipframe">
				<img
					class="par"
					src="/assets/shots/search-light.webp"
					width="1600"
					height="1013"
					loading="lazy"
					decoding="async"
					alt={t('f3.img')}
				/>
			</div>
		</div>
	</article>

	<article class="feat rev" data-reveal>
		<div class="feat-copy">
			<h3>{t('f4.h')}</h3>
			<p>{t('f4.p')}</p>
		</div>
		<div class="feat-media">
			<div class="clipframe">
				<img
					class="par"
					src="/assets/shots/tasks-light.webp"
					width="1600"
					height="1013"
					loading="lazy"
					decoding="async"
					alt={t('f4.img')}
				/>
			</div>
		</div>
	</article>
</section>
