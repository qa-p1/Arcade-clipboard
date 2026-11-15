//! Pairing and membership: mesh creation, invitations, the owner and client sides of a pairing
//! handshake, and revocation.

use super::*;

impl Core {
    pub(super) fn reserve_invitation(&self, session_id: &str) -> Result<InvitationState, String> {
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

    pub(super) fn finish_invitation(&self, session_id: &str, committed: bool) {
        if let Ok(mut invitations) = self.invitations.lock() {
            if let Some(entry) = invitations.get_mut(session_id) {
                entry.in_flight = false;
                if committed {
                    entry.consumed = true;
                }
            }
        }
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
}

pub(super) async fn run_owner_pair(
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

pub(super) async fn commit_owner_pair(
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

pub(super) async fn run_client_pair(
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

pub(super) async fn apply_pair_commit(
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

pub(super) fn set_pairing_state(core: &Core, session_id: &str, state: &str) {
    if let Ok(mut pairings) = core.pairings.lock() {
        if let Some(pairing) = pairings.get_mut(session_id) {
            pairing.info.state = state.to_string();
        }
    }
    core.touch();
}

pub(super) fn remove_pairing(core: &Core, session_id: &str) {
    if let Ok(mut pairings) = core.pairings.lock() {
        pairings.remove(session_id);
    }
    core.touch();
}

pub(super) fn decode_key_32(value: &str, label: &str) -> Result<Vec<u8>, String> {
    let bytes = crypto::decode(value)?;
    if bytes.len() != 32 {
        return Err(format!("{label} must contain a 32-byte key"));
    }
    Ok(bytes)
}

pub(super) fn validate_invite(invite: &InviteV1) -> Result<(), String> {
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

pub(super) fn pairing_prologue(mesh_id: &str, session_id: &str) -> Vec<u8> {
    format!("arcade-clipboard:pair:v1:{mesh_id}:{session_id}").into_bytes()
}

pub(super) fn invitation_prologue(invitation: &InvitationState) -> Vec<u8> {
    pairing_prologue(&invitation.invite.mesh_id, &invitation.invite.session_id)
}

pub(super) async fn exchange_pairing_approval<
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
>(
    stream: &mut S,
    secure: &mut TransportState,
    mut decision: watch::Receiver<Option<bool>>,
    expires_at: i64,
) -> Result<bool, String> {
    let remaining = expires_at.saturating_sub(store::now_ms());
    if remaining <= 0 {
        return Ok(false);
    }
    let (mut reader, mut writer) = tokio::io::split(stream);
    // read_exact is not cancellation safe. Keep one frame read alive while
    // local consent changes, and decrypt only after the full frame arrives.
    // Splitting the socket lets us send consent without dropping that read.
    let incoming = transport::read_frame(&mut reader);
    let deadline = tokio::time::sleep(Duration::from_millis(remaining as u64));
    tokio::pin!(incoming, deadline);
    let mut local_approved = false;
    let mut remote_approved = false;
    loop {
        let local = *decision.borrow_and_update();
        if let Some(accepted) = local {
            if !local_approved {
                transport::send_secure(
                    &mut writer,
                    secure,
                    &WireMessage::PairDecision { accepted },
                )
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
        tokio::select! {
            changed = decision.changed(), if !local_approved => {
                if changed.is_err() { return Ok(false); }
            }
            frame = &mut incoming, if !remote_approved => {
                match transport::decrypt(secure, &frame?)? {
                    WireMessage::PairDecision { accepted: true } => remote_approved = true,
                    WireMessage::PairDecision { accepted: false } => return Ok(false),
                    _ => return Err("Unexpected message before pairing approval".into()),
                }
            }
            _ = &mut deadline => return Ok(false),
        }
    }
}

#[cfg(test)]
mod pairing_approval_tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    #[tokio::test]
    async fn local_confirmation_preserves_a_partially_read_approval_frame() {
        // Exercise cancellation during both the length prefix and ciphertext.
        for partial in [2, 12] {
            let local = IdentityMaterial::generate().unwrap();
            let remote = IdentityMaterial::generate().unwrap();
            let initiator = crypto::build_handshake(
                &local.static_private,
                Some(&[7; 32]),
                b"approval-test",
                true,
            )
            .unwrap();
            let responder = crypto::build_handshake(
                &remote.static_private,
                Some(&[7; 32]),
                b"approval-test",
                false,
            )
            .unwrap();
            let (mut local_stream, mut remote_stream) = tokio::io::duplex(2048);
            let (local_session, remote_session) = tokio::join!(
                transport::noise_handshake(&mut local_stream, initiator),
                transport::noise_handshake(&mut remote_stream, responder),
            );
            let (mut local_secure, _, _) = local_session.unwrap();
            let (mut remote_secure, _, _) = remote_session.unwrap();
            let mut approval = Vec::new();
            transport::send_secure(
                &mut approval,
                &mut remote_secure,
                &WireMessage::PairDecision { accepted: true },
            )
            .await
            .unwrap();
            remote_stream.write_all(&approval[..partial]).await.unwrap();
            let (decision, updates) = watch::channel(None);
            let mut exchange = Box::pin(exchange_pairing_approval(
                &mut local_stream,
                &mut local_secure,
                updates,
                store::now_ms() + 5_000,
            ));

            // Poll until the available prefix has been consumed, then approve
            // locally while the rest of the remote frame is still withheld.
            assert!(futures_util::poll!(exchange.as_mut()).is_pending());
            decision.send_replace(Some(true));
            assert!(futures_util::poll!(exchange.as_mut()).is_pending());
            assert!(matches!(
                transport::read_secure(&mut remote_stream, &mut remote_secure)
                    .await
                    .unwrap(),
                WireMessage::PairDecision { accepted: true }
            ));
            remote_stream.write_all(&approval[partial..]).await.unwrap();
            let result = tokio::time::timeout(Duration::from_secs(1), exchange)
                .await
                .expect("approval frame stalled after local confirmation");
            assert_eq!(result, Ok(true), "frame split at byte {partial}");

            // Approval must leave the next encrypted protocol frame intact.
            transport::send_secure(
                &mut remote_stream,
                &mut remote_secure,
                &WireMessage::Ping { sent_at: 19 },
            )
            .await
            .unwrap();
            assert!(matches!(
                transport::read_secure(&mut local_stream, &mut local_secure)
                    .await
                    .unwrap(),
                WireMessage::Ping { sent_at: 19 }
            ));
        }
    }
}
