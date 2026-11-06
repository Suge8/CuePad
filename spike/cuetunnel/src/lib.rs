//! CuePad 网页预览的隧道核心（spike）：iroh 一条连接，上面每条双向流就是一条 TCP 连接，流的头两个字节是目标端口（大端）。
//! Mac 端（`serve`）只把流接到白名单里的本机端口（dev server 与它声明的后端），别的端口直接关流；
//! 手机端（`forward_local`）为每个授权端口在回环上开一个端口，每条进来的 TCP 连接开一条流。
//! 给 Swift 的只有 `cuetunnel_connect` 与 `cuetunnel_forward`：不绑定 iroh 的整套 API，生命周期、重连都留在 Rust 里。
use std::{
    ffi::{CStr, c_char},
    sync::OnceLock,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

use iroh::{
    Endpoint, EndpointAddr,
    endpoint::{Connection, presets},
};
use n0_future::StreamExt;
use tokio::{
    io::AsyncWriteExt,
    net::{TcpListener, TcpStream},
    runtime::Runtime,
    sync::Mutex,
};

pub const ALPN: &[u8] = b"cuepad/preview/0";

pub fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()
}

#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => { eprintln!("CT {} {}", $crate::now_ms(), format!($($arg)*)) };
}

/// `relay_only`：去掉 IP 传输，只走中继（量中继时延用）。环境变量 `CUETUNNEL_RELAY=<url>` 换成自营中继（不给用 n0 公共中继）。
pub async fn endpoint(relay_only: bool, alpns: Vec<Vec<u8>>) -> Endpoint {
    let mut builder = Endpoint::builder(presets::N0).alpns(alpns);
    if let Ok(url) = std::env::var("CUETUNNEL_RELAY") {
        let url: iroh::RelayUrl = url.parse().expect("relay url");
        builder = builder.relay_mode(iroh::RelayMode::Custom(url.into()));
    }
    if relay_only {
        builder = builder.clear_ip_transports();
    }
    let began = Instant::now();
    let endpoint = builder.bind().await.expect("bind");
    let _ = tokio::time::timeout(std::time::Duration::from_secs(8), endpoint.online()).await;
    log!("endpoint id={} online +{}ms relay_only={relay_only}", endpoint.id(), began.elapsed().as_millis());
    endpoint
}

/// 记下这条连接选中的路径（中继或直连）与 RTT，每次变化打一行。
fn watch_paths(connection: Connection, label: &'static str) {
    tokio::spawn(async move {
        let mut stream = connection.paths_stream();
        let mut last = String::new();
        while let Some(list) = stream.next().await {
            let Some(selected) = list.iter().find(|p| p.is_selected()) else { continue };
            let line = format!("{}:{}", if selected.is_relay() { "relay" } else { "direct" }, selected.remote_addr());
            if line != last {
                log!("{label} selected {line} rtt={}ms open_paths={}", selected.rtt().as_millis(), list.iter().count());
                last = line;
            }
        }
        log!("{label} connection closed");
    });
}

async fn splice(tcp: TcpStream, mut send: iroh::endpoint::SendStream, mut recv: iroh::endpoint::RecvStream) {
    let (mut read, mut write) = tcp.into_split();
    let up = async {
        let _ = tokio::io::copy(&mut read, &mut send).await;
        let _ = send.finish();
    };
    let down = async {
        let _ = tokio::io::copy(&mut recv, &mut write).await;
        let _ = write.shutdown().await;
    };
    tokio::join!(up, down);
}

