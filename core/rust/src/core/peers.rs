//! Connections to peers: the listener, the hello handshake, reconnect and dialling, discovery
//! and the relay route.

use super::*;

impl Core {
    pub(super) async fn start_listener(self: &Arc<Self>) -> Result<(), String> {
        if self
            .listener_addr
            .lock()
            .map_err(|_| "Mesh listener state is unavailable")?
            .is_some()
        {
            return Ok(());
        }
        let port = {
            let state = self.state.lock().await;
            state
                .store
                .meta("listen_port")?
                .and_then(|p| p.parse::<u16>().ok())
                .unwrap_or(0)
        };
        let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::UNSPECIFIED, port)))
            .await
            .map_err(|e| format!("Could not open the mesh owner listener: {e}"))?;
        let local_addr = listener
            .local_addr()
            .map_err(|e| format!("Could not inspect the mesh listener: {e}"))?;
        {
            let mut state = self.state.lock().await;
            state
                .store
                .set_meta("listen_port", &local_addr.port().to_string())?;
            state.diagnostic.clear();
        }
        *self
            .listener_addr
            .lock()
            .map_err(|_| "Mesh listener state is unavailable")? = Some(local_addr);
        let core = self.clone();
        let mut shutdown = self.shutdown_tx.subscribe();
        self.track(tokio::spawn(async move {
            let mut failures = 0u32;
            loop {
                tokio::select! {
                    changed = shutdown.changed() => {
                        if changed.is_err() || *shutdown.borrow() { break; }
                    }
                    accepted = listener.accept() => {
                        let Ok((stream, remote_addr)) = accepted else {
                            // iOS reclaims the sockets of suspended apps; a
                            // defunct listener fails every accept immediately.
                            // Back off, then drop it so it is bound again.
                            failures += 1;
                            if failures >= 8 {
                                if let Ok(mut address) = core.listener_addr.lock() {
                                    *address = None;
                                }
                                core.touch();
                                break;
                            }
                            tokio::time::sleep(Duration::from_millis(250)).await;
                            continue;
                        };
                        failures = 0;
                        let Ok(permit) = core.handshakes.clone().try_acquire_owned() else { continue; };
                        let handler_core = core.clone();
                        let tracked_core = handler_core.clone();
                        tracked_core.track(tokio::spawn(async move {
                            let _permit = permit;
                            let _ = stream.set_nodelay(true);
                            handle_incoming(handler_core, Box::new(stream), remote_addr).await;
                        }));
                    }
                }
            }
        }));
        #[cfg(not(target_os = "ios"))]
        let discovery_config = {
            let state = self.state.lock().await;
            (
                state.mesh_id.clone().unwrap_or_default(),
                state.identity.device_id.to_string(),
                crypto::encode(&state.identity.static_public),
            )
        };
        // A rebound listener reuses its persisted port, so an existing
        // announcement stays valid and is not started twice.
        #[cfg(not(target_os = "ios"))]
        let discovery_stopped = self.discovery.lock().is_ok_and(|slot| slot.is_none());
        #[cfg(not(target_os = "ios"))]
        if discovery_stopped {
            if let Err(error) = crate::discovery::start(
                self,
                &discovery_config.0,
                &discovery_config.1,
                &discovery_config.2,
                local_addr.port(),
            )
            .await
            {
                self.state.lock().await.diagnostic = error;
            }
        }
        self.touch();
        Ok(())
    }

    pub(super) fn start_member_connector(self: &Arc<Self>) {
        if self
            .connector_started
            .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return;
        }
        let core = self.clone();
        self.track(tokio::spawn(async move {
            reconnect_loop(core).await;
        }));
    }

    pub(super) fn close_connection(&self, peer_id: &str) {
        if let Ok(mut connections) = self.connections.lock() {
            if let Some(connection) = connections.remove(peer_id) {
                connection.cancel.send_replace(true);
            }
        }
    }

    pub(super) async fn authorize_reconnect(
        &self,
        peer_id: &str,
        peer_name: &str,
        peer_static: &[u8],
        hello_mesh: &str,
        _remote_addr: SocketAddr,
    ) -> Result<(), String> {
        let state = self.state.lock().await;
        let local_id = state.identity.device_id.to_string();
        let mesh_id = state
            .mesh_id
            .clone()
            .ok_or_else(|| "Mesh is unavailable".to_string())?;
        if hello_mesh != mesh_id {
            return Err("Reconnect identity is not valid for this mesh".into());
        }
        if peer_id == local_id {
            return Err("A device cannot connect to itself".into());
        }
        let owner_public = state
            .owner_signing_public
            .clone()
            .ok_or_else(|| "Mesh signing identity is missing".to_string())?;
        let peer = state
            .store
            .devices()?
            .into_iter()
            .find(|peer| peer.device_id == peer_id && !peer.revoked)
            .ok_or_else(|| "Device has not been approved by this mesh".to_string())?;
        if peer.static_public != peer_static || peer.device_name != peer_name {
            return Err("Reconnect identity does not match its approved membership".into());
        }
        crypto::verify_member(&owner_public, &peer.certificate)?;
        let cert = &peer.certificate.certificate;
        if cert.mesh_id != mesh_id
            || cert.device_id != peer_id
            || cert.device_name != peer_name
            || decode_key_32(&cert.static_public, "Device public identity")? != peer_static
        {
            return Err("Reconnect identity does not match its signed membership".into());
        }
        state.store.mark_seen(peer_id)?;
        drop(state);
        self.touch();
        Ok(())
    }

    pub(super) fn connection_is_missing(&self, peer_id: &str) -> bool {
        self.connections
            .lock()
            .map(|connections| !connections.contains_key(peer_id))
            .unwrap_or(true)
    }

    /// The app returned to the foreground after the OS may have suspended it:
    /// sockets can be silently dead. Reconnect now instead of waiting for
    /// heartbeats to time out, and rebind the listener if it was reclaimed.
    pub async fn resume(self: &Arc<Self>) {
        if let Ok(mut connections) = self.connections.lock() {
            for (_, connection) in connections.drain() {
                connection.cancel.send_replace(true);
            }
        }
        if let Ok(mut schedule) = self.next_dial.lock() {
            schedule.clear();
        }
        if let Ok(mut failures) = self.dial_failures.lock() {
            failures.clear();
        }
        let _ = self.start().await;
        self.touch();
    }

    pub async fn register_connection(
        &self,
        peer_id: String,
        outbound: Outbound,
        cancel: watch::Sender<bool>,
        route: &'static str,
        session: Vec<u8>,
    ) -> Result<u64, String> {
        let state = self.state.lock().await;
        let local_id = state.identity.device_id.to_string();
        let owner_id = state
            .owner_device_id
            .as_deref()
            .ok_or_else(|| "Mesh owner identity is missing".to_string())?;
        let peer = state
            .store
            .devices()?
            .into_iter()
            .find(|peer| peer.device_id == peer_id && !peer.revoked)
            .ok_or_else(|| {
                "Device was revoked before its connection could be registered".to_string()
            })?;
        if peer_id == local_id
            || state
                .store
                .devices()?
                .iter()
                .any(|p| p.device_id == local_id && p.revoked)
        {
            return Err("Revoked or local device cannot register a connection".into());
        }
        let _ = (owner_id, peer);
        let generation = self.next_generation.fetch_add(1, Ordering::SeqCst);
        if let Ok(mut connections) = self.connections.lock() {
            if let Some(existing) = connections.get(&peer_id) {
                if existing.registered_at.elapsed() < DUPLICATE_DIAL_WINDOW
                    && existing.session < session
                {
                    return Err("A simultaneous connection to this device is already active".into());
                }
            }
            if let Some(previous) = connections.remove(&peer_id) {
                previous.cancel.send_replace(true);
            }
            connections.insert(
                peer_id.clone(),
                LiveConnection {
                    generation,
                    outbound,
                    cancel,
                    route,
                    session,
                    registered_at: std::time::Instant::now(),
                },
            );
        }
        if let Ok(mut failures) = self.dial_failures.lock() {
            failures.remove(&peer_id);
        }
        drop(state);
        self.touch();
        Ok(generation)
    }

    pub fn unregister_connection(&self, peer_id: &str, generation: u64) {
        if let Ok(mut transfers) = self.transfers.lock() {
            transfers.retain(|(sender, _), _| sender != peer_id);
        }
        if let Ok(mut connections) = self.connections.lock() {
            if connections
                .get(peer_id)
                .is_some_and(|entry| entry.generation == generation)
            {
                connections.remove(peer_id);
                if let Ok(mut schedule) = self.next_dial.lock() {
                    schedule.remove(peer_id);
                }
            }
        }
        self.touch();
    }
}

