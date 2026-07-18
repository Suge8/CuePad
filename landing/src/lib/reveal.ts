/* Shared scroll-reveal: adds .in once; pure enhancement over visible SSR content */
export function observeReveals(): () => void {
	const io = new IntersectionObserver(
		(entries) => {
			for (const entry of entries) {
				if (entry.isIntersecting) {
					entry.target.classList.add('in');
					io.unobserve(entry.target);
				}
			}
		},
		{ threshold: 0.12, rootMargin: '0px 0px -6% 0px' }
	);
	document.querySelectorAll('[data-reveal]').forEach((el) => io.observe(el));
	return () => io.disconnect();
}
