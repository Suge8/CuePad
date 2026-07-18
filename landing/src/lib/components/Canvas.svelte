<script lang="ts">
	import { onMount } from 'svelte';

	let { kind }: { kind: 'dust' | 'spark' } = $props();
	let canvas: HTMLCanvasElement;

	onMount(() => {
		if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
		const ctx2d = canvas.getContext('2d')!;
		const DPR = Math.min(window.devicePixelRatio || 1, 2);
		const DUST = kind === 'dust';
		const COUNT = DUST ? 34 : 26;
		let w = 0,
			h = 0,
			time = 0,
			raf: number | null = null;

		interface P {
			x: number;
			y: number;
			s: number;
			vx: number;
			vy: number;
			phase: number;
			spin: number;
			hue: number;
		}
		let parts: P[] = [];

		function resize() {
			const r = canvas.parentElement!.getBoundingClientRect();
			w = r.width;
			h = r.height;
			canvas.width = w * DPR;
			canvas.height = h * DPR;
			ctx2d.setTransform(DPR, 0, 0, DPR, 0, 0);
		}
		function seed() {
			parts = Array.from({ length: COUNT }, () => ({
				x: Math.random() * w,
				y: Math.random() * h,
				s: DUST ? 1 + Math.random() * 2.6 : 1.6 + Math.random() * 2.6,
				vx: DUST ? -0.08 + Math.random() * 0.14 : -0.03 + Math.random() * 0.06,
				vy: DUST ? -0.12 - Math.random() * 0.08 : -0.05 - Math.random() * 0.05,
				phase: Math.random() * Math.PI * 2,
				spin: 0.4 + Math.random() * 1.2,
				hue: Math.random()
			}));
		}
		function draw() {
			time += 0.016;
			ctx2d.clearRect(0, 0, w, h);
			for (const p of parts) {
				p.x += p.vx + Math.sin(time * p.spin + p.phase) * 0.12;
				p.y += p.vy;
				if (p.y < -8) p.y = h + 8;
				if (p.x < -8) p.x = w + 8;
				if (p.x > w + 8) p.x = -8;
				if (DUST) {
					const a = 0.05 + 0.05 * (0.5 + 0.5 * Math.sin(time * p.spin + p.phase));
					ctx2d.fillStyle =
						p.hue < 0.6
							? `rgba(23, 21, 18, ${a})`
							: p.hue < 0.85
								? `rgba(86, 128, 103, ${a})`
								: `rgba(200, 162, 74, ${a})`;
					ctx2d.save();
					ctx2d.translate(p.x, p.y);
					ctx2d.rotate(p.phase + time * p.spin * 0.4);
					ctx2d.fillRect(-p.s / 2, -p.s / 2, p.s, p.s * 0.72);
					ctx2d.restore();
				} else {
					const a = 0.14 + 0.3 * (0.5 + 0.5 * Math.sin(time * p.spin * 1.6 + p.phase));
					ctx2d.fillStyle = p.hue < 0.55 ? `rgba(200, 162, 74, ${a})` : `rgba(169, 196, 180, ${a})`;
					const s = p.s * (0.7 + 0.3 * Math.sin(time * p.spin * 1.6 + p.phase));
					ctx2d.beginPath();
					ctx2d.moveTo(p.x, p.y - s);
					ctx2d.quadraticCurveTo(p.x, p.y, p.x + s, p.y);
					ctx2d.quadraticCurveTo(p.x, p.y, p.x, p.y + s);
					ctx2d.quadraticCurveTo(p.x, p.y, p.x - s, p.y);
					ctx2d.quadraticCurveTo(p.x, p.y, p.x, p.y - s);
					ctx2d.fill();
				}
			}
			raf = requestAnimationFrame(draw);
		}
		function start() {
			if (!raf && !document.hidden) {
				resize();
				raf = requestAnimationFrame(draw);
			}
		}
		function stop() {
			if (raf) cancelAnimationFrame(raf);
			raf = null;
		}

		resize();
		seed();
		const io = new IntersectionObserver((entries) => {
			if (entries[0].isIntersecting) start();
			else stop();
		});
		io.observe(canvas);
		const onVis = () => (document.hidden ? stop() : start());
		document.addEventListener('visibilitychange', onVis);
		const onResize = () => {
			resize();
			seed();
		};
		window.addEventListener('resize', onResize);

		return () => {
			stop();
			io.disconnect();
			document.removeEventListener('visibilitychange', onVis);
			window.removeEventListener('resize', onResize);
		};
	});
</script>

<canvas class={kind === 'dust' ? 'dust' : 'sparks'} bind:this={canvas} aria-hidden="true"></canvas>