pub(super) enum IncomingAction {
    Pair {
        invitation: Box<InvitationState>,
        peer: Box<PeerHello>,
        transcript: Vec<u8>,
        secure: TransportState,
    },
    Reconnect {
        peer_id: String,
        secure: TransportState,
        transcript: Vec<u8>,
    },
}

pub(super) async fn handle_incoming(
    core: Arc<Core>,
    mut stream: PeerStream,
    remote_addr: SocketAddr,
) {
    let mut reserved_invite: Option<String> = None;
    let outcome: Result<IncomingAction, String> = async {
        let bootstrap: Bootstrap =
            tokio::time::timeout(HANDSHAKE_TIMEOUT, transport::read_json(&mut stream))
                .await
                .map_err(|_| "Secure device prelude timed out".to_string())??;
        if bootstrap.version != PROTOCOL_VERSION {
            return Err("Device protocol version is not supported".into());
        }
        if bootstrap
            .session_id
            .as_deref()
            .is_some_and(|session| Uuid::parse_str(session).is_err())
        {
            return Err("Pairing session identifier is invalid".into());
        }
        let invitation = if let Some(session_id) = bootstrap.session_id.as_deref() {
            let reserved = core.reserve_invitation(session_id)?;
            reserved_invite = Some(session_id.to_string());
            Some(reserved)
        } else {
            None
        };
        let (mesh_id, private_key, local_id, owner_public) = {
            let state = core.state.lock().await;
            let local_id = state.identity.device_id.to_string();
            if invitation.is_some() && state.owner_device_id.as_deref() != Some(local_id.as_str()) {
                return Err("Only the mesh owner can approve pairing".into());
            }
            (
                state
                    .mesh_id
                    .clone()
                    .ok_or_else(|| "Mesh is unavailable".to_string())?,
                state.identity.static_private,
                local_id,
                state
                    .owner_signing_public
                    .clone()
                    .ok_or_else(|| "Mesh signing identity is unavailable".to_string())?,
            )
        };
        let (psk, prologue) = if let Some(invitation) = invitation.as_ref() {
            (Some(invitation.psk), invitation_prologue(invitation))
        } else {
            (None, reconnect_prologue(&mesh_id))
        };
        let handshake = crypto::build_handshake(&private_key, psk.as_ref(), &prologue, false)?;
        let (mut secure, peer_static, transcript) = tokio::time::timeout(
            HANDSHAKE_TIMEOUT,
            transport::noise_handshake(&mut stream, handshake),
        )
        .await
        .map_err(|_| "Secure device handshake timed out".to_string())??;
        let message = tokio::time::timeout(
            HANDSHAKE_TIMEOUT,
            transport::read_secure(&mut stream, &mut secure),
        )
        .await
        .map_err(|_| "Secure device identity hello timed out".to_string())??;
        let peer = hello_fields(message)?;
        if peer.static_public != peer_static {
            return Err("Noise identity did not match the authenticated device hello".into());
        }
        if peer.mesh_id != mesh_id {
            return Err("Device belongs to a different mesh".into());
        }
        if peer.device_id == local_id {
            return Err("A device cannot connect to itself".into());
        }
        if let Some(invitation) = invitation {
            if invitation.invite.mesh_id != mesh_id
                || invitation.invite.host_device_id != local_id
                || crypto::decode(&invitation.invite.host_static_public)? != {
                    let state = core.state.lock().await;
                    state.identity.static_public.to_vec()
                }
                || crypto::decode(&invitation.invite.owner_signing_public)? != owner_public
            {
                return Err("Pairing invitation does not match this mesh owner".into());
            }
            let peer_list = { core.state.lock().await.store.devices()? };
            if peer_list.iter().any(|p| {
                p.device_id == peer.device_id
                    && (p.revoked || p.static_public != peer.static_public)
            }) {
                return Err("This device identity cannot be paired again".into());
            }
            Ok(IncomingAction::Pair {
                invitation: Box::new(invitation),
                peer: Box::new(peer),
                transcript,
                secure,
            })
        } else {
            core.authorize_reconnect(
                &peer.device_id,
                &peer.device_name,
                &peer.static_public,
                &peer.mesh_id,
                remote_addr,
            )
            .await?;
            if remote_addr.port() != 0 {
                if let Ok(port) = peer.endpoint.parse::<u16>() {
                    if port != 0 {
                        let endpoint = SocketAddr::new(remote_addr.ip(), port).to_string();
                        let _ = core
                            .state
                            .lock()
                            .await
                            .store
                            .set_endpoint(&peer.device_id, &endpoint);
                    }
                }
            }
            let name = core.state.lock().await.device_name.clone();
            transport::send_secure(
                &mut stream,
                &mut secure,
                &hello_message(
                    &mesh_id,
                    &local_id,
                    &name,
                    &private_key,
                    &core.listen_port_text(),
                ),
            )
            .await?;
            Ok(IncomingAction::Reconnect {
                peer_id: peer.device_id,
                secure,
                transcript,
            })
        }
    }
    .await;

    match outcome {
        Ok(IncomingAction::Reconnect {
            peer_id,
            secure,
            transcript,
        }) => {
            transport::start_peer(
                core,
                peer_id,
                stream,
                secure,
                if remote_addr.port() == 0 {
                    "relay"
                } else {
                    "lan"
                },
                transcript,
            )
            .await;
        }
        Ok(IncomingAction::Pair {
            invitation,
            peer,
            transcript,
            secure,
        }) => {
            let session_id = invitation.invite.session_id.clone();
            let info = PendingPairingInfo {
                session_id: session_id.clone(),
                peer_name: peer.device_name.clone(),
                verification_code: crypto::verification_code(&transcript),
                expires_at: invitation.invite.expires_at,
                direction: "inbound".into(),
                state: "awaiting_confirmation".into(),
            };
            let (decision_tx, decision_rx) = watch::channel(None);
            let registered = if let Ok(mut pairings) = core.pairings.lock() {
                pairings.insert(
                    session_id.clone(),
                    PairingState {
                        info,
                        decision: decision_tx,
                    },
                );
                true
            } else {
                false
            };
            if registered {
                core.touch();
                let result = run_owner_pair(
                    core.clone(),
                    stream,
                    (secure, transcript),
                    *invitation,
                    *peer,
                    remote_addr,
                    decision_rx,
                )
                .await;
                if result.is_err() {
                    remove_pairing(&core, &session_id);
                }
                core.finish_invitation(&session_id, false);
            } else {
                core.finish_invitation(&session_id, false);
            }
        }
        Err(_) => {
            if let Some(session_id) = reserved_invite.as_deref() {
                core.finish_invitation(session_id, false);
            }
        }
    }
}

