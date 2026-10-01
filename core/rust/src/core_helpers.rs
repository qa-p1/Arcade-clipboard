#[derive(serde::Serialize, serde::Deserialize)]
struct Bootstrap {
    version: u16,
    session_id: Option<String>,
}

fn decode_key_32(value: &str, label: &str) -> Result<Vec<u8>, String> {
    let bytes = crypto::decode(value)?;
    if bytes.len() != 32 {
        return Err(format!("{label} must contain a 32-byte key"));
    }
    Ok(bytes)
}

fn validate_invite(invite: &InviteV1) -> Result<(), String> {
    if let Some(base) = &invite.relay_url {
        crate::relay_transport::validate_relay_url(base)?;
    }
    if invite.version != PROTOCOL_VERSION {
        return Err("Pairing invitation version is unsupported".into());
    }
    for value in [&invite.mesh_id, &invite.session_id, &invite.host_device_id] {
        Uuid::parse_str(value)
            .map_err(|_| "Pairing invitation has an invalid identifier".to_string())?;
    }
    validate_device_name(&invite.host_device_name)?;
    decode_key_32(&invite.host_static_public, "Mesh owner identity")?;
    decode_key_32(&invite.owner_signing_public, "Mesh signing identity")?;
    decode_key_32(&invite.pairing_token, "Pairing authorization")?;
    let address = invite
        .host_address
        .parse::<IpAddr>()
        .map_err(|_| "Pairing invitation has an invalid address".to_string())?;
    if address.is_unspecified() || address.is_multicast() || invite.host_port == 0 {
        return Err("Pairing invitation has an invalid address".into());
    }
    if invite.expires_at
        > store::now_ms().saturating_add((INVITE_TTL_SECONDS * 1000 + 30_000) as i64)
    {
        return Err("Pairing invitation expiry is too far in the future".into());
    }
    Ok(())
}

fn pairing_prologue(mesh_id: &str, session_id: &str) -> Vec<u8> {
    format!("arcade-clipboard:pair:v1:{mesh_id}:{session_id}").into_bytes()
}

fn invitation_prologue(invitation: &InvitationState) -> Vec<u8> {
    pairing_prologue(&invitation.invite.mesh_id, &invitation.invite.session_id)
}

fn reconnect_prologue(mesh_id: &str) -> Vec<u8> {
    format!("arcade-clipboard:sync:v1:{mesh_id}").into_bytes()
}

