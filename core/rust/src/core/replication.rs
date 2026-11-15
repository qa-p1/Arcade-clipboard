//! Replication between members: item, delete, pin and membership messages, chunked transfers
//! and the per-peer sync.

use super::*;

impl Core {
    pub(super) async fn send_to_peer(
        &self,
        peer_id: &str,
        message: WireMessage,
    ) -> Result<(), String> {
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

    pub(super) async fn broadcast(
        &self,
        message: WireMessage,
        exclude: Option<&str>,
    ) -> Result<(), String> {
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

    pub(super) async fn broadcast_item(&self, item: WireItem) -> Result<(), String> {
        for message in item_messages(&item)? {
            self.broadcast(message, None).await?;
        }
        // Offline capture is durable; reconnect catch-up delivers it.
        Ok(())
    }

    pub(super) async fn membership_snapshot(
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

    pub(super) async fn sync_peer_impl(
        &self,
        peer_id: &str,
        generation: u64,
    ) -> Result<(), String> {
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
            // Private mode: no clip leaves this device, the backlog included.
            // It is sent when Private mode ends.
            let ids = if state.store.setting("paused", false) {
                Vec::new()
            } else {
                state.store.active_item_ids(10_000)?
            };
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
                if state.store.setting("paused", false) {
                    return Ok(());
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

    pub(super) async fn receive_item(&self, sender_id: &str, item: WireItem) -> Result<(), String> {
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

    pub(super) async fn receive_delete(&self, sender_id: &str, id: &str) -> Result<(), String> {
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

    pub(super) async fn receive_membership(
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

    pub(super) async fn receive_pin(
        &self,
        sender_id: &str,
        update: SignedPinState,
    ) -> Result<(), String> {
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
}

pub(super) enum ItemMessages {
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

pub(super) fn item_messages(item: &WireItem) -> Result<ItemMessages, String> {
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

pub(super) struct IncomingTransfer {
    bytes: Vec<u8>,
    total: usize,
    deadline: std::time::Instant,
}

impl Core {
    pub(super) async fn receive_chunk(
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

pub(super) fn same_item(a: &WireItem, b: &WireItem) -> bool {
    serde_json::to_vec(a).ok() == serde_json::to_vec(b).ok()
}

pub(super) fn same_certificate(a: &SignedMemberCertificate, b: &SignedMemberCertificate) -> bool {
    serde_json::to_vec(a).ok() == serde_json::to_vec(b).ok()
}

pub(super) async fn send_sync(outbound: &Outbound, message: WireMessage) -> Result<(), String> {
    tokio::time::timeout(Duration::from_secs(15), outbound.send(message))
        .await
        .map_err(|_| "History synchronization timed out".to_string())?
        .map_err(|_| "Device connection closed during history synchronization".to_string())
}
