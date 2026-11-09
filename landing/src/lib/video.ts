import { REDUCED } from './gsap';

export function observeVideo(
	video: HTMLVideoElement,
	threshold: number,
	reducedMotion: 'static' | 'manual'
): () => void {
	let observer: IntersectionObserver | undefined;
	if (REDUCED()) {
		video.removeAttribute('autoplay');
		video.pause();
		if (reducedMotion === 'manual') video.controls = true;
	} else {
		observer = new IntersectionObserver(
			(entries) => {
				for (const entry of entries) {
					if (entry.isIntersecting) video.play().catch(() => {});
					else video.pause();
				}
			},
			{ threshold }
		);
		observer.observe(video);
	}
	return () => {
		observer?.disconnect();
		video.pause();
	};
}
