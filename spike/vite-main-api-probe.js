
// 原型：同源经 Vite proxy 与跨端口直连两种方式访问后端，结果写进页面
const api = document.createElement('p'); api.id = 'api'; document.querySelector('#center').append(api)
const show = (label, p) => p.then(r => r.json()).then(j => `${label}:ok(${j.from})`, e => `${label}:fail(${e.message})`)
Promise.all([show('same-origin', fetch('/api/hello')), show('cross-port', fetch('http://localhost:8787/hello')), show('cdn', fetch('https://cdn.jsdelivr.net/npm/vite@8/package.json').then(r => ({ json: () => r.json().then(() => ({ from: 'jsdelivr' })) })))]).then(r => { api.textContent = r.join(' ') })
