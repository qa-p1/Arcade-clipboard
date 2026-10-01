//! Opaque rendezvous and byte transport for Arcade Clipboard.
//!
//! The relay does not identify devices, interpret frames, persist payloads, or
//! possess clipboard decryption keys. Device authentication and end-to-end
//! encryption are provided by the clients' Noise session.

use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use axum::{
    Router,
    extract::{
        ConnectInfo, Path, Query, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::{
    net::TcpListener,
    sync::{Mutex, mpsc, oneshot},
    time::timeout_at,
};
use tracing::info;

pub const MAX_FRAME_BYTES: usize = 64 * 1024;
pub const RENDEZVOUS_TTL: Duration = Duration::from_secs(120);
const MAX_PENDING_ROUTES: usize = 512;
const MAX_CONNECTIONS: usize = 512;
const MAX_CONNECTIONS_PER_IP: usize = 16;
const MAX_UPGRADES_PER_MINUTE_PER_IP: u32 = 120;
const MAX_TRACKED_IPS: usize = 8_192;
const UPGRADE_WINDOW: Duration = Duration::from_secs(60);
const FORWARD_QUEUE_FRAMES: usize = 2;
const MAX_PAIRED_ROUTES: usize = 4_096;
const PAIRED_ROUTE_RETENTION: Duration = Duration::from_secs(10 * 60);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Health {
    pub status: &'static str,
    pub protocol: &'static str,
    pub max_frame_bytes: usize,
}

#[derive(Clone)]
pub struct RelayState {
    inner: Arc<Inner>,
}

struct Inner {
    broker: Mutex<Broker>,
    limits: Mutex<Limits>,
    next_generation: AtomicU64,
    max_connections_per_ip: usize,
}

#[derive(Default)]
struct Broker {
    invites: HashMap<String, InviteEntry>,
    paired: HashMap<String, PairedEntry>,
}

struct InviteEntry {
    ticket_hash: [u8; 32],
    deadline: Instant,
    generation: u64,
    first: Option<oneshot::Sender<Link>>,
    paired: bool,
}

struct PairedEntry {
    token_hash: [u8; 32],
    last_used: Instant,
    active: Option<ActivePair>,
}

struct ActivePair {
    generation: u64,
    deadline: Instant,
    first_slot: Slot,
    first: Option<oneshot::Sender<Link>>,
    paired: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Slot {
    A,
    B,
}

impl Slot {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "a" => Some(Self::A),
            "b" => Some(Self::B),
            _ => None,
        }
    }
}

struct Limits {
    active_total: usize,
    per_ip: HashMap<IpAddr, usize>,
    attempts: HashMap<IpAddr, AttemptWindow>,
}

struct AttemptWindow {
    started: Instant,
    count: u32,
}

struct Link {
    incoming: mpsc::Receiver<axum::body::Bytes>,
    outgoing: mpsc::Sender<axum::body::Bytes>,
}

enum Attach {
    Waiting {
        generation: u64,
        receiver: oneshot::Receiver<Link>,
        deadline: Instant,
    },
    Paired {
        generation: u64,
        link: Link,
    },
}

#[derive(Debug, PartialEq, Eq)]
enum AttachError {
    InvalidRoute,
    Full,
    Expired,
    Unauthorized,
    DuplicateSlot,
}

#[derive(Debug, Deserialize)]
struct TicketQuery {
    token: String,
    #[serde(default)]
    ready: Option<u8>,
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    error: &'static str,
}

impl RelayState {
    pub fn new() -> Self {
        Self::with_max_connections_per_ip(MAX_CONNECTIONS_PER_IP)
            .expect("default connection limit is valid")
    }

    pub fn with_max_connections_per_ip(limit: usize) -> Result<Self, String> {
        if !(1..=MAX_CONNECTIONS).contains(&limit) {
            return Err("Relay per-IP connection limit must be between 1 and 512".into());
        }
        Ok(Self {
            inner: Arc::new(Inner {
                broker: Mutex::new(Broker::default()),
                limits: Mutex::new(Limits {
                    active_total: 0,
                    per_ip: HashMap::new(),
                    attempts: HashMap::new(),
                }),
                next_generation: AtomicU64::new(1),
                max_connections_per_ip: limit,
            }),
        })
    }

    fn next_generation(&self) -> u64 {
        self.inner.next_generation.fetch_add(1, Ordering::Relaxed)
    }

    async fn authorize_connection(&self, ip: IpAddr) -> Result<(), StatusCode> {
        let mut limits = self.inner.limits.lock().await;
        let now = Instant::now();
        limits
            .attempts
            .retain(|_, value| now.duration_since(value.started) < UPGRADE_WINDOW);
        if !limits.attempts.contains_key(&ip) && limits.attempts.len() >= MAX_TRACKED_IPS {
            return Err(StatusCode::TOO_MANY_REQUESTS);
        }
        let entry = limits.attempts.entry(ip).or_insert(AttemptWindow {
            started: now,
            count: 0,
        });
        if now.duration_since(entry.started) >= UPGRADE_WINDOW {
            entry.started = now;
            entry.count = 0;
        }
        entry.count = entry.count.saturating_add(1);
        if entry.count > MAX_UPGRADES_PER_MINUTE_PER_IP {
            return Err(StatusCode::TOO_MANY_REQUESTS);
        }
        if limits.active_total >= MAX_CONNECTIONS
            || limits.per_ip.get(&ip).copied().unwrap_or(0) >= self.inner.max_connections_per_ip
        {
            return Err(StatusCode::TOO_MANY_REQUESTS);
        }
        limits.active_total += 1;
        *limits.per_ip.entry(ip).or_default() += 1;
        Ok(())
    }

    async fn release_connection(&self, ip: IpAddr) {
        let mut limits = self.inner.limits.lock().await;
        limits.active_total = limits.active_total.saturating_sub(1);
        if let Some(active) = limits.per_ip.get_mut(&ip) {
            *active = active.saturating_sub(1);
            if *active == 0 {
                limits.per_ip.remove(&ip);
            }
        }
    }

    async fn attach_invite(
        &self,
        route_id: &str,
        token_hash: [u8; 32],
    ) -> Result<Attach, AttachError> {
        validate_route_id(route_id)?;
        let mut broker = self.inner.broker.lock().await;
        let now = Instant::now();
        broker
            .invites
            .retain(|_, entry| entry.paired || entry.deadline > now);
        if let Some(entry) = broker.invites.get_mut(route_id) {
            if entry.ticket_hash != token_hash {
                return Err(AttachError::Unauthorized);
            }
            if entry.deadline <= now {
                broker.invites.remove(route_id);
                return Err(AttachError::Expired);
            }
            if entry.paired {
                return Err(AttachError::Full);
            }
            let generation = entry.generation;
            let first = entry.first.take().ok_or(AttachError::Full)?;
            entry.paired = true;
            let (to_first, from_first) = mpsc::channel(FORWARD_QUEUE_FRAMES);
            let (to_second, from_second) = mpsc::channel(FORWARD_QUEUE_FRAMES);
            let first_link = Link {
                incoming: from_first,
                outgoing: to_second,
            };
            let second_link = Link {
                incoming: from_second,
                outgoing: to_first,
            };
            if first.send(first_link).is_err() {
                broker.invites.remove(route_id);
                return Err(AttachError::Expired);
            }
            return Ok(Attach::Paired {
                generation,
                link: second_link,
            });
        }
        if broker.invites.len() >= MAX_PENDING_ROUTES {
            return Err(AttachError::Full);
        }
        let generation = self.next_generation();
        let deadline = now + RENDEZVOUS_TTL;
        let (sender, receiver) = oneshot::channel();
        broker.invites.insert(
            route_id.to_owned(),
            InviteEntry {
                ticket_hash: token_hash,
                deadline,
                generation,
                first: Some(sender),
                paired: false,
            },
        );
        Ok(Attach::Waiting {
            generation,
            receiver,
            deadline,
        })
    }

    async fn attach_paired(
        &self,
        route_id: &str,
        token_hash: [u8; 32],
        slot: Slot,
    ) -> Result<Attach, AttachError> {
        validate_route_id(route_id)?;
        let mut broker = self.inner.broker.lock().await;
        let now = Instant::now();
        broker.paired.retain(|_, entry| {
            entry.active.is_some() || now.duration_since(entry.last_used) < PAIRED_ROUTE_RETENTION
        });

        if !broker.paired.contains_key(route_id) {
            if broker.paired.len() >= MAX_PAIRED_ROUTES {
                let oldest_idle = broker
                    .paired
                    .iter()
                    .filter(|(_, entry)| entry.active.is_none())
                    .min_by_key(|(_, entry)| entry.last_used)
                    .map(|(route, _)| route.clone());
                if let Some(route) = oldest_idle {
                    broker.paired.remove(&route);
                } else {
                    return Err(AttachError::Full);
                }
            }
            broker.paired.insert(
                route_id.to_owned(),
                PairedEntry {
                    token_hash,
                    last_used: now,
                    active: None,
                },
            );
        }

        let entry = broker.paired.get_mut(route_id).expect("entry was inserted");
        if entry.token_hash != token_hash {
            return Err(AttachError::Unauthorized);
        }
        entry.last_used = now;

        if let Some(active) = entry.active.as_mut() {
            if active.paired {
                return Err(AttachError::DuplicateSlot);
            }
            if active.first_slot == slot {
                return Err(AttachError::DuplicateSlot);
            }
            if active.deadline <= now {
                entry.active = None;
            } else {
                let generation = active.generation;
                let first = active.first.take().ok_or(AttachError::DuplicateSlot)?;
                active.paired = true;
                let (to_first, from_first) = mpsc::channel(FORWARD_QUEUE_FRAMES);
                let (to_second, from_second) = mpsc::channel(FORWARD_QUEUE_FRAMES);
                let first_link = Link {
                    incoming: from_first,
                    outgoing: to_second,
                };
                let second_link = Link {
                    incoming: from_second,
                    outgoing: to_first,
                };
                if first.send(first_link).is_err() {
                    entry.active = None;
                    return Err(AttachError::Expired);
                }
                return Ok(Attach::Paired {
                    generation,
                    link: second_link,
                });
            }
        }

        let generation = self.next_generation();
        let deadline = now + RENDEZVOUS_TTL;
        let (sender, receiver) = oneshot::channel();
        entry.active = Some(ActivePair {
            generation,
            deadline,
            first_slot: slot,
            first: Some(sender),
            paired: false,
        });
        Ok(Attach::Waiting {
            generation,
            receiver,
            deadline,
        })
    }

    async fn detach(&self, route: &str, generation: u64, paired_route: bool) {
        let mut broker = self.inner.broker.lock().await;
        if paired_route {
            if let Some(entry) = broker.paired.get_mut(route) {
                if entry
                    .active
                    .as_ref()
                    .is_some_and(|active| active.generation == generation)
                {
                    entry.active = None;
                    entry.last_used = Instant::now();
                }
            }
        } else if broker
            .invites
            .get(route)
            .is_some_and(|entry| entry.generation == generation)
        {
            broker.invites.remove(route);
        }
    }
}

impl Default for RelayState {
    fn default() -> Self {
        Self::new()
    }
}

pub fn app(state: RelayState) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/v1/relay/{route_id}", get(invite_relay))
        .route("/v1/relay/paired/{route_id}/{slot}", get(paired_relay))
        .with_state(state)
}