fn local_capabilities() -> Vec<String> {
    [
        "text/plain",
        "text/uri-list",
        "text/html",
        "image/png",
        "image/jpeg",
        "files-v1",
        "chunks-v1",
        "origin-signatures-v1",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

fn hello_message(
    mesh_id: &str,
    device_id: &str,
    device_name: &str,
    private: &[u8; 32],
    endpoint: &str,
) -> WireMessage {
    let public = x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(*private));
    WireMessage::Hello {
        version: PROTOCOL_VERSION,
        mesh_id: mesh_id.into(),
        device_id: device_id.into(),
        device_name: device_name.into(),
        static_public: crypto::encode(public.as_bytes()),
        item_signing_public: crypto::encode(
            &crypto::item_signing_key(private).verifying_key().to_bytes(),
        ),
        platform: std::env::consts::OS.to_string(),
        capabilities: local_capabilities(),
        endpoint: endpoint.into(),
    }
}

struct PeerHello {
    /// The peer's listening port, so either side can dial the other later.
    endpoint: String,
    mesh_id: String,
    device_id: String,
    device_name: String,
    static_public: Vec<u8>,
    item_signing_public: String,
    platform: String,
    capabilities: Vec<String>,
}

fn hello_fields(message: WireMessage) -> Result<PeerHello, String> {
    let WireMessage::Hello {
        version,
        mesh_id,
        device_id,
        device_name,
        static_public,
        item_signing_public,
        platform,
        capabilities,
        endpoint,
    } = message
    else {
        return Err("Expected an authenticated device identity hello".into());
    };
    if version != PROTOCOL_VERSION {
        return Err("Device protocol version is unsupported".into());
    }
    Uuid::parse_str(&mesh_id).map_err(|_| "Mesh identifier is invalid".to_string())?;
    Uuid::parse_str(&device_id).map_err(|_| "Device identifier is invalid".to_string())?;
    validate_device_name(&device_name)?;
    if platform.len() > 32 || capabilities.len() > 32 || capabilities.iter().any(|c| c.len() > 128)
    {
        return Err("Device capabilities exceed their limit".into());
    }
    if endpoint.len() > MAX_ENDPOINT_BYTES {
        return Err("Device endpoint is too long".into());
    }
    Ok(PeerHello {
        endpoint,
        mesh_id,
        device_id,
        device_name,
        static_public: decode_key_32(&static_public, "Device public identity")?,
        item_signing_public,
        platform,
        capabilities,
    })
}

enum ItemMessages {
    Small(Option<Box<WireMessage>>),
    Chunks {
        bytes: Vec<u8>,
        offset: usize,
        id: String,
    },
}

impl Iterator for ItemMessages {
    type Item = WireMessage;
    fn next(&mut self) -> Option<Self::Item> {
        use base64::Engine;
        match self {
            Self::Small(message) => message.take().map(|message| *message),
            Self::Chunks { bytes, offset, id } => {
                if *offset >= bytes.len() {
                    return None;
                }
                let end = (*offset + 24 * 1024).min(bytes.len());
                let message = WireMessage::ClipboardChunk {
                    id: id.clone(),
                    offset: *offset,
                    total: bytes.len(),
                    data: base64::engine::general_purpose::STANDARD.encode(&bytes[*offset..end]),
                };
                *offset = end;
                Some(message)
            }
        }
    }
}

fn item_messages(item: &WireItem) -> Result<ItemMessages, String> {
    let bytes = crate::payload::encoded_item(item)?;
    if bytes.len() + 128 <= MAX_FRAME_BYTES {
        return Ok(ItemMessages::Small(Some(Box::new(
            WireMessage::ClipboardItem { item: item.clone() },
        ))));
    }
    Ok(ItemMessages::Chunks {
        bytes,
        offset: 0,
        id: item.id.clone(),
    })
}

struct IncomingTransfer {
    bytes: Vec<u8>,
    total: usize,
    deadline: std::time::Instant,
}

impl Core {
    async fn receive_chunk(
        &self,
        peer_id: &str,
        id: String,
        offset: usize,
        total: usize,
        data: String,
    ) -> Result<(), String> {
        use base64::Engine;
        Uuid::parse_str(&id).map_err(|_| "Clipboard transfer identifier is invalid".to_string())?;
        if total == 0 || total > crate::payload::MAX_ITEM_JSON_BYTES || data.len() > 32 * 1024 {
            return Err("Clipboard transfer exceeds its limit".into());
        }
        let chunk = base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|_| "Clipboard transfer chunk is invalid".to_string())?;
        if chunk.is_empty() || chunk.len() > 24 * 1024 {
            return Err("Clipboard transfer chunk exceeds its limit".into());
        }
        let item = {
            let mut transfers = self
                .transfers
                .lock()
                .map_err(|_| "Clipboard transfer state is unavailable".to_string())?;
            transfers.retain(|_, transfer| transfer.deadline > std::time::Instant::now());
            let key = (peer_id.to_string(), id.clone());
            if offset == 0 {
                if transfers.len() >= 8
                    || transfers.keys().filter(|(peer, _)| peer == peer_id).count() >= 2
                {
                    return Err("Too many pending clipboard transfers".into());
                }
                if transfers.contains_key(&key) {
                    return Err("Clipboard transfer was restarted before completion".into());
                }
                transfers.insert(
                    key.clone(),
                    IncomingTransfer {
                        bytes: Vec::new(),
                        total,
                        deadline: std::time::Instant::now() + Duration::from_secs(120),
                    },
                );
            }
            let transfer = transfers
                .get_mut(&key)
                .ok_or_else(|| "Clipboard transfer chunk arrived out of order".to_string())?;
            if total != transfer.total
                || offset != transfer.bytes.len()
                || offset.saturating_add(chunk.len()) > total
            {
                transfers.remove(&key);
                return Err(
                    "Clipboard transfer metadata changed or a chunk arrived out of order".into(),
                );
            }
            transfer.bytes.extend_from_slice(&chunk);
            if transfer.bytes.len() == total {
                let complete = transfers
                    .remove(&key)
                    .ok_or_else(|| "Clipboard transfer disappeared".to_string())?;
                let item: WireItem = serde_json::from_slice(&complete.bytes)
                    .map_err(|_| "Clipboard transfer item is malformed".to_string())?;
                if item.id != id {
                    return Err("Clipboard transfer item identifier changed".into());
                }
                Some(item)
            } else {
                None
            }
        };
        if let Some(item) = item {
            self.receive_item(peer_id, item).await?;
        }
        Ok(())
    }
}

