<script lang="ts">
	import '../styles/base.css';
</script>

<svelte:head>
	<title>CuePad</title>
	<meta name="description" content="A calm notebook that runs your coding agents. A major update is on the way." />
</svelte:head>

<main>
	<img src="/assets/mascot-hello.webp" alt="" width="160" height="142" />
	<h1>CuePad</h1>
	<p>A major update is on the way.</p>
	<p lang="zh-CN">即将大更新。</p>
	<a href="https://github.com/Suge8/CuePad/releases/latest">Download for Mac</a>
</main>

<style>
	main {
		display: grid;
		justify-items: center;
		gap: 0.5rem;
		padding: 2rem;
		text-align: center;
	}
	h1 {
		margin: 0.5rem 0 0.25rem;
		font-size: 2rem;
		font-weight: 650;
		letter-spacing: -0.02em;
	}
	p {
		margin: 0;
		color: var(--ink2);
	}
	a {
		margin-top: 1.25rem;
		padding: 0.6rem 1.1rem;
		border-radius: 999px;
		background: var(--ink);
		color: var(--paper);
		font-weight: 550;
		text-decoration: none;
	}
	a:focus-visible {
		outline: 2px solid var(--signature);
		outline-offset: 3px;
	}
</style>
