// 替身后端：Mac 上 localhost:8787，/hello 回 JSON；允许 http://localhost:5173 跨端口访问（CORS），看手机页面经隧道能不能连到后端
Bun.serve({ hostname: "localhost", port: 8787, fetch(req) {
  const url = new URL(req.url);
  console.log(`${Date.now()} ${req.method} ${url.pathname} origin=${req.headers.get("origin")} host=${req.headers.get("host")}`);
  return Response.json({ from: "backend", path: url.pathname, t: Date.now() }, { headers: { "access-control-allow-origin": "http://localhost:5173" } });
}});
console.log("backend localhost:8787");
