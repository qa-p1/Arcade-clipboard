use crate::{
    crypto,
    model::{
        DeviceInfo, HistoryItem, InviteV1, MemberCertificate, PeerRecord, PendingPairingInfo,
        Revocation, SignedMemberCertificate, SignedPinState, SignedRevocation, Status, WireItem,
        WireMessage, DEFAULT_MAX_ITEMS, DEFAULT_RETENTION_HOURS, INVITE_TTL_SECONDS,
        MAX_FRAME_BYTES, PROTOCOL_VERSION,
    },
    profile_lock::ProfileLock,
    secret::{IdentityMaterial, SecretStore, SystemSecretStore},
    store::{self, Store},
    transport::{self, Outbound},
};
use ed25519_dalek::SigningKey;
use rand::{rngs::OsRng, RngCore};
use snow::TransportState;
use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex as StdMutex,
    },
    time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{watch, Mutex, Semaphore},
    task::JoinHandle,
};
use uuid::Uuid;

const MAX_DEVICE_NAME_BYTES: usize = 128;
const MAX_ENDPOINT_BYTES: usize = 256;
const MAX_PEERS: usize = 128;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(12);
const POLL_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone)]
struct InvitationState {
    invite: InviteV1,
    psk: [u8; 32],
    in_flight: bool,
    consumed: bool,
}

struct PairingState {
    info: PendingPairingInfo,
    decision: watch::Sender<Option<bool>>,
}

struct LiveConnection {
    generation: u64,
    outbound: Outbound,
    cancel: watch::Sender<bool>,
    route: &'static str,
    /// Noise handshake hash: identical on both ends of one connection, so
    /// both devices can independently agree on which duplicate to keep.
    session: Vec<u8>,
    registered_at: std::time::Instant,
}

/// Both devices dial each other. Duplicates registered within this window
/// resolve to the lower handshake hash on both sides; a connection arriving
/// later always replaces the old one, which may be half-open after sleep.
const DUPLICATE_DIAL_WINDOW: Duration = Duration::from_secs(10);

struct State {
    identity: IdentityMaterial,
    store: Store,
    device_name: String,
    mesh_id: Option<String>,
    owner_device_id: Option<String>,
    owner_signing_public: Option<Vec<u8>>,
    owner_endpoint: Option<String>,
    diagnostic: String,
}

/// Persistent identity, trust, history and the active authority-centered mesh.
/// SQLite and keychain access stays behind short state-lock sections; network
/// waits never hold that lock.
pub struct Core {
    state: Mutex<State>,
    secrets: Arc<dyn SecretStore>,
    invitations: StdMutex<HashMap<String, InvitationState>>,
    pairings: StdMutex<HashMap<String, PairingState>>,
    connections: StdMutex<HashMap<String, LiveConnection>>,
    next_generation: AtomicU64,
    revision: AtomicU64,
    revision_tx: watch::Sender<u64>,
    shutdown_tx: watch::Sender<bool>,
    listener_addr: StdMutex<Option<SocketAddr>>,
    tasks: StdMutex<Vec<JoinHandle<()>>>,
    handshakes: Arc<Semaphore>,
    connector_started: AtomicU64,
    _profile_lock: ProfileLock,
    transfers: StdMutex<HashMap<(String, String), IncomingTransfer>>,
    discovery: StdMutex<Option<mdns_sd::ServiceDaemon>>,
    candidates: StdMutex<HashMap<String, Vec<SocketAddr>>>,
    dialing: StdMutex<std::collections::HashSet<String>>,
    next_dial: StdMutex<HashMap<String, std::time::Instant>>,
    dial_failures: StdMutex<HashMap<String, u32>>,
    #[cfg(test)]
    direct_disabled: AtomicU64,
}

impl Core {
    /// Open the production profile. The system credential store is mandatory;
    /// there is deliberately no plaintext or file-based fallback.
    pub fn open(data_dir: PathBuf, device_name: String) -> Result<Self, String> {
        let secrets = Arc::new(SystemSecretStore::for_data_dir(&data_dir));
        Self::open_with_secret_store(data_dir, device_name, secrets)
    }

    /// Open a profile with an injected secret store. This entry point is useful
    /// for isolated tests; production API calls always use `open` above.
    pub(crate) fn open_with_secret_store(
        data_dir: PathBuf,
        device_name: String,
        secrets: Arc<dyn SecretStore>,
    ) -> Result<Self, String> {
        validate_device_name(&device_name)?;
        std::fs::create_dir_all(&data_dir)
            .map_err(|e| format!("Could not create data folder: {e}"))?;
        let profile_lock = ProfileLock::acquire(&data_dir)?;
        let identity = IdentityMaterial::load_or_create(secrets.as_ref())?;
        let db_path = data_dir.join("history.sqlite");
        let store = Store::open(&db_path, identity.database_key)?;
        let saved_name = store.meta("device_name")?;
        let mesh_id = store.meta("mesh_id")?;
        let owner_device_id = store.meta("owner_device_id")?;
        let owner_signing_public = store.meta("owner_signing_public")?;
        let owner_endpoint = store.meta("owner_endpoint")?;

        let had_saved_name = saved_name.is_some();
        let mut device_name = saved_name.unwrap_or(device_name);
        if mesh_id.is_none() {
            store.set_meta("device_name", &device_name)?;
        } else {
            validate_device_name(&device_name)?;
            let mesh_id_value = mesh_id.as_deref().unwrap_or_default();
            Uuid::parse_str(mesh_id_value).map_err(|_| {
                "Stored mesh identity is invalid; refusing to replace it".to_string()
            })?;
            let owner_id = owner_device_id
                .as_deref()
                .ok_or_else(|| "Stored mesh owner identity is missing".to_string())?;
            Uuid::parse_str(owner_id)
                .map_err(|_| "Stored mesh owner identity is invalid".to_string())?;
            let owner_public = owner_signing_public
                .as_deref()
                .ok_or_else(|| "Stored mesh signing identity is missing".to_string())?;
            let owner_public = crypto::decode(owner_public)?;
            if owner_public.len() != 32 {
                return Err("Stored mesh signing identity is invalid".into());
            }
            let peers = store.devices()?;
            let self_peer = peers
                .iter()
                .find(|peer| peer.device_id == identity.device_id.to_string())
                .ok_or_else(|| "Stored mesh membership is missing for this device".to_string())?;
            if self_peer.static_public != identity.static_public {
                return Err("Stored mesh membership does not match this device identity".into());
            }
            crypto::verify_member(&owner_public, &self_peer.certificate)?;
            if self_peer.certificate.certificate.mesh_id != mesh_id_value
                || self_peer.certificate.certificate.device_name != device_name
            {
                return Err("Stored mesh membership metadata is inconsistent".into());
            }
            let owner_peer = peers
                .iter()
                .find(|peer| peer.device_id == owner_id && peer.owner && !peer.revoked)
                .ok_or_else(|| "Stored mesh owner membership is missing".to_string())?;
            if owner_peer.certificate.certificate.mesh_id != mesh_id_value {
                return Err("Stored mesh owner certificate is inconsistent".into());
            }
            crypto::verify_member(&owner_public, &owner_peer.certificate)?;
            if identity.device_id.to_string() == owner_id {
                let secret = identity
                    .owner_signing_secret
                    .ok_or_else(|| "Secure mesh owner signing identity is missing".to_string())?;
                if SigningKey::from_bytes(&secret)
                    .verifying_key()
                    .to_bytes()
                    .as_slice()
                    != owner_public
                {
                    return Err(
                        "Stored mesh signing identity does not match its secure credential".into(),
                    );
                }
            } else if owner_endpoint.as_deref().unwrap_or_default().is_empty() {
                return Err("Stored mesh owner address is missing".into());
            }
        }

        // Device names are mesh-signed after pairing, so an app preference
        // cannot silently rename a trusted identity at initialization.
        if !had_saved_name && mesh_id.is_some() {
            device_name = device_name.trim().to_string();
        }
        let (revision_tx, _) = watch::channel(1u64);
        let (shutdown_tx, _) = watch::channel(false);
        Ok(Self {
            state: Mutex::new(State {
                identity,
                store,
                device_name,
                mesh_id,
                owner_device_id,
                owner_signing_public: owner_signing_public
                    .map(|value| crypto::decode(&value))
                    .transpose()?,
                owner_endpoint,
                diagnostic: String::new(),
            }),
            secrets,
            invitations: StdMutex::new(HashMap::new()),
            pairings: StdMutex::new(HashMap::new()),
            connections: StdMutex::new(HashMap::new()),
            next_generation: AtomicU64::new(1),
            revision: AtomicU64::new(1),
            revision_tx,
            shutdown_tx,
            listener_addr: StdMutex::new(None),
            tasks: StdMutex::new(Vec::new()),
            handshakes: Arc::new(Semaphore::new(32)),
            connector_started: AtomicU64::new(0),
            _profile_lock: profile_lock,
            transfers: StdMutex::new(HashMap::new()),
            discovery: StdMutex::new(None),
            candidates: StdMutex::new(HashMap::new()),
            dialing: StdMutex::new(std::collections::HashSet::new()),
            next_dial: StdMutex::new(HashMap::new()),
            dial_failures: StdMutex::new(HashMap::new()),
            #[cfg(test)]
            direct_disabled: AtomicU64::new(0),
        })
    }