fn same_item(a: &WireItem, b: &WireItem) -> bool {
    serde_json::to_vec(a).ok() == serde_json::to_vec(b).ok()
}

fn same_certificate(a: &SignedMemberCertificate, b: &SignedMemberCertificate) -> bool {
    serde_json::to_vec(a).ok() == serde_json::to_vec(b).ok()
}

async fn send_sync(outbound: &Outbound, message: WireMessage) -> Result<(), String> {
    tokio::time::timeout(Duration::from_secs(15), outbound.send(message))
        .await
        .map_err(|_| "History synchronization timed out".to_string())?
        .map_err(|_| "Device connection closed during history synchronization".to_string())
}

fn discover_host_address() -> IpAddr {
    let Ok(socket) = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)) else {
        return IpAddr::V4(Ipv4Addr::LOCALHOST);
    };
    if socket.connect((Ipv4Addr::new(1, 1, 1, 1), 80)).is_ok() {
        if let Ok(address) = socket.local_addr() {
            return address.ip();
        }
    }
    IpAddr::V4(Ipv4Addr::LOCALHOST)
}

async fn exchange_pairing_approval<S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin>(
    stream: &mut S,
    secure: &mut TransportState,
    mut decision: watch::Receiver<Option<bool>>,
    expires_at: i64,
) -> Result<bool, String> {
    let mut local_approved = false;
    let mut remote_approved = false;
    loop {
        let local = *decision.borrow_and_update();
        if let Some(accepted) = local {
            if !local_approved {
                transport::send_secure(stream, secure, &WireMessage::PairDecision { accepted })
                    .await?;
                if !accepted {
                    return Ok(false);
                }
                local_approved = true;
            }
        }
        if local_approved && remote_approved {
            return Ok(true);
        }
        let remaining = expires_at.saturating_sub(store::now_ms());
        if remaining <= 0 {
            return Ok(false);
        }
        tokio::select! {
            changed = decision.changed(), if !local_approved => {
                if changed.is_err() { return Ok(false); }
            }
            incoming = tokio::time::timeout(Duration::from_millis(remaining as u64), transport::read_secure(stream, secure)), if !remote_approved => {
                match incoming {
                    Ok(Ok(WireMessage::PairDecision { accepted: true })) => remote_approved = true,
                    Ok(Ok(WireMessage::PairDecision { accepted: false })) | Err(_) => return Ok(false),
                    Ok(Err(error)) => return Err(error),
                    _ => return Err("Unexpected message before pairing approval".into()),
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(remaining as u64)) => return Ok(false),
        }
    }
}

trait AsyncPeer: tokio::io::AsyncRead + tokio::io::AsyncWrite + Send + Unpin {}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Send + Unpin> AsyncPeer for T {}
type PeerStream = Box<dyn AsyncPeer>;

impl Core {
    pub(crate) fn install_discovery(&self, daemon: mdns_sd::ServiceDaemon) {
        if let Ok(mut slot) = self.discovery.lock() {
            *slot = Some(daemon);
        }
    }
    pub(crate) fn shutdown_receiver(&self) -> watch::Receiver<bool> {
        self.shutdown_tx.subscribe()
    }
    pub(crate) fn track_discovery(&self, task: JoinHandle<()>) {
        self.track(task);
    }
    pub(crate) async fn discovery_candidates(
        &self,
        id: &str,
        public: &str,
        addresses: Vec<SocketAddr>,
    ) -> bool {
        let valid = {
            let state = self.state.lock().await;
            state.store.devices().is_ok_and(|peers| {
                peers.iter().any(|peer| {
                    peer.device_id == id
                        && !peer.revoked
                        && crypto::encode(&peer.static_public) == public
                })
            })
        };
        if valid {
            if let Ok(mut candidates) = self.candidates.lock() {
                if candidates.get(id) != Some(&addresses) {
                    candidates.insert(id.to_string(), addresses);
                    // A new address (Wi-Fi change, wake) deserves a prompt dial.
                    if let Ok(mut failures) = self.dial_failures.lock() {
                        failures.remove(id);
                    }
                    if let Ok(mut schedule) = self.next_dial.lock() {
                        schedule.remove(id);
                    }
                    self.touch();
                }
            }
        }
        valid
    }
    fn listen_port_text(&self) -> String {
        self.listener_addr
            .lock()
            .ok()
            .and_then(|address| address.map(|address| address.port().to_string()))
            .unwrap_or_default()
    }

    async fn relay_url(&self) -> Option<String> {
        let value = self
            .state
            .lock()
            .await
            .store
            .setting("relay_url", String::new());
        let value = if value.is_empty() {
            std::env::var("ARCADE_RELAY_URL").unwrap_or_default()
        } else {
            value
        };
        if value.is_empty() || crate::relay_transport::validate_relay_url(&value).is_err() {
            None
        } else {
            Some(value)
        }
    }
}

fn relay_capability(
    mesh: &str,
    local_id: &str,
    remote_id: &str,
    private: &[u8; 32],
    remote_public: &[u8],
) -> Result<(String, String), String> {
    let public: [u8; 32] = remote_public
        .try_into()
        .map_err(|_| "Relay peer identity is invalid".to_string())?;
    let shared = x25519_dalek::StaticSecret::from(*private)
        .diffie_hellman(&x25519_dalek::PublicKey::from(public));
    if !shared.was_contributory() {
        return Err("Relay peer identity has an invalid public key".into());
    }
    let (first, second) = if local_id < remote_id {
        (local_id, remote_id)
    } else {
        (remote_id, local_id)
    };
    let context = format!("arcade:relay-context:v1:{mesh}:{first}:{second}");
    let mut material = shared.as_bytes().to_vec();
    material.extend_from_slice(context.as_bytes());
    let route = blake3::derive_key("arcade-clipboard:relay-route:v1", &material)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let token = blake3::derive_key("arcade-clipboard:relay-capability:v1", &material);
    Ok((route, crypto::encode(&token)))
}

async fn authenticate_outgoing(
    core: &Core,
    mut stream: PeerStream,
    peer: &PeerRecord,
) -> Result<(PeerStream, TransportState, Vec<u8>), String> {
    let (mesh_id, private, local_id, name) = {
        let state = core.state.lock().await;
        (
            state
                .mesh_id
                .clone()
                .ok_or_else(|| "Mesh is unavailable".to_string())?,
            state.identity.static_private,
            state.identity.device_id.to_string(),
            state.device_name.clone(),
        )
    };
    transport::send_json(
        &mut stream,
        &Bootstrap {
            version: PROTOCOL_VERSION,
            session_id: None,
        },
    )
    .await?;
    let handshake = crypto::build_handshake(&private, None, &reconnect_prologue(&mesh_id), true)?;
    let (mut secure, remote_static, transcript) =
        transport::noise_handshake(&mut stream, handshake).await?;
    if remote_static != peer.static_public {
        return Err("Device identity did not match its signed membership".into());
    }
    transport::send_secure(
        &mut stream,
        &mut secure,
        &hello_message(
            &mesh_id,
            &local_id,
            &name,
            &private,
            &core.listen_port_text(),
        ),
    )
    .await?;
    let remote = hello_fields(transport::read_secure(&mut stream, &mut secure).await?)?;
    if remote.mesh_id != mesh_id
        || remote.device_id != peer.device_id
        || remote.device_name != peer.device_name
        || remote.static_public != peer.static_public
        || (!peer.certificate.certificate.item_signing_public.is_empty()
            && remote.item_signing_public != peer.certificate.certificate.item_signing_public)
    {
        return Err("Device hello did not match its signed membership".into());
    }
    Ok((stream, secure, transcript))
}

async fn reconnect_peer(core: Arc<Core>, peer: PeerRecord) {
    let (mesh_id, local_id, private) = {
        let state = core.state.lock().await;
        (
            state.mesh_id.clone().unwrap_or_default(),
            state.identity.device_id.to_string(),
            state.identity.static_private,
        )
    };
    let initiator = local_id < peer.device_id;
    let mut candidates = core
        .candidates
        .lock()
        .ok()
        .and_then(|all| all.get(&peer.device_id).cloned())
        .unwrap_or_default();
    if let Ok(endpoint) = peer.endpoint.parse::<SocketAddr>() {
        if !candidates.contains(&endpoint) {
            candidates.push(endpoint);
        }
    }
    #[cfg(test)]
    let direct_allowed = core.direct_disabled.load(Ordering::SeqCst) == 0;
    #[cfg(not(test))]
    let direct_allowed = true;
    // Either device may dial: a firewall or a missing discovery record on one
    // side must not prevent the pair from reconnecting.
    if direct_allowed {
        for address in candidates.into_iter().take(8) {
            let direct = async {
                let stream = TcpStream::connect(address)
                    .await
                    .map_err(|_| "LAN device is unreachable".to_string())?;
                let _ = stream.set_nodelay(true);
                authenticate_outgoing(&core, Box::new(stream), &peer).await
            };
            if let Ok(Ok((stream, secure, transcript))) =
                tokio::time::timeout(Duration::from_secs(2), direct).await
            {
                let _ = core
                    .state
                    .lock()
                    .await
                    .store
                    .set_endpoint(&peer.device_id, &address.to_string());
                if let Ok(mut dialing) = core.dialing.lock() {
                    dialing.remove(&peer.device_id);
                }
                transport::start_peer(
                    core.clone(),
                    peer.device_id.clone(),
                    stream,
                    secure,
                    "lan",
                    transcript,
                )
                .await;
                return;
            }
        }
    }
    if !core.connection_is_missing(&peer.device_id) {
        return;
    }
    if let Some(base) = core.relay_url().await {
        if let Ok((route, token)) = relay_capability(
            &mesh_id,
            &local_id,
            &peer.device_id,
            &private,
            &peer.static_public,
        ) {
            let slot = if initiator { "a" } else { "b" };
            if let Ok(Ok(stream)) = tokio::time::timeout(
                Duration::from_secs(15),
                crate::relay_transport::connect(&base, &route, &token, Some(slot)),
            )
            .await
            {
                if initiator {
                    if let Ok(Ok((stream, secure, transcript))) = tokio::time::timeout(
                        HANDSHAKE_TIMEOUT,
                        authenticate_outgoing(&core, Box::new(stream), &peer),
                    )
                    .await
                    {
                        if let Ok(mut dialing) = core.dialing.lock() {
                            dialing.remove(&peer.device_id);
                        }
                        transport::start_peer(
                            core.clone(),
                            peer.device_id.clone(),
                            stream,
                            secure,
                            "relay",
                            transcript,
                        )
                        .await;
                    }
                } else {
                    if let Ok(mut dialing) = core.dialing.lock() {
                        dialing.remove(&peer.device_id);
                    }
                    handle_incoming(
                        core.clone(),
                        Box::new(stream),
                        SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                    )
                    .await;
                }
            }
        }
    }
}

async fn reconnect_loop(core: Arc<Core>) {
    let mut shutdown = core.shutdown_tx.subscribe();
    let mut changes = core.revision_tx.subscribe();
    let mut delay = Duration::ZERO;
    loop {
        tokio::select! {
            _ = shutdown.changed() => break,
            _ = tokio::time::sleep(delay) => {},
            _ = changes.changed() => {},
        }
        if *shutdown.borrow() {
            break;
        }
        changes.borrow_and_update();
        delay = Duration::from_secs(30);
        let listener_missing = core
            .listener_addr
            .lock()
            .map(|address| address.is_none())
            .unwrap_or(false);
        if listener_missing && core.start_listener().await.is_err() {
            delay = Duration::from_secs(5);
        }
        let peers = {
            let state = core.state.lock().await;
            let local_id = state.identity.device_id.to_string();
            let Ok(peers) = state.store.devices() else {
                continue;
            };
            if peers.iter().any(|p| p.device_id == local_id && p.revoked) {
                break;
            }
            peers
                .into_iter()
                .filter(|p| p.device_id != local_id && !p.revoked)
                .collect::<Vec<_>>()
        };
        for peer in peers {
            let route = core
                .connections
                .lock()
                .ok()
                .and_then(|connections| connections.get(&peer.device_id).map(|c| c.route));
            if route == Some("lan") {
                continue;
            }
            if route.is_none() {
                delay = Duration::from_secs(2);
            }
            let local_id = core.state.lock().await.identity.device_id.to_string();
            if route == Some("relay") && local_id > peer.device_id {
                continue;
            }
            if let Ok(mut schedule) = core.next_dial.lock() {
                if schedule
                    .get(&peer.device_id)
                    .is_some_and(|next| *next > std::time::Instant::now())
                {
                    continue;
                }
                let failures = core
                    .dial_failures
                    .lock()
                    .map(|mut failures| {
                        let count = failures.entry(peer.device_id.clone()).or_insert(0);
                        *count = count.saturating_add(1);
                        *count
                    })
                    .unwrap_or(1);
                // 2, 4, 8 ... 60 seconds while a device stays unreachable;
                // discovery updates and successful connections reset it.
                let backoff = if route == Some("relay") {
                    30
                } else {
                    (1u64 << failures.min(5)).min(60)
                };
                schedule.insert(
                    peer.device_id.clone(),
                    std::time::Instant::now() + Duration::from_secs(backoff),
                );
            }
            let Ok(mut dialing) = core.dialing.lock() else {
                continue;
            };
            if !dialing.insert(peer.device_id.clone()) {
                continue;
            }
            drop(dialing);
            let peer_core = core.clone();
            let peer_id = peer.device_id.clone();
            core.track(tokio::spawn(async move {
                reconnect_peer(peer_core.clone(), peer).await;
                if let Ok(mut dialing) = peer_core.dialing.lock() {
                    dialing.remove(&peer_id);
                }
            }));
        }
    }
}

#[cfg(test)]
impl Core {
    pub(crate) fn test_force_relay(&self) {
        self.direct_disabled.store(1, Ordering::SeqCst);
        if let Ok(mut discovery) = self.discovery.lock() {
            if let Some(daemon) = discovery.take() {
                let _ = daemon.shutdown();
            }
        }
        if let Ok(mut candidates) = self.candidates.lock() {
            candidates.clear();
        }
        if let Ok(mut connections) = self.connections.lock() {
            for (_, connection) in connections.drain() {
                connection.cancel.send_replace(true);
            }
        }
        self.touch();
    }
}

#[cfg(test)]
mod relay_route_tests {
    use super::*;
    #[test]
    fn relay_routes_are_pairwise_secret_and_symmetric() {
        let a = IdentityMaterial::generate().unwrap();
        let b = IdentityMaterial::generate().unwrap();
        let mesh = Uuid::new_v4().to_string();
        let ids = (a.device_id.to_string(), b.device_id.to_string());
        let first =
            relay_capability(&mesh, &ids.0, &ids.1, &a.static_private, &b.static_public).unwrap();
        let second =
            relay_capability(&mesh, &ids.1, &ids.0, &b.static_private, &a.static_public).unwrap();
        assert_eq!(first, second);
        let public_guess =
            blake3::hash(format!("arcade:relay-route:v1:{mesh}:{}:{}", ids.0, ids.1).as_bytes())
                .to_hex()
                .to_string();
        assert_ne!(first.0, public_guess);
        let attacker = IdentityMaterial::generate().unwrap();
        let attacker_guess = relay_capability(
            &mesh,
            &ids.0,
            &ids.1,
            &attacker.static_private,
            &b.static_public,
        )
        .unwrap();
        assert_ne!(first.0, attacker_guess.0);
        assert_ne!(first.1, attacker_guess.1);
    }
}
