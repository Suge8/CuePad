//! Mac 端：cuetunnel-listen <授权端口,…> [--relay-only]。ticket 打到标准输出，日志到标准错误。
use cuetunnel::{ALPN, endpoint, serve};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let allowed: Vec<u16> = args[1].split(',').map(|p| p.parse().expect("port")).collect();
    let endpoint = endpoint(args.iter().any(|a| a == "--relay-only"), vec![ALPN.to_vec()]).await;
    println!("{}", iroh_tickets::endpoint::EndpointTicket::new(endpoint.addr()));
    serve(endpoint, allowed).await;
}