    pub async fn status(&self) -> Result<Status, String> {
        let state = self.state.lock().await;
        let paused = state.store.setting("paused", false);
        let retention_hours = state
            .store
            .setting("retention_hours", DEFAULT_RETENTION_HOURS);
        let online = !self
            .connections
            .lock()
            .map_err(|_| "Device connection state is unavailable")?
            .is_empty();
        let pending_pairings = self
            .pairings
            .lock()
            .map_err(|_| "Pairing state is unavailable")?
            .values()
            .map(|pairing| pairing.info.clone())
            .collect::<Vec<_>>();
        Ok(Status {
            initialized: true,
            mesh_id: state.mesh_id.clone(),
            device_id: state.identity.device_id.to_string(),
            device_name: state.device_name.clone(),
            paused,
            connection: if online { "online" } else { "offline" }.into(),
            transport: {
                let connections = self
                    .connections
                    .lock()
                    .map_err(|_| "Device connection state is unavailable")?;
                let lan = connections.values().any(|c| c.route == "lan");
                let relay = connections.values().any(|c| c.route == "relay");
                match (lan, relay) {
                    (true, true) => "mixed",
                    (true, false) => "lan",
                    (false, true) => "relay",
                    _ => "offline",
                }
                .to_string()
            },
            diagnostic: state.diagnostic.clone(),
            pending_pairings,
            retention_hours,
            revision: self.revision.load(Ordering::SeqCst),
        })
    }

    /// Start the persistent transport role for this profile. Mesh owners listen
    /// for paired members; members reconnect only to their pinned owner.
    pub async fn start(self: &Arc<Self>) -> Result<(), String> {
        let active = {
            let state = self.state.lock().await;
            state.mesh_id.is_some()
                && !state
                    .store
                    .devices()?
                    .iter()
                    .any(|p| p.device_id == state.identity.device_id.to_string() && p.revoked)
        };
        if !active {
            return Ok(());
        }
        self.start_listener().await?;
        self.start_member_connector();
        Ok(())
    }