pub(super) fn reconnect_prologue(mesh_id: &str) -> Vec<u8> {
    format!("arcade-clipboard:sync:v1:{mesh_id}").into_bytes()
}

pub(super) fn local_capabilities() -> Vec<String> {
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

/// The first encrypted message on a connection: which pairing session, if any, it belongs to.
#[derive(serde::Serialize, serde::Deserialize)]
pub(super) struct Bootstrap {
    pub(super) version: u16,
    pub(super) session_id: Option<String>,
}

pub(super) fn hello_message(
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

pub(super) struct PeerHello {
    /// The peer's listening port, so either side can dial the other later.
    pub(super) endpoint: String,
    pub(super) mesh_id: String,
    pub(super) device_id: String,
    pub(super) device_name: String,
    pub(super) static_public: Vec<u8>,
    pub(super) item_signing_public: String,
    pub(super) platform: String,
    pub(super) capabilities: Vec<String>,
}

pub(super) fn hello_fields(message: WireMessage) -> Result<PeerHello, String> {
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

pub(super) fn discover_host_address() -> IpAddr {
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

pub(super) trait AsyncPeer:
    tokio::io::AsyncRead + tokio::io::AsyncWrite + Send + Unpin
{
}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Send + Unpin> AsyncPeer for T {}
pub(super) type PeerStream = Box<dyn AsyncPeer>;

// The iPhone host browses with Bonjour and reports candidates instead of
// running the mDNS daemon, so these hooks exist only on other platforms.
#[cfg(not(target_os = "ios"))]
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
}

impl Core {
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
    pub(super) fn listen_port_text(&self) -> String {
        self.listener_addr
            .lock()
            .ok()
            .and_then(|address| address.map(|address| address.port().to_string()))
            .unwrap_or_default()
    }

    pub(super) async fn relay_url(&self) -> Option<String> {
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

pub(super) fn relay_capability(
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

pub(super) async fn authenticate_outgoing(
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

pub(super) async fn reconnect_peer(core: Arc<Core>, peer: PeerRecord) {
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

pub(super) async fn reconnect_loop(core: Arc<Core>) {
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
                    (1u64 << failures.min(6)).min(60)
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