/// Mac 端：接受连接，每条双向流按头两个字节的端口接到 localhost:<port>（localhost 依次试 ::1 与 127.0.0.1：Vite 默认只听 ::1）。
pub async fn serve(endpoint: Endpoint, allowed: Vec<u16>) {
    while let Some(incoming) = endpoint.accept().await {
        let allowed = allowed.clone();
        tokio::spawn(async move {
            let Ok(connection) = incoming.await else { return };
            log!("serve accepted remote={}", connection.remote_id());
            watch_paths(connection.clone(), "serve");
            let mut streams = 0u64;
            while let Ok((send, mut recv)) = connection.accept_bi().await {
                streams += 1;
                let id = streams;
                let allowed = allowed.clone();
                tokio::spawn(async move {
                    let mut head = [0u8; 2];
                    if recv.read_exact(&mut head).await.is_err() { return }
                    let port = u16::from_be_bytes(head);
                    if !allowed.contains(&port) {
                        log!("serve stream #{id} refused port {port}");
                        return;
                    }
                    match TcpStream::connect(("localhost", port)).await {
                        Ok(tcp) => splice(tcp, send, recv).await,
                        Err(error) => log!("serve stream #{id} target error {error}"),
                    }
                });
            }
        });
    }
}

pub struct Peer {
    endpoint: Endpoint,
    addr: EndpointAddr,
    connection: Mutex<Option<Connection>>,
}

impl Peer {
    /// 复用同一条连接；断了（Mac 睡醒、换网）下一条 TCP 进来时重连。
    async fn connection(&self) -> Option<Connection> {
        let mut slot = self.connection.lock().await;
        if let Some(connection) = slot.as_ref().filter(|c| c.close_reason().is_none()) {
            return Some(connection.clone());
        }
        let began = Instant::now();
        match self.endpoint.connect(self.addr.clone(), ALPN).await {
            Ok(connection) => {
                log!("connect ok +{}ms", began.elapsed().as_millis());
                watch_paths(connection.clone(), "client");
                *slot = Some(connection.clone());
                Some(connection)
            }
            Err(error) => {
                log!("connect failed +{}ms {error}", began.elapsed().as_millis());
                None
            }
        }
    }
}

/// 手机端：连上 Mac（同一条连接给所有端口复用）。
pub async fn connect(endpoint: Endpoint, addr: EndpointAddr) -> std::sync::Arc<Peer> {
    let peer = std::sync::Arc::new(Peer { endpoint, addr, connection: Mutex::new(None) });
    peer.connection().await;
    peer
}

/// 手机端：在 127.0.0.1:<bind_port>（0 为随机）上监听，每条 TCP 连接开一条去 Mac <remote_port> 的流，返回实际端口。
pub async fn forward_local(peer: std::sync::Arc<Peer>, remote_port: u16, bind_port: u16) -> u16 {
    let listener = TcpListener::bind(("127.0.0.1", bind_port)).await.expect("listen");
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let peer = peer.clone();
            tokio::spawn(async move {
                let Some(connection) = peer.connection().await else { return };
                match connection.open_bi().await {
                    Ok((mut send, recv)) => {
                        if send.write_all(&remote_port.to_be_bytes()).await.is_ok() { splice(tcp, send, recv).await }
                    }
                    Err(error) => log!("open_bi failed {error}"),
                }
            });
        }
    });
    port
}

pub fn parse_ticket(ticket: &str) -> EndpointAddr {
    ticket.parse::<iroh_tickets::endpoint::EndpointTicket>().expect("ticket").endpoint_addr().clone()
}

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap())
}

static PEER: OnceLock<std::sync::Arc<Peer>> = OnceLock::new();

/// Swift 调：连上 ticket 指的 Mac（一个进程一次）。阻塞到连上为止，调用方放在后台线程。
///
/// # Safety
/// `ticket` 是以 NUL 结尾的 UTF-8 字符串。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cuetunnel_connect(ticket: *const c_char, relay_only: bool) -> bool {
    let ticket = unsafe { CStr::from_ptr(ticket) }.to_string_lossy().into_owned();
    runtime().block_on(async move {
        let endpoint = endpoint(relay_only, vec![]).await;
        let peer = connect(endpoint, parse_ticket(&ticket)).await;
        PEER.set(peer).is_ok()
    })
}

/// Swift 调：Mac 上 `remote_port` 在手机回环上的端口（失败 0）。
#[unsafe(no_mangle)]
pub extern "C" fn cuetunnel_forward(remote_port: u16) -> u16 {
    let Some(peer) = PEER.get() else { return 0 };
    runtime().block_on(forward_local(peer.clone(), remote_port, 0))
}