    async fn start_listener(self: &Arc<Self>) -> Result<(), String> {
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

    fn start_member_connector(self: &Arc<Self>) {
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

    fn track(&self, task: JoinHandle<()>) {
        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.retain(|existing| !existing.is_finished());
            tasks.push(task);
        }
    }

    fn close_connection(&self, peer_id: &str) {
        if let Ok(mut connections) = self.connections.lock() {
            if let Some(connection) = connections.remove(peer_id) {
                connection.cancel.send_replace(true);
            }
        }
    }

    fn reserve_invitation(&self, session_id: &str) -> Result<InvitationState, String> {
        let mut invitations = self
            .invitations
            .lock()
            .map_err(|_| "Pairing invitation state is unavailable")?;
        let entry = invitations
            .get_mut(session_id)
            .ok_or_else(|| "Pairing invitation is unknown or was already used".to_string())?;
        if entry.consumed || entry.invite.expires_at <= store::now_ms() {
            return Err("Pairing invitation has expired or was already used".into());
        }
        if entry.in_flight {
            return Err("This pairing invitation is already being used".into());
        }
        entry.in_flight = true;
        Ok(entry.clone())
    }

    fn finish_invitation(&self, session_id: &str, committed: bool) {
        if let Ok(mut invitations) = self.invitations.lock() {
            if let Some(entry) = invitations.get_mut(session_id) {
                entry.in_flight = false;
                if committed {
                    entry.consumed = true;
                }
            }
        }
    }

    async fn authorize_reconnect(
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

    async fn send_to_peer(&self, peer_id: &str, message: WireMessage) -> Result<(), String> {
        let live = {
            self.connections
                .lock()
                .map_err(|_| "Device connection state is unavailable")?
                .get(peer_id)
                .map(|entry| (entry.generation, entry.outbound.clone()))
        }
        .ok_or_else(|| "Device is not connected".to_string())?;
        match tokio::time::timeout(Duration::from_secs(15), live.1.send(message)).await {
            Ok(Ok(())) => Ok(()),
            _ => {
                if let Ok(mut connections) = self.connections.lock() {
                    if connections
                        .get(peer_id)
                        .is_some_and(|entry| entry.generation == live.0)
                    {
                        if let Some(connection) = connections.remove(peer_id) {
                            connection.cancel.send_replace(true);
                        }
                    }
                }
                Err("Device connection could not accept the outgoing message".into())
            }
        }
    }

    async fn broadcast(&self, message: WireMessage, exclude: Option<&str>) -> Result<(), String> {
        let active = {
            let state = self.state.lock().await;
            state
                .store
                .devices()?
                .into_iter()
                .filter(|peer| !peer.revoked)
                .map(|peer| peer.device_id)
                .collect::<std::collections::HashSet<_>>()
        };
        let targets = {
            self.connections
                .lock()
                .map_err(|_| "Device connection state is unavailable")?
                .iter()
                .filter(|(id, _)| exclude != Some(id.as_str()) && active.contains(*id))
                .map(|(id, entry)| (id.clone(), entry.generation, entry.outbound.clone()))
                .collect::<Vec<_>>()
        };
        for (peer_id, generation, outbound) in targets {
            let result =
                tokio::time::timeout(Duration::from_secs(15), outbound.send(message.clone())).await;
            if !matches!(result, Ok(Ok(()))) {
                if let Ok(mut connections) = self.connections.lock() {
                    if connections
                        .get(&peer_id)
                        .is_some_and(|entry| entry.generation == generation)
                    {
                        if let Some(connection) = connections.remove(&peer_id) {
                            connection.cancel.send_replace(true);
                        }
                    }
                }
            }
        }
        Ok(())
    }

    async fn broadcast_item(&self, item: WireItem) -> Result<(), String> {
        for message in item_messages(&item)? {
            self.broadcast(message, None).await?;
        }
        // Offline capture is durable; reconnect catch-up delivers it.
        Ok(())
    }

    fn connection_is_missing(&self, peer_id: &str) -> bool {
        self.connections
            .lock()
            .map(|connections| !connections.contains_key(peer_id))
            .unwrap_or(true)
    }

    async fn membership_snapshot(
        &self,
    ) -> Result<(Vec<SignedMemberCertificate>, Vec<SignedRevocation>), String> {
        let state = self.state.lock().await;
        let certificates = state
            .store
            .devices()?
            .into_iter()
            .filter(|peer| !peer.revoked)
            .map(|peer| peer.certificate)
            .collect::<Vec<_>>();
        let owner_public = state
            .owner_signing_public
            .clone()
            .ok_or_else(|| "Mesh signing identity is unavailable".to_string())?;
        let revocations = state
            .store
            .revocations()?
            .into_iter()
            .map(|(device_id, revoked_at, epoch, signature)| {
                let mesh_id = state
                    .mesh_id
                    .clone()
                    .ok_or_else(|| "Mesh is unavailable".to_string())?;
                let signed = SignedRevocation {
                    revocation: Revocation {
                        version: PROTOCOL_VERSION,
                        mesh_id,
                        device_id,
                        revoked_at,
                        epoch,
                    },
                    signature,
                };
                crypto::verify_revocation(&owner_public, &signed)?;
                Ok(signed)
            })
            .collect::<Result<Vec<_>, String>>()?;
        let msg = WireMessage::MembershipSnapshot {
            certificates: certificates.clone(),
            revocations: revocations.clone(),
        };
        if serde_json::to_vec(&msg)
            .map_err(|_| "Could not encode mesh membership".to_string())?
            .len()
            + 16
            > MAX_FRAME_BYTES
        {
            return Err("Mesh membership is too large to send in one protocol frame".into());
        }
        Ok((certificates, revocations))
    }

    async fn sync_peer_impl(&self, peer_id: &str, generation: u64) -> Result<(), String> {
        let (outbound, ids, deleted) = {
            let mut state = self.state.lock().await;
            let peers = state.store.devices()?;
            if !peers.iter().any(|p| p.device_id == peer_id && !p.revoked) {
                return Err("Device was revoked before history synchronization".into());
            }
            let outbound = self
                .connections
                .lock()
                .map_err(|_| "Device connection state is unavailable")?
                .get(peer_id)
                .filter(|c| c.generation == generation)
                .map(|c| c.outbound.clone())
                .ok_or_else(|| "Device connection was replaced before history sync".to_string())?;
            let local_id = state.identity.device_id.to_string();
            if peers.iter().any(|p| p.device_id == local_id && p.revoked) {
                return Err("This device has been removed from the mesh".into());
            }
            let ids = state.store.active_item_ids(10_000)?;
            (outbound, ids, state.store.deleted_ids()?)
        };
        let (certificates, revocations) = self.membership_snapshot().await?;
        send_sync(
            &outbound,
            WireMessage::MembershipSnapshot {
                certificates,
                revocations,
            },
        )
        .await?;
        let pins = {
            let state = self.state.lock().await;
            let peers = state.store.devices()?;
            let mut pins = Vec::new();
            for pin in state.store.pin_states()? {
                if let Some(actor) = peers
                    .iter()
                    .find(|peer| peer.device_id == pin.actor_device && !peer.revoked)
                {
                    crypto::verify_pin(&actor.certificate.certificate.item_signing_public, &pin)?;
                    pins.push(pin);
                }
            }
            pins
        };
        for state in pins {
            send_sync(&outbound, WireMessage::PinUpdate { state }).await?;
        }
        for id in deleted {
            send_sync(&outbound, WireMessage::DeleteItem { id }).await?;
        }
        for id in ids {
            let item = {
                let state = self.state.lock().await;
                let peers = state.store.devices()?;
                if !peers
                    .iter()
                    .any(|peer| peer.device_id == peer_id && !peer.revoked)
                {
                    return Err("Device was revoked during history synchronization".into());
                }
                let local_id = state.identity.device_id.to_string();
                state.store.item(&id)?.filter(|item| {
                    peers
                        .iter()
                        .any(|peer| peer.device_id == item.origin_device && !peer.revoked)
                        && (item.origin_device == local_id || !item.origin_signature.is_empty())
                })
            };
            if let Some(item) = item {
                for message in item_messages(&item)? {
                    send_sync(&outbound, message).await?;
                }
            }
        }
        Ok(())
    }

    async fn receive_item(&self, sender_id: &str, item: WireItem) -> Result<(), String> {
        let (_owner, forwarded, inserted) = {
            let mut state = self.state.lock().await;
            let local_id = state.identity.device_id.to_string();
            let owner_id = state
                .owner_device_id
                .clone()
                .ok_or_else(|| "Mesh owner identity is missing".to_string())?;
            let owner = owner_id == local_id;
            let peers = state.store.devices()?;
            if !peers.iter().any(|p| p.device_id == sender_id && !p.revoked) {
                return Err(
                    "Clipboard item came from a device that is not a current mesh member".into(),
                );
            }
            if peers.iter().any(|p| p.device_id == local_id && p.revoked) {
                return Err("This device has been removed from the mesh".into());
            }
            let origin_is_active = peers
                .iter()
                .any(|peer| peer.device_id == item.origin_device && !peer.revoked);
            if !origin_is_active {
                return Err("Clipboard item origin is not an active mesh member".into());
            }
            let origin = peers
                .iter()
                .find(|peer| peer.device_id == item.origin_device)
                .ok_or_else(|| "Clipboard item origin certificate is unavailable".to_string())?;
            if origin.device_name != item.source_name {
                return Err(
                    "Clipboard source name does not match its signed device membership".into(),
                );
            }
            let origin_public = &origin.certificate.certificate.item_signing_public;
            if !origin_public.is_empty() {
                crypto::verify_item(origin_public, &item)?;
            } else if item.origin_device != sender_id {
                return Err(
                    "Older clipboard entries can only synchronize directly from their origin"
                        .into(),
                );
            }
            let existing = state.store.item(&item.id)?;
            let max_items = state.store.setting("max_items", DEFAULT_MAX_ITEMS);
            let new_item = state.store.capture(&item, max_items)?;
            state.store.mark_seen(sender_id)?;
            let forwarded = new_item;
            if !new_item && existing.as_ref().is_some_and(|old| !same_item(old, &item)) {
                return Err("A duplicate clipboard item changed its authenticated metadata".into());
            }
            (owner, forwarded, new_item)
        };
        if inserted {
            self.touch();
        }
        if forwarded {
            for message in item_messages(&item)? {
                self.broadcast(message, Some(sender_id)).await?;
            }
        }
        Ok(())
    }

    async fn receive_delete(&self, sender_id: &str, id: &str) -> Result<(), String> {
        Uuid::parse_str(id).map_err(|_| "Clipboard item ID must be a valid UUID".to_string())?;
        let (changed, owner_id) = {
            let state = self.state.lock().await;
            let local_id = state.identity.device_id.to_string();
            let owner_id = state
                .owner_device_id
                .clone()
                .ok_or_else(|| "Mesh owner identity is missing".to_string())?;
            let _ = local_id;
            let peer = state
                .store
                .devices()?
                .into_iter()
                .find(|peer| peer.device_id == sender_id && !peer.revoked)
                .ok_or_else(|| {
                    "Deletion came from a device that is not a current mesh member".to_string()
                })?;
            let _ = peer;
            state.store.mark_seen(sender_id)?;
            let changed = state.store.delete_item(id)?;
            (changed, owner_id)
        };
        self.touch();
        if changed {
            self.broadcast(
                WireMessage::DeleteItem { id: id.to_string() },
                Some(sender_id),
            )
            .await?;
        }
        let _ = owner_id;
        Ok(())
    }

    async fn receive_membership(
        &self,
        sender_id: &str,
        certificates: Vec<SignedMemberCertificate>,
        revocations: Vec<SignedRevocation>,
    ) -> Result<(), String> {
        let mut close_ids = Vec::new();
        {
            let mut state = self.state.lock().await;
            let local_id = state.identity.device_id.to_string();
            let owner_id = state
                .owner_device_id
                .clone()
                .ok_or_else(|| "Mesh owner identity is missing".to_string())?;
            if owner_id == local_id {
                return Ok(());
            }
            if !state
                .store
                .devices()?
                .iter()
                .any(|p| p.device_id == sender_id && !p.revoked)
            {
                return Err("Membership update sender is not trusted".into());
            }
            let mesh_id = state
                .mesh_id
                .clone()
                .ok_or_else(|| "Mesh is unavailable".to_string())?;
            let owner_public = state
                .owner_signing_public
                .clone()
                .ok_or_else(|| "Mesh signing identity is missing".to_string())?;
            let pinned_owner_static = state
                .store
                .meta("owner_static_public")?
                .ok_or_else(|| "Pinned mesh owner identity is missing".to_string())?;
            let pinned_owner_static = crypto::decode(&pinned_owner_static)?;
            if certificates.len() > MAX_PEERS {
                return Err("Mesh membership exceeds the device limit".into());
            }
            let mut revoked_ids = state
                .store
                .revocations()?
                .into_iter()
                .map(|r| r.0)
                .collect::<std::collections::HashSet<_>>();
            for signed in &revocations {
                crypto::verify_revocation(&owner_public, signed)?;
                if signed.revocation.mesh_id != mesh_id || signed.revocation.device_id == owner_id {
                    return Err("Mesh revocation metadata is inconsistent".into());
                }
                state.store.revoke(
                    &signed.revocation.device_id,
                    signed.revocation.revoked_at,
                    signed.revocation.epoch,
                    &signed.signature,
                )?;
                revoked_ids.insert(signed.revocation.device_id.clone());
                close_ids.push(signed.revocation.device_id.clone());
            }
            let mut owner_cert_seen = false;
            let mut _self_cert_seen = false;
            for signed in &certificates {
                crypto::verify_member(&owner_public, signed)?;
                let cert = &signed.certificate;
                if cert.mesh_id != mesh_id {
                    return Err("Mesh membership belongs to a different mesh".into());
                }
                Uuid::parse_str(&cert.device_id)
                    .map_err(|_| "Device membership has an invalid identifier".to_string())?;
                validate_device_name(&cert.device_name)?;
                let public = decode_key_32(&cert.static_public, "Device public identity")?;
                if cert.device_id == owner_id {
                    owner_cert_seen = public == pinned_owner_static;
                    if !owner_cert_seen {
                        return Err("Mesh owner identity changed unexpectedly".into());
                    }
                }
                if cert.device_id == local_id {
                    _self_cert_seen = true;
                }
                if revoked_ids.contains(&cert.device_id) {
                    continue;
                }
                let peer = PeerRecord {
                    device_id: cert.device_id.clone(),
                    device_name: cert.device_name.clone(),
                    static_public: public,
                    endpoint: state
                        .store
                        .devices()?
                        .into_iter()
                        .find(|p| p.device_id == cert.device_id)
                        .map(|p| p.endpoint)
                        .unwrap_or_default(),
                    certificate: signed.clone(),
                    last_seen: state
                        .store
                        .devices()?
                        .into_iter()
                        .find(|p| p.device_id == cert.device_id)
                        .map(|p| p.last_seen)
                        .unwrap_or(0),
                    revoked: false,
                    owner: cert.device_id == owner_id,
                };
                state.store.add_device(&peer)?;
            }
            if !owner_cert_seen {
                return Err("Mesh owner certificate is missing from the membership update".into());
            }
            if revoked_ids.contains(&local_id) {
                state.diagnostic = "This device is no longer an active mesh member".into();
                close_ids.extend(
                    self.connections
                        .lock()
                        .map_err(|_| "Device connection state is unavailable")?
                        .keys()
                        .cloned(),
                );
            }
            state.store.mark_seen(sender_id)?;
        }
        for id in close_ids {
            self.close_connection(&id);
        }
        self.touch();
        Ok(())
    }

    pub async fn create_mesh(self: &Arc<Self>, device_name: &str) -> Result<(), String> {
        validate_device_name(device_name)?;
        {
            let mut state = self.state.lock().await;
            if state.mesh_id.is_some() {
                if state.owner_device_id.as_deref()
                    == Some(state.identity.device_id.to_string().as_str())
                {
                    return Ok(());
                }
                return Err("This device already belongs to another mesh".into());
            }
            let signing = match state.identity.owner_signing_secret {
                Some(secret) => SigningKey::from_bytes(&secret),
                None => {
                    let signing = crypto::generate_owner_signing_key();
                    state.identity.owner_signing_secret = Some(signing.to_bytes());
                    state.identity.save(self.secrets.as_ref())?;
                    signing
                }
            };
            let mesh_id = Uuid::new_v4().to_string();
            let device_id = state.identity.device_id.to_string();
            let cert = MemberCertificate {
                version: PROTOCOL_VERSION,
                mesh_id: mesh_id.clone(),
                device_id: device_id.clone(),
                device_name: device_name.trim().to_string(),
                static_public: crypto::encode(&state.identity.static_public),
                issued_at: store::now_ms(),
                item_signing_public: crypto::encode(
                    &crypto::item_signing_key(&state.identity.static_private)
                        .verifying_key()
                        .to_bytes(),
                ),
                platform: std::env::consts::OS.to_string(),
                capabilities: local_capabilities(),
            };
            let signed = crypto::sign_member(&signing, cert)?;
            let peer = PeerRecord {
                device_id: device_id.clone(),
                device_name: device_name.trim().to_string(),
                static_public: state.identity.static_public.to_vec(),
                endpoint: String::new(),
                certificate: signed,
                last_seen: store::now_ms(),
                revoked: false,
                owner: true,
            };
            let signing_public = crypto::encode(&signing.verifying_key().to_bytes());
            let static_public = crypto::encode(&state.identity.static_public);
            state.store.install_mesh(
                &[
                    ("mesh_id", &mesh_id),
                    ("owner_device_id", &device_id),
                    ("owner_signing_public", &signing_public),
                    ("owner_static_public", &static_public),
                    ("device_name", device_name.trim()),
                    ("listen_port", "0"),
                ],
                &[peer],
            )?;
            state.mesh_id = Some(mesh_id);
            state.owner_device_id = Some(device_id);
            state.owner_signing_public = Some(signing.verifying_key().to_bytes().to_vec());
            state.device_name = device_name.trim().to_string();
            state.diagnostic.clear();
        }
        self.touch();
        self.start().await
    }

    pub async fn create_invite(self: &Arc<Self>) -> Result<(String, i64), String> {
        self.start_listener().await?;
        let (mesh_id, host_id, name, static_public, signing_public) = {
            let state = self.state.lock().await;
            if state.owner_device_id.as_deref()
                != Some(state.identity.device_id.to_string().as_str())
            {
                return Err("Only the mesh owner can create pairing invitations".into());
            }
            (
                state
                    .mesh_id
                    .clone()
                    .ok_or_else(|| "Create a mesh before inviting a device".to_string())?,
                state.identity.device_id.to_string(),
                state.device_name.clone(),
                state.identity.static_public,
                state
                    .owner_signing_public
                    .clone()
                    .ok_or_else(|| "Mesh signing identity is unavailable".to_string())?,
            )
        };
        let endpoint = self
            .listener_addr
            .lock()
            .map_err(|_| "Mesh listener state is unavailable")?
            .ok_or_else(|| "Mesh listener is not ready".to_string())?;
        let address = discover_host_address().to_string();
        let expires_at = store::now_ms().saturating_add((INVITE_TTL_SECONDS * 1000) as i64);
        let mut psk = [0u8; 32];
        OsRng.fill_bytes(&mut psk);
        let invite = InviteV1 {
            version: PROTOCOL_VERSION,
            mesh_id,
            session_id: Uuid::new_v4().to_string(),
            expires_at,
            host_address: address,
            host_port: endpoint.port(),
            host_device_id: host_id,
            host_device_name: name,
            host_static_public: crypto::encode(&static_public),
            owner_signing_public: crypto::encode(&signing_public),
            pairing_token: crypto::encode(&psk),
            relay_url: self.relay_url().await.filter(|value| !value.is_empty()),
        };
        let encoded = serde_json::to_string(&invite)
            .map_err(|_| "Could not encode pairing invitation".to_string())?;
        let mut invitations = self
            .invitations
            .lock()
            .map_err(|_| "Pairing invitation state is unavailable")?;
        let now = store::now_ms();
        invitations.retain(|_, entry| !entry.consumed && entry.invite.expires_at > now);
        if invitations.len() >= 16 {
            return Err("Too many active invitations; wait for one to expire".into());
        }
        let relay_invite = invite.clone();
        invitations.insert(
            invite.session_id.clone(),
            InvitationState {
                invite,
                psk,
                in_flight: false,
                consumed: false,
            },
        );
        drop(invitations);
        if let Some(base) = relay_invite.relay_url {
            let core = self.clone();
            self.track(tokio::spawn(async move {
                if let Ok(Ok(stream)) = tokio::time::timeout(
                    Duration::from_secs(INVITE_TTL_SECONDS),
                    crate::relay_transport::connect(
                        &base,
                        &relay_invite.session_id,
                        &relay_invite.pairing_token,
                        None,
                    ),
                )
                .await
                {
                    handle_incoming(
                        core,
                        Box::new(stream),
                        SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
                    )
                    .await;
                }
            }));
        }
        Ok((encoded, expires_at))
    }

    pub async fn join(
        self: &Arc<Self>,
        invite_text: &str,
        device_name: &str,
    ) -> Result<PendingPairingInfo, String> {
        validate_device_name(device_name)?;
        if invite_text.len() > 8192 {
            return Err("Pairing invitation is too large".into());
        }
        let invite: InviteV1 = serde_json::from_str(invite_text)
            .map_err(|_| "Pairing invitation is malformed".to_string())?;
        validate_invite(&invite)?;
        if invite.expires_at <= store::now_ms() {
            return Err("Pairing invitation has expired".into());
        }
        let address = SocketAddr::new(
            invite
                .host_address
                .parse::<IpAddr>()
                .map_err(|_| "Pairing invitation has an invalid host address".to_string())?,
            invite.host_port,
        );
        let (private_key, device_id, old_mesh) = {
            let mut state = self.state.lock().await;
            if let Some(mesh) = state.mesh_id.as_ref() {
                return Err(format!("This device already belongs to mesh {mesh}"));
            }
            state.device_name = device_name.trim().to_string();
            state.store.set_meta("device_name", &state.device_name)?;
            (
                state.identity.static_private,
                state.identity.device_id.to_string(),
                state.mesh_id.clone(),
            )
        };
        if old_mesh.is_some() {
            return Err("This device already belongs to a mesh".into());
        }
        let (mut stream, route): (PeerStream, &'static str) = match tokio::time::timeout(
            Duration::from_secs(3),
            TcpStream::connect(address),
        )
        .await
        {
            Ok(Ok(stream)) => {
                stream
                    .set_nodelay(true)
                    .map_err(|_| "Could not configure secure connection".to_string())?;
                (Box::new(stream), "lan")
            }
            _ => {
                let base = invite.relay_url.as_deref().ok_or_else(|| "Could not reach the mesh owner. Connect both devices to the same network, or configure a relay on the owner.".to_string())?;
                (
                    Box::new(
                        tokio::time::timeout(
                            HANDSHAKE_TIMEOUT,
                            crate::relay_transport::connect(
                                base,
                                &invite.session_id,
                                &invite.pairing_token,
                                None,
                            ),
                        )
                        .await
                        .map_err(|_| "Relay pairing connection timed out".to_string())??,
                    ),
                    "relay",
                )
            }
        };
        let psk: [u8; 32] = decode_key_32(&invite.pairing_token, "Pairing authorization")?
            .try_into()
            .map_err(|_| "Invalid pairing authorization")?;
        let bootstrap = Bootstrap {
            version: PROTOCOL_VERSION,
            session_id: Some(invite.session_id.clone()),
        };
        transport::send_json(&mut stream, &bootstrap).await?;
        let prologue = pairing_prologue(&invite.mesh_id, &invite.session_id);
        let handshake = crypto::build_handshake(&private_key, Some(&psk), &prologue, true)?;
        let (mut secure, remote_static, hash) = tokio::time::timeout(
            HANDSHAKE_TIMEOUT,
            transport::noise_handshake(&mut stream, handshake),
        )
        .await
        .map_err(|_| "Secure pairing handshake timed out".to_string())??;
        if remote_static != crypto::decode(&invite.host_static_public)? {
            return Err("The mesh owner identity did not match the pairing invitation".into());
        }
        transport::send_secure(
            &mut stream,
            &mut secure,
            &hello_message(
                &invite.mesh_id,
                &device_id,
                device_name.trim(),
                &private_key,
                "",
            ),
        )
        .await?;
        let info = PendingPairingInfo {
            session_id: invite.session_id.clone(),
            peer_name: invite.host_device_name.clone(),
            verification_code: crypto::verification_code(&hash),
            expires_at: invite.expires_at,
            direction: "outbound".into(),
            state: "awaiting_confirmation".into(),
        };
        let (decision_tx, decision_rx) = watch::channel(None);
        self.pairings
            .lock()
            .map_err(|_| "Pairing state is unavailable")?
            .insert(
                info.session_id.clone(),
                PairingState {
                    info: info.clone(),
                    decision: decision_tx,
                },
            );
        self.touch();
        let core = self.clone();
        let session_id = info.session_id.clone();
        self.track(tokio::spawn(async move {
            run_client_pair(
                core,
                stream,
                (secure, hash),
                invite,
                session_id,
                decision_rx,
                route,
            )
            .await;
        }));
        Ok(info)
    }

    pub async fn confirm_pairing(&self, session_id: &str, accept: bool) -> Result<(), String> {
        let mut pairings = self
            .pairings
            .lock()
            .map_err(|_| "Pairing state is unavailable")?;
        let pairing = pairings
            .get_mut(session_id)
            .ok_or_else(|| "Pairing request is no longer active".to_string())?;
        if pairing.info.expires_at <= store::now_ms() {
            return Err("Pairing request has expired".into());
        }
        if pairing.info.state != "awaiting_confirmation" {
            return Err("Pairing request has already been answered".into());
        }
        pairing.info.state = if accept { "approval_sent" } else { "rejected" }.into();
        pairing.decision.send_replace(Some(accept));
        drop(pairings);
        self.touch();
        Ok(())
    }

    pub async fn capture(
        self: &Arc<Self>,
        id: Option<&str>,
        text: &str,
        kind: Option<&str>,
    ) -> Result<String, String> {
        self.capture_representations(id, text, kind, Vec::new(), false)
            .await
    }

    async fn capture_representations(
        self: &Arc<Self>,
        id: Option<&str>,
        text: &str,
        kind: Option<&str>,
        representations: Vec<crate::payload::Representation>,
        only_if_new: bool,
    ) -> Result<String, String> {
        let kind = kind.unwrap_or_else(|| {
            if text.trim_start().starts_with("https://") || text.trim_start().starts_with("http://")
            {
                "url"
            } else {
                "text"
            }
        });
        crate::payload::validate_payload(text, kind, &representations)?;
        let id = match id {
            Some(value) => Uuid::parse_str(value)
                .map_err(|_| "Clipboard item ID must be a valid UUID".to_string())?
                .to_string(),
            None => Uuid::new_v4().to_string(),
        };
        let content_hash = crate::payload::content_hash(text, &representations);
        let (message, replaced) = {
            let mut state = self.state.lock().await;
            if state.store.setting("paused", false) {
                return Err("Mesh capture is paused".into());
            }
            if state.mesh_id.is_none() {
                return Err("Create or join a mesh before capturing clipboard text".into());
            }
            let local_id = state.identity.device_id.to_string();
            if state
                .store
                .devices()?
                .iter()
                .any(|peer| peer.device_id == local_id && peer.revoked)
            {
                return Err("This device has been revoked from the mesh".into());
            }
            // Copying something already in history moves it to the top
            // instead of adding a duplicate. Re-copying the newest clip (or a
            // pinned one, which already leads the list) changes nothing.
            let (same, newest) = state.store.same_content(&content_hash)?;
            if let Some((existing, _)) = same.iter().find(|(existing, pinned)| {
                only_if_new || *pinned || newest.as_deref() == Some(existing.as_str())
            }) {
                return Ok(existing.clone());
            }
            let mut replaced = Vec::new();
            for (existing, _) in same {
                if state.store.delete_item(&existing)? {
                    replaced.push(existing);
                }
            }
            let source_name = state.device_name.clone();
            let retention: u32 = state
                .store
                .setting("retention_hours", DEFAULT_RETENTION_HOURS);
            let mut wire = WireItem {
                protocol_version: PROTOCOL_VERSION,
                id: id.clone(),
                origin_device: state.identity.device_id.to_string(),
                sender_sequence: state.store.next_sequence()?,
                source_name,
                created_at: store::now_ms(),
                expires_at: store::now_ms()
                    .saturating_add(i64::from(retention.max(1)) * 60 * 60 * 1000),
                text: text.to_string(),
                kind: kind.into(),
                content_hash,
                representations,
                origin_signature: String::new(),
            };
            crypto::sign_item(&state.identity.static_private, &mut wire)?;
            crate::payload::encoded_item(&wire)?;
            let max_items = state.store.setting("max_items", DEFAULT_MAX_ITEMS);
            let stored = state.store.capture(&wire, max_items)?;
            if !stored {
                return Ok(id);
            }
            (wire, replaced)
        };
        self.touch();
        // Local history is already durable; peers that miss this broadcast get
        // it during reconnect catch-up. A slow peer must not stall capture.
        let core = self.clone();
        self.track(tokio::spawn(async move {
            for id in replaced {
                let _ = core.broadcast(WireMessage::DeleteItem { id }, None).await;
            }
            let _ = core.broadcast_item(message).await;
        }));
        Ok(id)
    }

    pub async fn devices(&self) -> Result<Vec<DeviceInfo>, String> {
        let state = self.state.lock().await;
        let connected = self
            .connections
            .lock()
            .map_err(|_| "Device connection state is unavailable")?;
        state
            .store
            .devices()?
            .into_iter()
            .map(|peer| {
                Ok(DeviceInfo {
                    device_id: peer.device_id.clone(),
                    device_name: peer.device_name,
                    platform: match peer.certificate.certificate.platform.as_str() {
                        "linux" => "Linux",
                        "windows" => "Windows",
                        "macos" => "macOS",
                        "android" => "Android",
                        "ios" => "iOS",
                        _ => "Device",
                    }
                    .into(),
                    state: if peer.revoked {
                        "revoked".into()
                    } else if peer.device_id == state.identity.device_id.to_string()
                        || connected.contains_key(&peer.device_id)
                    {
                        "online".into()
                    } else {
                        "offline".into()
                    },
                    last_seen: (peer.last_seen > 0).then_some(peer.last_seen),
                    is_owner: peer.owner,
                })
            })
            .collect()
    }

    pub async fn delete(&self, id: &str) -> Result<bool, String> {
        let changed = self.state.lock().await.store.delete_item(id)?;
        self.touch();
        self.broadcast(WireMessage::DeleteItem { id: id.to_string() }, None)
            .await?;
        Ok(changed)
    }

    pub async fn pin(&self, id: &str, pinned: bool) -> Result<bool, String> {
        let update = {
            let mut state = self.state.lock().await;
            state.store.expire()?;
            if state.store.item(id)?.is_none() {
                return Ok(false);
            }
            let local_id = state.identity.device_id.to_string();
            if state
                .store
                .devices()?
                .iter()
                .any(|peer| peer.device_id == local_id && peer.revoked)
            {
                return Err("This device has been removed from the mesh".into());
            }
            if state
                .store
                .pin_state(id)?
                .is_some_and(|pin| pin.pinned == pinned)
            {
                return Ok(false);
            }
            let mut update = SignedPinState {
                version: PROTOCOL_VERSION,
                mesh_id: state
                    .mesh_id
                    .clone()
                    .ok_or_else(|| "Mesh is unavailable".to_string())?,
                id: id.to_string(),
                pinned,
                actor_device: local_id,
                revision: state.store.next_pin_revision()?,
                changed_at: store::now_ms(),
                signature: String::new(),
            };
            crypto::sign_pin(&state.identity.static_private, &mut update)?;
            state.store.apply_pin(&update)?;
            update
        };
        self.touch();
        self.broadcast(WireMessage::PinUpdate { state: update }, None)
            .await?;
        Ok(true)
    }

    async fn receive_pin(&self, sender_id: &str, update: SignedPinState) -> Result<(), String> {
        let changed = {
            let mut state = self.state.lock().await;
            if update.version != PROTOCOL_VERSION
                || state.mesh_id.as_deref() != Some(update.mesh_id.as_str())
            {
                return Err("Pin update belongs to an unsupported or different mesh".into());
            }
            let local_id = state.identity.device_id.to_string();
            let peers = state.store.devices()?;
            if peers
                .iter()
                .any(|peer| peer.device_id == local_id && peer.revoked)
                || !peers
                    .iter()
                    .any(|peer| peer.device_id == sender_id && !peer.revoked)
            {
                return Err("Pin update came from an untrusted connection".into());
            }
            let actor = peers
                .iter()
                .find(|peer| peer.device_id == update.actor_device && !peer.revoked)
                .ok_or_else(|| "Pin update origin is not trusted".to_string())?;
            crypto::verify_pin(&actor.certificate.certificate.item_signing_public, &update)?;
            state.store.apply_pin(&update)?
        };
        if changed {
            self.touch();
            self.broadcast(WireMessage::PinUpdate { state: update }, Some(sender_id))
                .await?;
        }
        Ok(())
    }

    pub async fn update_settings(&self, values: &serde_json::Value) -> Result<(), String> {
        let object = values
            .as_object()
            .ok_or_else(|| "Settings values must be an object".to_string())?;
        let mut state = self.state.lock().await;
        for (key, value) in object {
            match key.as_str() {
                "paused" => {
                    let paused = value
                        .as_bool()
                        .ok_or_else(|| "The paused setting must be true or false".to_string())?;
                    state
                        .store
                        .set_setting("paused", if paused { "true" } else { "false" })?;
                }
                "retention_hours" => {
                    let hours = value
                        .as_u64()
                        .filter(|n| (1..=720).contains(n))
                        .ok_or_else(|| "Retention must be between 1 and 720 hours".to_string())?;
                    state
                        .store
                        .set_setting("retention_hours", &hours.to_string())?;
                }
                "max_items" => {
                    let count = value
                        .as_u64()
                        .filter(|n| (1..=10_000).contains(n))
                        .ok_or_else(|| {
                            "History limit must be between 1 and 10,000 items".to_string()
                        })?;
                    state.store.set_setting("max_items", &count.to_string())?;
                }
                "relay_url" => {
                    let base = value
                        .as_str()
                        .ok_or_else(|| "Relay address must be text".to_string())?;
                    crate::relay_transport::validate_relay_url(base)?;
                    state.store.set_setting("relay_url", base)?;
                }
                _ => return Err(format!("Unsupported setting: {key}")),
            }
        }
        state.store.expire()?;
        drop(state);
        self.touch();
        Ok(())
    }

    pub async fn revoke(&self, device_id: &str) -> Result<bool, String> {
        let signed = {
            let state = self.state.lock().await;
            if state.owner_device_id.as_deref()
                != Some(state.identity.device_id.to_string().as_str())
            {
                return Err("Only the mesh owner can revoke a device".into());
            }
            Uuid::parse_str(device_id).map_err(|_| "Device ID must be a valid UUID".to_string())?;
            let target = state
                .store
                .devices()?
                .into_iter()
                .find(|peer| peer.device_id == device_id)
                .ok_or_else(|| "Device is not a member of this mesh".to_string())?;
            if target.owner {
                return Err("The mesh owner cannot revoke itself".into());
            }
            if target.revoked {
                return Ok(false);
            }
            let epoch = state
                .store
                .revocations()?
                .into_iter()
                .map(|entry| entry.2)
                .max()
                .unwrap_or(0)
                .saturating_add(1);
            let signing = SigningKey::from_bytes(
                &state
                    .identity
                    .owner_signing_secret
                    .ok_or_else(|| "Mesh signing identity is unavailable".to_string())?,
            );
            let revocation = Revocation {
                version: PROTOCOL_VERSION,
                mesh_id: state
                    .mesh_id
                    .clone()
                    .ok_or_else(|| "Mesh is unavailable".to_string())?,
                device_id: device_id.to_string(),
                revoked_at: store::now_ms(),
                epoch,
            };
            let signed = crypto::sign_revocation(&signing, revocation)?;
            state.store.revoke(
                device_id,
                signed.revocation.revoked_at,
                epoch,
                &signed.signature,
            )?;
            signed
        };
        self.close_connection(device_id);
        let (certificates, revocations) = self.membership_snapshot().await?;
        self.broadcast(
            WireMessage::MembershipSnapshot {
                certificates,
                revocations,
            },
            Some(device_id),
        )
        .await?;
        self.touch();
        let _ = signed;
        Ok(true)
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

    pub async fn shutdown(&self) {
        self.shutdown_tx.send_replace(true);
        if let Ok(mut discovery) = self.discovery.lock() {
            if let Some(daemon) = discovery.take() {
                let _ = daemon.shutdown();
            }
        }
        if let Ok(mut connections) = self.connections.lock() {
            for (_, connection) in connections.drain() {
                connection.cancel.send_replace(true);
            }
        }
        let tasks = self
            .tasks
            .lock()
            .map(|mut tasks| tasks.drain(..).collect::<Vec<_>>())
            .unwrap_or_default();
        for task in &tasks {
            task.abort();
        }
        for task in tasks {
            let _ = task.await;
        }
        self.touch();
    }

    pub async fn history(
        &self,
        query: Option<&str>,
        limit: usize,
    ) -> Result<Vec<HistoryItem>, String> {
        self.state.lock().await.store.history(query, limit)
    }

    pub async fn settings(&self) -> Result<serde_json::Value, String> {
        let state = self.state.lock().await;
        Ok(serde_json::json!({
            "paused": state.store.setting("paused", false),
            "retention_hours": state.store.setting("retention_hours", DEFAULT_RETENTION_HOURS),
            "max_items": state.store.setting("max_items", DEFAULT_MAX_ITEMS),
            "relay_url": state.store.setting("relay_url", String::new()),
        }))
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

    pub async fn handle_wire(&self, peer_id: &str, message: WireMessage) -> Result<(), String> {
        match message {
            WireMessage::ClipboardItem { item } => self.receive_item(peer_id, item).await,
            WireMessage::ClipboardChunk {
                id,
                offset,
                total,
                data,
            } => self.receive_chunk(peer_id, id, offset, total, data).await,
            WireMessage::DeleteItem { id } => self.receive_delete(peer_id, &id).await,
            WireMessage::PinUpdate { state } => self.receive_pin(peer_id, state).await,
            WireMessage::MembershipSnapshot {
                certificates,
                revocations,
            } => {
                self.receive_membership(peer_id, certificates, revocations)
                    .await
            }
            WireMessage::Ping { sent_at } => {
                self.send_to_peer(peer_id, WireMessage::Pong { sent_at })
                    .await
            }
            WireMessage::Pong { .. } => Ok(()),
            _ => Err("Unexpected pairing message on an established device connection".into()),
        }
    }

    pub async fn sync_peer(&self, peer_id: &str, generation: u64) -> Result<(), String> {
        self.sync_peer_impl(peer_id, generation).await
    }

    pub async fn wait_for_change(&self, after_revision: u64, timeout: Duration) -> u64 {
        let mut changes = self.revision_tx.subscribe();
        loop {
            let current = *changes.borrow_and_update();
            if current > after_revision {
                return current;
            }
            if tokio::time::timeout(timeout.min(POLL_TIMEOUT), changes.changed())
                .await
                .is_err()
            {
                return self.revision.load(Ordering::SeqCst);
            }
        }
    }

    fn touch(&self) -> u64 {
        let revision = self.revision.fetch_add(1, Ordering::SeqCst) + 1;
        self.revision_tx.send_replace(revision);
        revision
    }

    pub(crate) async fn request(
        self: &Arc<Self>,
        request: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        let object = request
            .as_object()
            .ok_or_else(|| "Request must be a JSON object".to_string())?;
        let op = object
            .get("op")
            .and_then(|value| value.as_str())
            .ok_or_else(|| "Request is missing its operation".to_string())?;
        let string_arg = |key: &str| -> Result<&str, String> {
            object
                .get(key)
                .and_then(|value| value.as_str())
                .ok_or_else(|| format!("Request is missing {key}"))
        };
        match op {
            "discovery_config" => {
                let state = self.state.lock().await;
                let port = self
                    .listener_addr
                    .lock()
                    .map_err(|_| "Mesh listener state is unavailable")?
                    .map(|address| address.port())
                    .unwrap_or(0);
                Ok(
                    serde_json::json!({"mesh_id":state.mesh_id,"device_id":state.identity.device_id.to_string(),"public":crypto::encode(&state.identity.static_public),"port":port}),
                )
            }
            "discovery_candidates" => {
                let id = string_arg("device_id")?;
                Uuid::parse_str(id)
                    .map_err(|_| "Discovery device identifier is invalid".to_string())?;
                let public = string_arg("public")?;
                decode_key_32(public, "Discovered device identity")?;
                let values = object
                    .get("addresses")
                    .and_then(|value| value.as_array())
                    .filter(|values| values.len() <= 16)
                    .ok_or_else(|| "Discovery requires at most 16 socket addresses".to_string())?;
                // Platform discovery may report addresses this core cannot
                // dial (e.g. scoped link-local IPv6); skip those, keep the rest.
                let mut addresses = Vec::new();
                for value in values {
                    let Some(address) = value
                        .as_str()
                        .filter(|raw| raw.len() <= 256)
                        .and_then(|raw| raw.parse::<SocketAddr>().ok())
                    else {
                        continue;
                    };
                    if address.port() == 0
                        || address.ip().is_unspecified()
                        || address.ip().is_multicast()
                    {
                        continue;
                    }
                    if !addresses.contains(&address) {
                        addresses.push(address);
                    }
                }
                if addresses.is_empty() {
                    return Ok(serde_json::json!({"accepted":false}));
                }
                let accepted = self.discovery_candidates(id, public, addresses).await;
                Ok(serde_json::json!({"accepted":accepted}))
            }
            "status" => serde_json::to_value(self.status().await?)
                .map_err(|_| "Could not encode device status".into()),
            "resume" => {
                self.resume().await;
                serde_json::to_value(self.status().await?)
                    .map_err(|_| "Could not encode device status".into())
            }
            "wait_for_change" => {
                let after = object
                    .get("after_revision")
                    .and_then(|value| value.as_u64())
                    .unwrap_or(0);
                let timeout_ms = object
                    .get("timeout_ms")
                    .and_then(|value| value.as_u64())
                    .unwrap_or(POLL_TIMEOUT.as_millis() as u64)
                    .min(POLL_TIMEOUT.as_millis() as u64);
                Ok(
                    serde_json::json!({"revision": self.wait_for_change(after, Duration::from_millis(timeout_ms)).await}),
                )
            }
            "create_mesh" => {
                self.create_mesh(string_arg("device_name")?).await?;
                serde_json::to_value(self.status().await?)
                    .map_err(|_| "Could not encode device status".into())
            }
            "create_invite" => {
                let (invite, expires_at) = self.create_invite().await?;
                Ok(serde_json::json!({"invite":invite,"expires_at":expires_at}))
            }
            "join" => {
                let info = self
                    .join(string_arg("invite")?, string_arg("device_name")?)
                    .await?;
                serde_json::to_value(info).map_err(|_| "Could not encode pairing request".into())
            }
            "confirm_pairing" => {
                let accept = object
                    .get("accept")
                    .and_then(|value| value.as_bool())
                    .ok_or_else(|| "Request is missing a true or false accept value".to_string())?;
                self.confirm_pairing(string_arg("session_id")?, accept)
                    .await?;
                Ok(serde_json::json!({"accepted":accept}))
            }
            "history" => {
                let query = object
                    .get("query")
                    .and_then(|value| value.as_str())
                    .unwrap_or("");
                let limit = object
                    .get("limit")
                    .and_then(|value| value.as_u64())
                    .unwrap_or(250)
                    .clamp(1, 10_000) as usize;
                Ok(serde_json::json!({"items":self.history(Some(query), limit).await?}))
            }
            "capture" => {
                let id = object.get("id").and_then(|value| value.as_str());
                let kind = object.get("kind").and_then(|value| value.as_str());
                let text = object
                    .get("text")
                    .and_then(|value| value.as_str())
                    .unwrap_or_default();
                let representations = object
                    .get("representations")
                    .cloned()
                    .map(serde_json::from_value::<Vec<crate::payload::Representation>>)
                    .transpose()
                    .map_err(|_| "Clipboard representations are malformed".to_string())?
                    .unwrap_or_default();
                // The desktop watcher reports the existing selection at start;
                // that must not reorder history if the content is known.
                let only_if_new = object
                    .get("only_if_new")
                    .and_then(|value| value.as_bool())
                    .unwrap_or(false);
                let id = self
                    .capture_representations(id, text, kind, representations, only_if_new)
                    .await?;
                Ok(serde_json::json!({"id":id,"stored":true}))
            }
            "payload" => {
                let mut state = self.state.lock().await;
                state.store.expire()?;
                let item = state
                    .store
                    .item(string_arg("id")?)?
                    .ok_or_else(|| "Clipboard item is no longer available".to_string())?;
                Ok(
                    serde_json::json!({"id":item.id,"text":item.text,"kind":item.kind,"representations":item.representations}),
                )
            }
            "resend" => {
                let item = {
                    let mut state = self.state.lock().await;
                    state.store.expire()?;
                    state
                        .store
                        .item(string_arg("id")?)?
                        .ok_or_else(|| "Clipboard item is no longer available".to_string())?
                };
                let id = self
                    .capture_representations(
                        None,
                        &item.text,
                        Some(&item.kind),
                        item.representations.clone(),
                        false,
                    )
                    .await?;
                if id == item.id {
                    // Already the newest clip: share the existing item again.
                    self.broadcast_item(item).await?;
                }
                Ok(serde_json::json!({"id":id,"stored":true}))
            }
            "devices" => Ok(serde_json::json!({"devices":self.devices().await?})),
            "revoke" => {
                Ok(serde_json::json!({"revoked":self.revoke(string_arg("device_id")?).await?}))
            }
            "clear_history" => {
                let include_pinned = object
                    .get("include_pinned")
                    .and_then(|value| value.as_bool())
                    .unwrap_or(false);
                let ids = self
                    .state
                    .lock()
                    .await
                    .store
                    .clear_history(include_pinned)?;
                for id in &ids {
                    self.broadcast(WireMessage::DeleteItem { id: id.clone() }, None)
                        .await?;
                }
                if !ids.is_empty() {
                    self.touch();
                }
                Ok(serde_json::json!({"deleted":ids.len()}))
            }
            "delete" => Ok(serde_json::json!({"deleted":self.delete(string_arg("id")?).await?})),
            "pin" => {
                let pinned = object
                    .get("pinned")
                    .and_then(|value| value.as_bool())
                    .ok_or_else(|| "Request is missing a true or false pinned value".to_string())?;
                Ok(serde_json::json!({"changed":self.pin(string_arg("id")?, pinned).await?}))
            }
            "settings" => {
                if let Some(values) = object.get("values") {
                    self.update_settings(values).await?;
                }
                self.settings().await
            }
            "shutdown" => {
                self.shutdown().await;
                Ok(serde_json::json!({"shutdown":true}))
            }
            _ => Err(format!("Unsupported core operation: {op}")),
        }
    }
}

fn validate_device_name(name: &str) -> Result<(), String> {
    if name.trim().is_empty() {
        return Err("Device name cannot be empty".into());
    }
    if name.trim().len() > MAX_DEVICE_NAME_BYTES {
        return Err("Device name must be 128 bytes or fewer".into());
    }
    Ok(())
}

enum IncomingAction {
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

async fn handle_incoming(core: Arc<Core>, mut stream: PeerStream, remote_addr: SocketAddr) {
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

async fn run_owner_pair(
    core: Arc<Core>,
    mut stream: PeerStream,
    // Encrypted transport and its Noise handshake hash.
    session: (TransportState, Vec<u8>),
    invitation: InvitationState,
    peer: PeerHello,
    remote_addr: SocketAddr,
    decision: watch::Receiver<Option<bool>>,
) -> Result<(), String> {
    let (mut secure, transcript) = session;
    let session_id = invitation.invite.session_id.clone();
    let peer_id = peer.device_id.clone();
    if !exchange_pairing_approval(
        &mut stream,
        &mut secure,
        decision,
        invitation.invite.expires_at,
    )
    .await?
    {
        remove_pairing(&core, &session_id);
        return Ok(());
    }
    set_pairing_state(&core, &session_id, "approval_sent");
    if invitation.invite.expires_at <= store::now_ms() {
        remove_pairing(&core, &session_id);
        return Err("Pairing invitation expired before both devices approved".into());
    }
    let commit = commit_owner_pair(&core, &invitation, &peer, remote_addr).await?;
    transport::send_secure(&mut stream, &mut secure, &commit).await?;
    let (certificates, revocations) = core.membership_snapshot().await?;
    core.broadcast(
        WireMessage::MembershipSnapshot {
            certificates,
            revocations,
        },
        Some(&peer_id),
    )
    .await?;
    remove_pairing(&core, &session_id);
    core.finish_invitation(&session_id, true);
    core.touch();
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
    Ok(())
}

async fn commit_owner_pair(
    core: &Arc<Core>,
    invitation: &InvitationState,
    peer: &PeerHello,
    remote_addr: SocketAddr,
) -> Result<WireMessage, String> {
    let peer_id = peer.device_id.as_str();
    let peer_static = peer.static_public.as_slice();
    let item_signing_public = peer.item_signing_public.as_str();
    if invitation.invite.expires_at <= store::now_ms() {
        return Err("Pairing invitation expired before commit".into());
    }
    {
        let invites = core
            .invitations
            .lock()
            .map_err(|_| "Pairing invitation state is unavailable")?;
        let current = invites
            .get(&invitation.invite.session_id)
            .ok_or_else(|| "Pairing invitation is no longer active".to_string())?;
        if current.consumed || !current.in_flight || current.invite.expires_at <= store::now_ms() {
            return Err("Pairing invitation expired or was already used".into());
        }
    }
    let state = core.state.lock().await;
    let local_id = state.identity.device_id.to_string();
    if state.owner_device_id.as_deref() != Some(local_id.as_str())
        || state.mesh_id.as_deref() != Some(invitation.invite.mesh_id.as_str())
        || state.identity.static_public.to_vec()
            != crypto::decode(&invitation.invite.host_static_public)?
    {
        return Err("Mesh owner identity changed before pairing commit".into());
    }
    if invitation.invite.expires_at <= store::now_ms() {
        return Err("Pairing invitation expired before commit".into());
    }
    if peer_id == local_id {
        return Err("A device cannot join itself".into());
    }
    decode_key_32(item_signing_public, "Clipboard signing identity")?;
    let peers = state.store.devices()?;
    if peers
        .iter()
        .any(|p| p.device_id == peer_id && (p.revoked || p.static_public != peer_static))
    {
        return Err("This device identity cannot be paired again".into());
    }
    if peers.len() >= MAX_PEERS && !peers.iter().any(|p| p.device_id == peer_id) {
        return Err("This mesh reached its device limit".into());
    }
    let name = {
        let pairing = core
            .pairings
            .lock()
            .map_err(|_| "Pairing state is unavailable")?;
        pairing
            .get(&invitation.invite.session_id)
            .map(|entry| entry.info.peer_name.clone())
            .ok_or_else(|| "Pairing request expired before commit".to_string())?
    };
    let signing = SigningKey::from_bytes(
        &state
            .identity
            .owner_signing_secret
            .ok_or_else(|| "Mesh signing identity is unavailable".to_string())?,
    );
    let cert = MemberCertificate {
        version: PROTOCOL_VERSION,
        mesh_id: invitation.invite.mesh_id.clone(),
        device_id: peer_id.to_string(),
        device_name: name.clone(),
        static_public: crypto::encode(peer_static),
        issued_at: store::now_ms(),
        item_signing_public: item_signing_public.to_string(),
        platform: peer.platform.clone(),
        capabilities: peer.capabilities.clone(),
    };
    let signed = crypto::sign_member(&signing, cert)?;
    let mut membership = peers
        .into_iter()
        .filter(|p| !p.revoked && p.device_id != peer_id)
        .map(|peer| peer.certificate)
        .collect::<Vec<_>>();
    membership.push(signed.clone());
    let pair_commit = WireMessage::PairCommit {
        mesh_id: invitation.invite.mesh_id.clone(),
        owner_signing_public: crypto::encode(&signing.verifying_key().to_bytes()),
        owner_device_id: local_id,
        member_certificate: signed.clone(),
        membership: membership.clone(),
    };
    if serde_json::to_vec(&pair_commit)
        .map_err(|_| "Could not encode mesh membership".to_string())?
        .len()
        + 16
        > MAX_FRAME_BYTES
    {
        return Err("Mesh membership is too large to send in one secure pairing frame".into());
    }
    if invitation.invite.expires_at <= store::now_ms() {
        return Err("Pairing invitation expired before commit".into());
    }
    state.store.add_device(&PeerRecord {
        device_id: peer_id.to_string(),
        device_name: name,
        static_public: peer_static.to_vec(),
        endpoint: remote_addr.to_string(),
        certificate: signed,
        last_seen: store::now_ms(),
        revoked: false,
        owner: false,
    })?;
    drop(state);
    if let Ok(mut invites) = core.invitations.lock() {
        if let Some(current) = invites.get_mut(&invitation.invite.session_id) {
            current.consumed = true;
            current.in_flight = false;
        }
    }
    Ok(pair_commit)
}

async fn run_client_pair(
    core: Arc<Core>,
    mut stream: PeerStream,
    // Encrypted transport and its Noise handshake hash.
    session: (TransportState, Vec<u8>),
    invite: InviteV1,
    session_id: String,
    decision: watch::Receiver<Option<bool>>,
    route: &'static str,
) {
    let (mut secure, handshake) = session;
    if !matches!(
        exchange_pairing_approval(&mut stream, &mut secure, decision, invite.expires_at).await,
        Ok(true)
    ) {
        remove_pairing(&core, &session_id);
        return;
    }
    set_pairing_state(&core, &session_id, "approval_sent");
    loop {
        if invite.expires_at <= store::now_ms() {
            break;
        }
        let remaining =
            Duration::from_millis(invite.expires_at.saturating_sub(store::now_ms()).max(1) as u64);
        let message =
            match tokio::time::timeout(remaining, transport::read_secure(&mut stream, &mut secure))
                .await
            {
                Ok(Ok(message)) => message,
                _ => break,
            };
        match message {
            WireMessage::PairDecision { accepted: false } => break,
            WireMessage::PairDecision { accepted: true } => continue,
            WireMessage::PairCommit {
                mesh_id,
                owner_signing_public,
                owner_device_id,
                member_certificate,
                membership,
            } => {
                if apply_pair_commit(
                    &core,
                    &invite,
                    &mesh_id,
                    &owner_signing_public,
                    &owner_device_id,
                    &member_certificate,
                    &membership,
                )
                .await
                .is_err()
                {
                    break;
                }
                remove_pairing(&core, &session_id);
                core.touch();
                if core.start().await.is_err() {
                    break;
                }
                transport::start_peer(
                    core,
                    invite.host_device_id.clone(),
                    stream,
                    secure,
                    route,
                    handshake,
                )
                .await;
                return;
            }
            _ => break,
        }
    }
    remove_pairing(&core, &session_id);
}

async fn apply_pair_commit(
    core: &Core,
    invite: &InviteV1,
    mesh_id: &str,
    owner_signing_public: &str,
    owner_device_id: &str,
    member_certificate: &SignedMemberCertificate,
    membership: &[SignedMemberCertificate],
) -> Result<(), String> {
    if invite.expires_at <= store::now_ms() {
        return Err("Pairing invitation expired before trust was committed".into());
    }
    if mesh_id != invite.mesh_id
        || owner_device_id != invite.host_device_id
        || owner_signing_public != invite.owner_signing_public
    {
        return Err("Pair commit does not match the pinned invitation".into());
    }
    let owner_public = decode_key_32(owner_signing_public, "Mesh owner signing identity")?;
    crypto::verify_member(&owner_public, member_certificate)?;
    let owner_static = decode_key_32(&invite.host_static_public, "Mesh owner identity")?;
    let local_id = {
        let state = core.state.lock().await;
        state.identity.device_id.to_string()
    };
    let mut owner_seen = false;
    let mut self_seen = false;
    let mut peers = Vec::new();
    if membership.len() > MAX_PEERS {
        return Err("Mesh membership exceeds the device limit".into());
    }
    for signed in membership {
        crypto::verify_member(&owner_public, signed)?;
        let cert = &signed.certificate;
        if cert.mesh_id != invite.mesh_id {
            return Err("Pair commit contains membership from another mesh".into());
        }
        Uuid::parse_str(&cert.device_id)
            .map_err(|_| "Pair commit contains an invalid device identifier".to_string())?;
        validate_device_name(&cert.device_name)?;
        let public = decode_key_32(&cert.static_public, "Device public identity")?;
        if cert.device_id == owner_device_id {
            owner_seen = public == owner_static && cert.device_name == invite.host_device_name;
            if !owner_seen {
                return Err("Mesh owner certificate did not match the invitation".into());
            }
        }
        if cert.device_id == local_id {
            self_seen = public == core.state.lock().await.identity.static_public
                && same_certificate(signed, member_certificate);
            if !self_seen {
                return Err("Pair commit did not authorize this device identity".into());
            }
        }
        peers.push(PeerRecord {
            device_id: cert.device_id.clone(),
            device_name: cert.device_name.clone(),
            static_public: public,
            endpoint: if cert.device_id == owner_device_id {
                SocketAddr::new(
                    invite
                        .host_address
                        .parse()
                        .map_err(|_| "Invalid owner address")?,
                    invite.host_port,
                )
                .to_string()
            } else {
                String::new()
            },
            certificate: signed.clone(),
            last_seen: store::now_ms(),
            revoked: false,
            owner: cert.device_id == owner_device_id,
        });
    }
    if !owner_seen || !self_seen {
        return Err("Pair commit omitted the owner or new member certificate".into());
    }
    let mut state = core.state.lock().await;
    if state.mesh_id.is_some() {
        return Err("This device joined another mesh while pairing".into());
    }
    let owner_endpoint = SocketAddr::new(
        invite
            .host_address
            .parse()
            .map_err(|_| "Invalid owner address")?,
        invite.host_port,
    )
    .to_string();
    let owner_static_encoded = crypto::encode(&owner_static);
    state.store.install_mesh(
        &[
            ("mesh_id", mesh_id),
            ("owner_device_id", owner_device_id),
            ("owner_signing_public", owner_signing_public),
            ("owner_static_public", &owner_static_encoded),
            ("owner_endpoint", &owner_endpoint),
            ("device_name", &member_certificate.certificate.device_name),
        ],
        &peers,
    )?;
    if let Some(base) = &invite.relay_url {
        state.store.set_setting("relay_url", base)?;
    }
    state.mesh_id = Some(mesh_id.to_string());
    state.owner_device_id = Some(owner_device_id.to_string());
    state.owner_signing_public = Some(owner_public);
    state.owner_endpoint = Some(
        SocketAddr::new(
            invite
                .host_address
                .parse()
                .map_err(|_| "Invalid owner address")?,
            invite.host_port,
        )
        .to_string(),
    );
    state.device_name = member_certificate.certificate.device_name.clone();
    state.diagnostic.clear();
    Ok(())
}

fn set_pairing_state(core: &Core, session_id: &str, state: &str) {
    if let Ok(mut pairings) = core.pairings.lock() {
        if let Some(pairing) = pairings.get_mut(session_id) {
            pairing.info.state = state.to_string();
        }
    }
    core.touch();
}

fn remove_pairing(core: &Core, session_id: &str) {
    if let Ok(mut pairings) = core.pairings.lock() {
        pairings.remove(session_id);
    }
    core.touch();
}

include!("core_helpers.rs");
