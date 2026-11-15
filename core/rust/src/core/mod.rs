use crate::{
    crypto,
    model::{
        DeviceInfo, HistoryItem, InviteV1, MemberCertificate, PeerRecord, PendingPairingInfo,
        Revocation, SignedMemberCertificate, SignedPinState, SignedRevocation, Status, WireItem,
        WireMessage, DEFAULT_MAX_ITEMS, DEFAULT_MAX_STORAGE_MB, DEFAULT_RETENTION_HOURS,
        INVITE_TTL_SECONDS, MAX_FRAME_BYTES, PROTOCOL_VERSION,
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

mod pairing;
mod peers;
mod replication;

use pairing::*;
use peers::*;
use replication::*;

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
    data_dir: PathBuf,
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
    /// Counts `latest_only` history searches; a newer one stops an older one.
    searches: AtomicU64,
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
            data_dir,
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
            searches: AtomicU64::new(0),
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

    /// The app profile path used for private, allowlisted settings backups.
    pub fn data_dir(&self) -> &std::path::Path {
        &self.data_dir
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

    fn track(&self, task: JoinHandle<()>) {
        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.retain(|existing| !existing.is_finished());
            tasks.push(task);
        }
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
            // One clock reading: with Forever the lifetime is exactly the
            // protocol's 30-day maximum, so a second, later reading for the
            // expiry made it a millisecond too long and the capture failed.
            let created_at = store::now_ms();
            let mut wire = WireItem {
                protocol_version: PROTOCOL_VERSION,
                id: id.clone(),
                origin_device: state.identity.device_id.to_string(),
                sender_sequence: state.store.next_sequence()?,
                source_name,
                created_at,
                // Forever (0) still tells peers a 30-day lifetime, the longest
                // the protocol allows; each device keeps clips by its own setting.
                expires_at: created_at.saturating_add(
                    i64::from(if retention == 0 {
                        720
                    } else {
                        retention.min(720)
                    }) * 60
                        * 60
                        * 1000,
                ),
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

    pub async fn update_settings(
        self: &Arc<Self>,
        values: &serde_json::Value,
    ) -> Result<(), String> {
        let object = values
            .as_object()
            .ok_or_else(|| "Settings values must be an object".to_string())?;
        let mut state = self.state.lock().await;
        let was_paused = state.store.setting("paused", false);
        let cause = object
            .get("cause")
            .and_then(|value| value.as_str())
            .unwrap_or("unspecified")
            .chars()
            .filter(|c| !c.is_control())
            .take(64)
            .collect::<String>();
        for (key, value) in object {
            match key.as_str() {
                "cause" => {}
                "paused" => {
                    let paused = value
                        .as_bool()
                        .ok_or_else(|| "The paused setting must be true or false".to_string())?;
                    if paused != was_paused {
                        // Every path that changes Private mode leaves a trace.
                        eprintln!(
                            "arcade-clipboard: Private mode {} (cause: {cause})",
                            if paused { "on" } else { "off" }
                        );
                    }
                    state
                        .store
                        .set_setting("paused", if paused { "true" } else { "false" })?;
                }
                "retention_hours" => {
                    let hours = value
                        .as_u64()
                        .filter(|n| *n <= u64::from(crate::model::MAX_RETENTION_HOURS))
                        .ok_or_else(|| {
                            "Retention must be Forever (0) or between 1 hour and 10 years"
                                .to_string()
                        })?;
                    state
                        .store
                        .set_setting("retention_hours", &hours.to_string())?;
                }
                "max_storage_mb" => {
                    let megabytes = value
                        .as_u64()
                        .filter(|n| (16..=65_536).contains(n))
                        .ok_or_else(|| {
                            "The storage budget must be between 16 MB and 64 GB".to_string()
                        })?;
                    state
                        .store
                        .set_setting("max_storage_mb", &megabytes.to_string())?;
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
        let resumed = was_paused && !state.store.setting("paused", false);
        drop(state);
        if resumed {
            // Catch connected devices up on what Private mode held back.
            let connected: Vec<(String, u64)> = self
                .connections
                .lock()
                .map(|c| c.iter().map(|(id, c)| (id.clone(), c.generation)).collect())
                .unwrap_or_default();
            for (peer_id, generation) in connected {
                let core = self.clone();
                self.track(tokio::spawn(async move {
                    let _ = core.sync_peer(&peer_id, generation).await;
                }));
            }
        }
        self.touch();
        Ok(())
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
            "max_storage_mb": state.store.setting("max_storage_mb", DEFAULT_MAX_STORAGE_MB),
            "storage_used_bytes": state.store.storage_used_bytes()?,
            "relay_url": state.store.setting("relay_url", String::new()),
        }))
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
                // The search box asks for `latest_only`: typing on supersedes
                // a search still scanning an encrypted history.
                let items = if object.get("latest_only").and_then(|v| v.as_bool()) == Some(true) {
                    let search = self.searches.fetch_add(1, Ordering::SeqCst) + 1;
                    let superseded = || self.searches.load(Ordering::SeqCst) != search;
                    let items = self.state.lock().await.store.history_until(
                        Some(query),
                        limit,
                        &superseded,
                    )?;
                    if superseded() {
                        return Ok(serde_json::json!({"items":[],"superseded":true}));
                    }
                    items
                } else {
                    self.history(Some(query), limit).await?
                };
                let total = self.state.lock().await.store.item_count()?;
                Ok(serde_json::json!({"items":items,"total":total}))
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
