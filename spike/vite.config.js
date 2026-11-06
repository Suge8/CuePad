// 同源 /api 由 Vite 在 Mac 上转给后端（手机只经隧道访问 5173）
export default { server: { proxy: { '/api': { target: 'http://localhost:8787', rewrite: (p) => p.replace(/^\/api/, '') } } } }
