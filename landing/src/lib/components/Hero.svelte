<script lang="ts">
	import { onMount } from 'svelte';
	import { gsap, REDUCED } from '$lib/gsap';
	import { i18n, t, LINKS } from '$lib/i18n.svelte';
	import Icon from './Icon.svelte';
	import Sim from './Sim.svelte';
	import Canvas from './Canvas.svelte';

	let hero: HTMLElement;
	let stageEl: HTMLElement | undefined = $state();
	let artEl: HTMLElement;
	let squiggle: SVGSVGElement;

	/* Hand-drawn underline reveals via clip-path — dash tricks break under
	   non-scaling-stroke while composited animations are in flight */
	function drawSquiggle() {
		if (!squiggle) return;
		squiggle.classList.remove('drawn');
		void squiggle.getBoundingClientRect();
		squiggle.classList.add('drawn');
	}

	// Redraw the underline whenever the headline language changes
	let booted = false;
	$effect(() => {
		i18n.lang;
		if (booted) drawSquiggle();
	});

	onMount(() => {
		booted = true;
		/* First draw lands once the headline rise has fully settled */
		const pending = Array.from(hero.querySelectorAll('.display .li')).flatMap((el) =>
			Array.from(el.getAnimations()).map((a) => a.finished)
		);
		if (pending.length) Promise.allSettled(pending).then(drawSquiggle);
		else drawSquiggle();

		const cleanups: Array<() => void> = [];
		const on = (target: EventTarget, ev: string, fn: EventListener, opts?: object) => {
			target.addEventListener(ev, fn, opts);
			cleanups.push(() => target.removeEventListener(ev, fn, opts));
		};

		/* Ambient loop: pause offscreen; frozen poster with reduced motion */
		const artVideo = artEl.querySelector('video');
		if (artVideo) {
			if (REDUCED()) {
				artVideo.removeAttribute('autoplay');
				artVideo.pause();
			} else {
				const io = new IntersectionObserver(
					(entries) => {
						for (const e of entries) {
							if (e.isIntersecting) artVideo.play().catch(() => {});
							else artVideo.pause();
						}
					},
					{ threshold: 0.1 }
				);
				io.observe(artVideo);
				cleanups.push(() => io.disconnect());
			}
		}

		if (REDUCED()) return () => cleanups.forEach((fn) => fn());

		const ctx = gsap.context(() => {
			/* Scroll: art drifts up as the hero leaves */
			gsap.to(artEl, {
				yPercent: -12,
				ease: 'none',
				scrollTrigger: { trigger: hero, start: 'top top', end: 'bottom top', scrub: true }
			});

			if (window.matchMedia('(pointer: fine)').matches && stageEl) {
				const stage = stageEl;
				/* Mouse: stage tilt + art parallax */
				const xTo = gsap.quickTo(artEl, 'x', { duration: 0.7, ease: 'power3.out' });
				const yTo = gsap.quickTo(artEl, 'y', { duration: 0.7, ease: 'power3.out' });
				let tx = 0,
					ty = 0,
					cx = 0,
					cy = 0,
					tiltRaf: number | null = null;
				const stepTilt = () => {
					cx += (tx - cx) * 0.08;
					cy += (ty - cy) * 0.08;
					stage.style.setProperty('--ry', `${(cx * 5).toFixed(2)}deg`);
					stage.style.setProperty('--rx', `${(-cy * 3.5).toFixed(2)}deg`);
					if (Math.abs(tx - cx) > 0.002 || Math.abs(ty - cy) > 0.002) {
						tiltRaf = requestAnimationFrame(stepTilt);
					} else {
						tiltRaf = null;
					}
				};
				on(hero, 'mousemove', ((e: MouseEvent) => {
					const r = hero.getBoundingClientRect();
					const nx = (e.clientX - r.left) / r.width - 0.5;
					const ny = (e.clientY - r.top) / r.height - 0.5;
					tx = nx;
					ty = ny;
					xTo(nx * 22);
					yTo(ny * 16);
					if (!tiltRaf) tiltRaf = requestAnimationFrame(stepTilt);
				}) as EventListener);
				on(hero, 'mouseleave', () => {
					tx = 0;
					ty = 0;
					xTo(0);
					yTo(0);
					if (!tiltRaf) tiltRaf = requestAnimationFrame(stepTilt);
				});

				/* Magnetic primary buttons */
				hero.querySelectorAll('.btn-primary').forEach((btn) => {
					on(btn, 'mousemove', ((e: MouseEvent) => {
						const r = (btn as HTMLElement).getBoundingClientRect();
						gsap.to(btn, {
							x: ((e.clientX - r.left) / r.width - 0.5) * 7,
							y: ((e.clientY - r.top) / r.height - 0.5) * 5 - 2,
							duration: 0.4,
							ease: 'power3.out'
						});
					}) as EventListener);
					on(btn, 'mouseleave', () => {
						gsap.to(btn, { x: 0, y: 0, duration: 0.5, ease: 'power3.out' });
					});
				});
			}
		}, hero);

		/* Scroll parallax on the sim windows */
		if (window.matchMedia('(min-width: 48rem)').matches && stageEl) {
			const cells = stageEl.querySelectorAll('[data-px]');
			let ticking = false;
			const onScroll = () => {
				if (ticking) return;
				ticking = true;
				requestAnimationFrame(() => {
					const vh = window.innerHeight;
					for (const el of cells) {
						const r = el.getBoundingClientRect();
						if (r.bottom < -80 || r.top > vh + 80) continue;
						const p = (r.top + r.height / 2 - vh / 2) / vh;
						(el as HTMLElement).style.setProperty(
							'--py',
							`${(-p * Number((el as HTMLElement).dataset.px)).toFixed(1)}px`
						);
					}
					ticking = false;
				});
			};
			on(window, 'scroll', onScroll as EventListener, { passive: true });
			onScroll();
		}

		return () => {
			ctx.revert();
			cleanups.forEach((fn) => fn());
		};
	});
</script>

<section class="hero" id="top" bind:this={hero}>
	<Canvas kind="dust" />
	<div class="hero-grid">
		<div class="hero-copy">
			<h1 class="display">
				<span class="l"><span class="li">{t('hero.t1')}</span></span>
				<span class="l"
					><span class="li"
						>{t('hero.t2')}<em class="squig"
							>{t('hero.t3')}<svg
								class="squiggle"
								bind:this={squiggle}
								viewBox="0 0 200 12"
								preserveAspectRatio="none"
								aria-hidden="true"
							>
								<path d="M4 8 C 42 2, 78 11, 108 6 S 172 2, 196 7" /></svg
							></em
						>{t('hero.t4')}</span
					></span
				>
			</h1>
			<p class="hero-sub">{t('hero.sub')}</p>
			<div class="hero-ctas">
				<a class="btn btn-primary" href={LINKS.download} download>
					<Icon name="download" /><span>{t('hero.cta1')}</span>
				</a>
				<a class="btn btn-ghost" href={LINKS.repo} target="_blank" rel="noopener">
					<Icon name="github" /><span>{t('hero.cta2')}</span>
				</a>
			</div>
		</div>
		<div class="hero-art" bind:this={artEl}>
			<video
				src="/assets/loops/hero-plane.mp4"
				poster="/assets/loops/hero-plane.jpg"
				autoplay
				muted
				loop
				playsinline
				preload="metadata"
				width="736"
				height="400"
				aria-hidden="true"
				tabindex="-1"
			></video>
		</div>
	</div>

	<Sim bind:stageEl={stageEl} />
</section>
