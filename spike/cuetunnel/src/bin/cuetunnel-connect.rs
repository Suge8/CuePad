//! 手机端的命令行替身（远端服务器、Mac 上对照用）：cuetunnel-connect <ticket> <本机端口> [--relay-only] [--remote <Mac 端口>，默认 5173]。
use cuetunnel::{connect, endpoint, forward_local, log, parse_ticket};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let remote = args.iter().position(|a| a == "--remote").map(|i| args[i + 1].parse().expect("port")).unwrap_or(5173);
    let endpoint = endpoint(args.iter().any(|a| a == "--relay-only"), vec![]).await;
    let peer = connect(endpoint, parse_ticket(&args[1])).await;
    let port = forward_local(peer, remote, args[2].parse().expect("port")).await;
    log!("forwarding 127.0.0.1:{port} -> mac:{remote}");
    std::future::pending::<()>().await;
}