pub async fn serve(listener: TcpListener, state: RelayState) -> std::io::Result<()> {
    axum::serve(
        listener,
        app(state).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await
}

async fn health() -> axum::Json<Health> {
    axum::Json(Health {
        status: "ok",
        protocol: "v1",
        max_frame_bytes: MAX_FRAME_BYTES,
    })
}

async fn invite_relay(
    State(state): State<RelayState>,
    ConnectInfo(remote): ConnectInfo<SocketAddr>,
    Path(route_id): Path<String>,
    Query(query): Query<TicketQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    relay_upgrade(
        state,
        remote.ip(),
        route_id,
        query.token,
        RelayKind::Invite,
        query.ready == Some(1),
        ws,
    )
    .await
}

async fn paired_relay(
    State(state): State<RelayState>,
    ConnectInfo(remote): ConnectInfo<SocketAddr>,
    Path((route_id, slot)): Path<(String, String)>,
    Query(query): Query<TicketQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let Some(slot) = Slot::parse(&slot) else {
        return error(StatusCode::BAD_REQUEST, "invalid relay slot");
    };
    relay_upgrade(
        state,
        remote.ip(),
        route_id,
        query.token,
        RelayKind::Paired(slot),
        query.ready == Some(1),
        ws,
    )
    .await
}

#[derive(Clone, Copy)]
enum RelayKind {
    Invite,
    Paired(Slot),
}

async fn relay_upgrade(
    state: RelayState,
    ip: IpAddr,
    route_id: String,
    token: String,
    kind: RelayKind,
    notify_ready: bool,
    ws: WebSocketUpgrade,
) -> Response {
    if let Err(status) = state.authorize_connection(ip).await {
        return error(status, "relay connection limit reached");
    }
    if validate_route_id(&route_id).is_err() {
        state.release_connection(ip).await;
        return error(StatusCode::BAD_REQUEST, "invalid relay route");
    }
    let Ok(ticket) = decode_ticket(&token) else {
        state.release_connection(ip).await;
        return error(StatusCode::UNAUTHORIZED, "invalid relay ticket");
    };
    let token_hash: [u8; 32] = Sha256::digest(ticket).into();
    let attach = match kind {
        RelayKind::Invite => state.attach_invite(&route_id, token_hash).await,
        RelayKind::Paired(slot) => state.attach_paired(&route_id, token_hash, slot).await,
    };
    let attach = match attach {
        Ok(attach) => attach,
        Err(err) => {
            state.release_connection(ip).await;
            return match err {
                AttachError::InvalidRoute => error(StatusCode::BAD_REQUEST, "invalid relay route"),
                AttachError::Full => error(StatusCode::TOO_MANY_REQUESTS, "relay is at capacity"),
                AttachError::Expired => error(StatusCode::GONE, "relay invitation expired"),
                AttachError::Unauthorized => {
                    error(StatusCode::UNAUTHORIZED, "invalid relay ticket")
                }
                AttachError::DuplicateSlot => error(
                    StatusCode::CONFLICT,
                    "relay route slot is already connected",
                ),
            };
        }
    };
    let paired_route = matches!(kind, RelayKind::Paired(_));
    let generation = match &attach {
        Attach::Waiting { generation, .. } | Attach::Paired { generation, .. } => *generation,
    };
    let route_label = route_id;
    let failed_state = state.clone();
    let failed_route = route_label.clone();
    ws.max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .max_write_buffer_size(256 * 1024)
        .on_failed_upgrade(move |_error| {
            // `on_upgrade` may fail before a WebSocket exists. Release the
            // bounded connection reservation and remove its rendezvous slot.
            tokio::spawn(async move {
                failed_state
                    .detach(&failed_route, generation, paired_route)
                    .await;
                failed_state.release_connection(ip).await;
            });
        })
        .on_upgrade(move |socket| async move {
            handle_attached(
                state,
                route_label,
                ip,
                attach,
                paired_route,
                notify_ready,
                socket,
            )
            .await;
        })
}

async fn handle_attached(
    state: RelayState,
    route_id: String,
    ip: IpAddr,
    attach: Attach,
    paired_route: bool,
    notify_ready: bool,
    socket: WebSocket,
) {
    let (generation, link) = match attach {
        Attach::Paired { generation, link } => (generation, Some((socket, link))),
        Attach::Waiting {
            generation,
            mut receiver,
            deadline,
        } => (
            generation,
            wait_for_peer(socket, &mut receiver, deadline).await,
        ),
    };

    if let Some((mut socket, link)) = link {
        if !notify_ready
            || socket
                .send(Message::Text("arcade-ready-v1".into()))
                .await
                .is_ok()
        {
            forward_socket(socket, link).await;
        }
    }
    state.detach(&route_id, generation, paired_route).await;
    state.release_connection(ip).await;
}

async fn wait_for_peer(
    mut socket: WebSocket,
    receiver: &mut oneshot::Receiver<Link>,
    deadline: Instant,
) -> Option<(WebSocket, Link)> {
    loop {
        tokio::select! {
            link = timeout_at(deadline.into(), &mut *receiver) => {
                match link {
                    Ok(Ok(link)) => return Some((socket, link)),
                    _ => {
                        close_socket(&mut socket, axum::extract::ws::close_code::POLICY, "rendezvous timed out").await;
                        return None;
                    }
                }
            }
            message = socket.recv() => {
                match message {
                    Some(Ok(Message::Ping(payload))) => {
                        if socket.send(Message::Pong(payload)).await.is_err() {
                            return None;
                        }
                    }
                    Some(Ok(Message::Pong(_))) => {}
                    Some(Ok(Message::Binary(_))) => {
                        close_socket(&mut socket, axum::extract::ws::close_code::UNSUPPORTED, "wait for the second peer before sending data").await;
                        return None;
                    }
                    Some(Ok(Message::Text(_))) => {
                        close_socket(&mut socket, axum::extract::ws::close_code::UNSUPPORTED, "binary frames required").await;
                        return None;
                    }
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return None,
                }
            }
        }
    }
}

enum SocketControl {
    Pong(axum::body::Bytes),
    Close {
        code: Option<u16>,
        reason: Option<String>,
        acknowledged: oneshot::Sender<()>,
    },
}

async fn forward_socket(socket: WebSocket, link: Link) {
    let (sink, stream) = socket.split();
    let (control_tx, control_rx) = mpsc::channel(4);
    let reader = read_from_socket(stream, link.outgoing, control_tx);
    let writer = write_to_socket(sink, link.incoming, control_rx);
    tokio::pin!(reader);
    tokio::pin!(writer);
    tokio::select! {
        _ = &mut reader => {},
        _ = &mut writer => {},
    }
}

async fn read_from_socket(
    mut stream: impl futures_util::Stream<Item = Result<Message, axum::Error>> + Unpin,
    outgoing: mpsc::Sender<axum::body::Bytes>,
    controls: mpsc::Sender<SocketControl>,
) {
    while let Some(message) = stream.next().await {
        match message {
            Ok(Message::Binary(payload)) if payload.len() <= MAX_FRAME_BYTES => {
                // Awaiting capacity propagates backpressure. This reader is
                // separate from the writer so a full outbound queue cannot
                // block receiving traffic in the reverse direction.
                if outgoing.send(payload).await.is_err() {
                    request_close(&controls, None, None).await;
                    return;
                }
            }
            Ok(Message::Binary(_)) => {
                request_close(
                    &controls,
                    Some(axum::extract::ws::close_code::SIZE),
                    Some("frame too large".to_owned()),
                )
                .await;
                return;
            }
            Ok(Message::Ping(payload)) => {
                if controls.send(SocketControl::Pong(payload)).await.is_err() {
                    return;
                }
            }
            Ok(Message::Pong(_)) => {}
            Ok(Message::Text(_)) => {
                request_close(
                    &controls,
                    Some(axum::extract::ws::close_code::UNSUPPORTED),
                    Some("binary frames required".to_owned()),
                )
                .await;
                return;
            }
            Ok(Message::Close(_)) | Err(_) => {
                request_close(&controls, None, None).await;
                return;
            }
        }
    }
    request_close(&controls, None, None).await;
}

async fn request_close(
    controls: &mpsc::Sender<SocketControl>,
    code: Option<u16>,
    reason: Option<String>,
) {
    let (sender, receiver) = oneshot::channel();
    if controls
        .send(SocketControl::Close {
            code,
            reason,
            acknowledged: sender,
        })
        .await
        .is_ok()
    {
        let _ = receiver.await;
    }
}

async fn write_to_socket(
    mut sink: impl futures_util::Sink<Message, Error = axum::Error> + Unpin,
    mut incoming: mpsc::Receiver<axum::body::Bytes>,
    mut controls: mpsc::Receiver<SocketControl>,
) {
    loop {
        tokio::select! {
            control = controls.recv() => {
                match control {
                    Some(SocketControl::Pong(payload)) => {
                        if sink.send(Message::Pong(payload)).await.is_err() {
                            return;
                        }
                    }
                    Some(SocketControl::Close { code, reason, acknowledged }) => {
                        let frame = code.map(|code| axum::extract::ws::CloseFrame {
                            code,
                            reason: reason.unwrap_or_default().into(),
                        });
                        let _ = sink.send(Message::Close(frame)).await;
                        let _ = acknowledged.send(());
                        return;
                    }
                    None => return,
                }
            }
            payload = incoming.recv() => {
                match payload {
                    Some(payload) => {
                        if sink.send(Message::Binary(payload)).await.is_err() {
                            return;
                        }
                    }
                    None => {
                        let _ = sink.send(Message::Close(None)).await;
                        return;
                    }
                }
            }
        }
    }
}

async fn close_socket(socket: &mut WebSocket, code: u16, reason: &'static str) {
    let _ = socket
        .send(Message::Close(Some(axum::extract::ws::CloseFrame {
            code,
            reason: reason.into(),
        })))
        .await;
}

fn validate_route_id(route: &str) -> Result<(), AttachError> {
    if (16..=80).contains(&route.len())
        && route
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        Ok(())
    } else {
        Err(AttachError::InvalidRoute)
    }
}

fn decode_ticket(value: &str) -> Result<[u8; 32], ()> {
    if value.len() != 43 {
        return Err(());
    }
    let bytes = URL_SAFE_NO_PAD.decode(value).map_err(|_| ())?;
    bytes.try_into().map_err(|_| ())
}

fn error(status: StatusCode, message: &'static str) -> Response {
    (status, axum::Json(ErrorBody { error: message })).into_response()
}

/// Run periodic cleanup for stale invitation state and expired paired-route records.
/// Active paired sessions are never expired while traffic is idle; the clients own
/// reconnect policy and the relay never acknowledges or queues a payload offline.
pub async fn cleanup_loop(state: RelayState) {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    loop {
        interval.tick().await;
        let now = Instant::now();
        let mut broker = state.inner.broker.lock().await;
        broker
            .invites
            .retain(|_, entry| entry.paired || entry.deadline > now);
        broker.paired.retain(|_, entry| {
            entry.active.is_some() || now.duration_since(entry.last_used) < PAIRED_ROUTE_RETENTION
        });
    }
}

/// Bind and run the service using `ARCADE_RELAY_BIND`, defaulting to loopback.
pub async fn run_from_env() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let bind = std::env::var("ARCADE_RELAY_BIND").unwrap_or_else(|_| "127.0.0.1:8787".to_owned());
    let listener = TcpListener::bind(&bind).await?;
    let max_per_ip = std::env::var("ARCADE_RELAY_MAX_CONNECTIONS_PER_IP")
        .ok()
        .map(|raw| raw.parse::<usize>())
        .transpose()?
        .unwrap_or(MAX_CONNECTIONS_PER_IP);
    let state = RelayState::with_max_connections_per_ip(max_per_ip)?;
    let cleanup_state = state.clone();
    tokio::spawn(cleanup_loop(cleanup_state));
    info!(bind = %bind, "Arcade Clipboard relay listening; TLS must terminate at a trusted reverse proxy for public deployment");
    serve(listener, state).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_32_byte_unpadded_base64url_tokens_are_accepted() {
        let good = URL_SAFE_NO_PAD.encode([7_u8; 32]);
        assert_eq!(decode_ticket(&good).unwrap(), [7_u8; 32]);
        assert!(decode_ticket("short").is_err());
        assert!(decode_ticket(&URL_SAFE_NO_PAD.encode([7_u8; 31])).is_err());
        assert!(decode_ticket("+/not-url-safe").is_err());
    }

    #[test]
    fn route_ids_are_bounded_and_url_safe() {
        assert!(validate_route_id("0123456789abcdef").is_ok());
        assert!(validate_route_id("short").is_err());
        assert!(validate_route_id("0123456789abcde/").is_err());
        assert!(validate_route_id(&"a".repeat(81)).is_err());
    }

    #[tokio::test]
    async fn invite_rendezvous_requires_matching_ticket_and_allows_only_two_sockets() {
        let state = RelayState::new();
        let route = "0123456789abcdef";
        let secret = [11_u8; 32];
        let digest: [u8; 32] = Sha256::digest(secret).into();
        let first = state.attach_invite(route, digest).await.unwrap();
        assert!(matches!(first, Attach::Waiting { .. }));
        assert!(matches!(
            state.attach_invite(route, [0; 32]).await,
            Err(AttachError::Unauthorized)
        ));
        assert!(matches!(
            state.attach_invite(route, digest).await.unwrap(),
            Attach::Paired { .. }
        ));
        assert!(matches!(
            state.attach_invite(route, digest).await,
            Err(AttachError::Full)
        ));
    }

    #[tokio::test]
    async fn paired_route_reuses_same_ticket_but_rejects_duplicate_peer_slot() {
        let state = RelayState::new();
        let route = "fedcba9876543210";
        let digest = [22_u8; 32];
        let first = state.attach_paired(route, digest, Slot::A).await.unwrap();
        assert!(matches!(first, Attach::Waiting { .. }));
        assert!(matches!(
            state.attach_paired(route, digest, Slot::A).await,
            Err(AttachError::DuplicateSlot)
        ));
        assert!(matches!(
            state.attach_paired(route, digest, Slot::B).await.unwrap(),
            Attach::Paired { .. }
        ));
        assert!(matches!(
            state.attach_paired(route, digest, Slot::B).await,
            Err(AttachError::DuplicateSlot)
        ));
    }

    #[tokio::test]
    async fn bad_token_does_not_claim_paired_route() {
        let state = RelayState::new();
        let route = "fedcba9876543210";
        assert!(matches!(
            state.attach_paired(route, [1; 32], Slot::A).await.unwrap(),
            Attach::Waiting { .. }
        ));
        assert!(matches!(
            state.attach_paired(route, [2; 32], Slot::B).await,
            Err(AttachError::Unauthorized)
        ));
    }

    #[tokio::test]
    async fn connection_caps_are_released_after_disconnect() {
        let state = RelayState::new();
        let ip = IpAddr::V4(std::net::Ipv4Addr::LOCALHOST);
        state.authorize_connection(ip).await.unwrap();
        state.release_connection(ip).await;
        let limits = state.inner.limits.lock().await;
        assert_eq!(limits.active_total, 0);
        assert_eq!(limits.per_ip.get(&ip), None);
    }
}
