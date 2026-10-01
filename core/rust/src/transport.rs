use crate::model::{WireMessage, MAX_FRAME_BYTES};
use snow::{HandshakeState, TransportState};
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{mpsc, watch, Mutex},
};

pub async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Vec<u8>, String> {
    let mut size = [0u8; 4];
    reader
        .read_exact(&mut size)
        .await
        .map_err(|e| format!("Device connection closed while reading a frame: {e}"))?;
    let size = u32::from_be_bytes(size) as usize;
    if size == 0 || size > MAX_FRAME_BYTES {
        return Err("Device sent a frame outside the 64 KiB protocol limit".into());
    }
    let mut frame = vec![0; size];
    reader
        .read_exact(&mut frame)
        .await
        .map_err(|e| format!("Device connection closed while reading a frame: {e}"))?;
    Ok(frame)
}

pub async fn write_frame<W: AsyncWrite + Unpin>(
    writer: &mut W,
    frame: &[u8],
) -> Result<(), String> {
    if frame.is_empty() || frame.len() > MAX_FRAME_BYTES {
        return Err("Outgoing frame exceeds the 64 KiB protocol limit".into());
    }
    writer
        .write_all(&(frame.len() as u32).to_be_bytes())
        .await
        .map_err(|e| format!("Could not write a device frame: {e}"))?;
    writer
        .write_all(frame)
        .await
        .map_err(|e| format!("Could not write a device frame: {e}"))?;
    writer
        .flush()
        .await
        .map_err(|e| format!("Could not flush a device frame: {e}"))
}

pub async fn send_json<W: AsyncWrite + Unpin>(
    writer: &mut W,
    value: &impl serde::Serialize,
) -> Result<(), String> {
    let bytes =
        serde_json::to_vec(value).map_err(|e| format!("Could not encode protocol message: {e}"))?;
    write_frame(writer, &bytes).await
}

pub async fn read_json<R: AsyncRead + Unpin, T: serde::de::DeserializeOwned>(
    reader: &mut R,
) -> Result<T, String> {
    let frame = read_frame(reader).await?;
    serde_json::from_slice(&frame).map_err(|_| "Device sent an invalid protocol message".into())
}

pub async fn noise_handshake<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    mut state: HandshakeState,
) -> Result<(TransportState, Vec<u8>, Vec<u8>), String> {
    let mut buffer = vec![0u8; MAX_FRAME_BYTES];
    while !state.is_handshake_finished() {
        if state.is_my_turn() {
            let length = state
                .write_message(&[], &mut buffer)
                .map_err(|e| format!("Secure pairing handshake failed: {e}"))?;
            write_frame(stream, &buffer[..length]).await?;
        } else {
            let frame = read_frame(stream).await?;
            state
                .read_message(&frame, &mut buffer)
                .map_err(|e| format!("Secure pairing handshake authentication failed: {e}"))?;
        }
    }
    let remote_static = state
        .get_remote_static()
        .ok_or_else(|| "Secure pairing did not authenticate a device identity".to_string())?
        .to_vec();
    let handshake_hash = state.get_handshake_hash().to_vec();
    let transport = state
        .into_transport_mode()
        .map_err(|e| format!("Secure pairing could not enter encrypted mode: {e}"))?;
    Ok((transport, remote_static, handshake_hash))
}

fn encrypt(state: &mut TransportState, message: &WireMessage) -> Result<Vec<u8>, String> {
    let input = serde_json::to_vec(message)
        .map_err(|e| format!("Could not encode secure protocol message: {e}"))?;
    if input.len() + 16 > MAX_FRAME_BYTES {
        return Err("Secure protocol message exceeds its frame limit".into());
    }
    let mut output = vec![0u8; input.len() + 64];
    let len = state
        .write_message(&input, &mut output)
        .map_err(|e| format!("Could not encrypt protocol message: {e}"))?;
    output.truncate(len);
    Ok(output)
}

fn decrypt(state: &mut TransportState, frame: &[u8]) -> Result<WireMessage, String> {
    let mut output = vec![0u8; MAX_FRAME_BYTES];
    let len = state
        .read_message(frame, &mut output)
        .map_err(|e| format!("Secure device message authentication failed: {e}"))?;
    serde_json::from_slice(&output[..len])
        .map_err(|_| "Secure device sent an invalid protocol message".into())
}

pub async fn send_secure<W: AsyncWrite + Unpin>(
    writer: &mut W,
    state: &mut TransportState,
    message: &WireMessage,
) -> Result<(), String> {
    let frame = encrypt(state, message)?;
    write_frame(writer, &frame).await
}

pub async fn read_secure<R: AsyncRead + Unpin>(
    reader: &mut R,
    state: &mut TransportState,
) -> Result<WireMessage, String> {
    let frame = read_frame(reader).await?;
    decrypt(state, &frame)
}

pub type Outbound = mpsc::Sender<WireMessage>;

/// Own every task for one authenticated connection. A failed reader, writer,
/// handler, initial catch-up, or explicit revocation tears down the whole socket.
/// Replacement sessions have separate generations so an old close cannot erase
/// a newer online connection.
pub async fn start_peer<S: AsyncRead + AsyncWrite + Send + Unpin + 'static>(
    core: Arc<crate::Core>,
    peer_id: String,
    stream: S,
    state: TransportState,
    route: &'static str,
    session: Vec<u8>,
) {
    let (reader, writer) = tokio::io::split(stream);
    let state = Arc::new(Mutex::new(state));
    let (incoming_tx, mut incoming_rx) = mpsc::channel::<Result<WireMessage, String>>(32);
    let (outgoing_tx, mut outgoing_rx) = mpsc::channel::<WireMessage>(32);
    let (cancel_tx, mut cancelled) = watch::channel(false);
    let heartbeat_outbound = outgoing_tx.clone();
    let Ok(generation) = core
        .register_connection(peer_id.clone(), outgoing_tx, cancel_tx, route, session)
        .await
    else {
        return;
    };

    // These futures are owned by this session. Cancelling the session drops
    // both socket halves and every worker; no detached task retains the profile.
    let reader = reader_loop(reader, state.clone(), incoming_tx);
    let writer = writer_loop(writer, state, &mut outgoing_rx);
    let catchup = core.sync_peer(&peer_id, generation);
    let handler = async {
        while let Some(event) = incoming_rx.recv().await {
            core.handle_wire(&peer_id, event?).await?;
        }
        Ok::<(), String>(())
    };
    let heartbeat = async {
        let mut interval = tokio::time::interval(Duration::from_secs(15));
        interval.tick().await;
        loop {
            interval.tick().await;
            if !matches!(
                tokio::time::timeout(
                    Duration::from_secs(15),
                    heartbeat_outbound.send(WireMessage::Ping {
                        sent_at: crate::store::now_ms()
                    })
                )
                .await,
                Ok(Ok(()))
            ) {
                return Err::<(), String>("Device heartbeat could not be sent".into());
            }
        }
        #[allow(unreachable_code)]
        Ok::<(), String>(())
    };
    tokio::pin!(reader, writer, catchup, handler, heartbeat);
    let mut catchup_finished = false;
    loop {
        if *cancelled.borrow() {
            break;
        }
        tokio::select! {
            _ = cancelled.changed() => break,
            _ = &mut reader => break,
            _ = &mut writer => break,
            _ = &mut handler => break,
            _ = &mut heartbeat => break,
            result = &mut catchup, if !catchup_finished => {
                catchup_finished = true;
                if result.is_err() { break; }
            }
        }
    }
    core.unregister_connection(&peer_id, generation);
}

async fn reader_loop<R: AsyncRead + Unpin>(
    mut reader: R,
    state: Arc<Mutex<TransportState>>,
    incoming: mpsc::Sender<Result<WireMessage, String>>,
) {
    loop {
        let frame =
            match tokio::time::timeout(Duration::from_secs(45), read_frame(&mut reader)).await {
                Ok(Ok(frame)) => frame,
                error => {
                    let e = match error {
                        Ok(Err(error)) => error,
                        _ => "Device connection stopped responding".to_string(),
                    };
                    let _ = incoming.send(Err(e)).await;
                    break;
                }
            };
        let message = {
            let mut state = state.lock().await;
            decrypt(&mut state, &frame)
        };
        if incoming.send(message).await.is_err() {
            break;
        }
    }
}

async fn writer_loop<W: AsyncWrite + Unpin>(
    mut writer: W,
    state: Arc<Mutex<TransportState>>,
    outgoing: &mut mpsc::Receiver<WireMessage>,
) {
    while let Some(message) = outgoing.recv().await {
        let frame = {
            let mut state = state.lock().await;
            match encrypt(&mut state, &message) {
                Ok(frame) => frame,
                Err(_) => break,
            }
        };
        if !matches!(
            tokio::time::timeout(Duration::from_secs(15), write_frame(&mut writer, &frame)).await,
            Ok(Ok(()))
        ) {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{crypto, secret::IdentityMaterial};

    async fn session(psk: Option<[u8; 32]>) -> (TransportState, TransportState) {
        let a = IdentityMaterial::generate().unwrap();
        let b = IdentityMaterial::generate().unwrap();
        let sa =
            crypto::build_handshake(&a.static_private, psk.as_ref(), b"test-v1", true).unwrap();
        let sb =
            crypto::build_handshake(&b.static_private, psk.as_ref(), b"test-v1", false).unwrap();
        let (mut socket_a, mut socket_b) = tokio::io::duplex(2048);
        let (a_result, b_result) = tokio::join!(
            noise_handshake(&mut socket_a, sa),
            noise_handshake(&mut socket_b, sb)
        );
        let (a_transport, remote_b, hash_a) = a_result.unwrap();
        let (b_transport, remote_a, hash_b) = b_result.unwrap();
        assert_eq!(remote_a, a.static_public);
        assert_eq!(remote_b, b.static_public);
        assert_eq!(hash_a, hash_b);
        (a_transport, b_transport)
    }

    #[tokio::test]
    async fn real_noise_pairing_encrypts_and_authenticates_both_directions() {
        let (mut a, mut b) = session(Some([7; 32])).await;
        let message = WireMessage::Hello {
            version: 1,
            mesh_id: "synthetic-mesh".into(),
            device_id: "synthetic-device".into(),
            device_name: "distinctive fake secret string".into(),
            static_public: "public".into(),
            item_signing_public: String::new(),
            platform: String::new(),
            capabilities: Vec::new(),
            endpoint: "127.0.0.1:1".into(),
        };
        let encrypted = encrypt(&mut a, &message).unwrap();
        assert!(!encrypted
            .windows(23)
            .any(|window| window == b"distinctive fake secret "));
        assert!(matches!(
            decrypt(&mut b, &encrypted).unwrap(),
            WireMessage::Hello { .. }
        ));
        // Noise sequence nonces reject replay within the live session.
        assert!(decrypt(&mut b, &encrypted).is_err());
        let reply = encrypt(&mut b, &WireMessage::Pong { sent_at: 19 }).unwrap();
        assert!(matches!(
            decrypt(&mut a, &reply).unwrap(),
            WireMessage::Pong { sent_at: 19 }
        ));
    }

    #[tokio::test]
    async fn altered_ciphertext_is_rejected() {
        let (mut a, mut b) = session(None).await;
        let mut encrypted = encrypt(&mut a, &WireMessage::Ping { sent_at: 1 }).unwrap();
        encrypted[0] ^= 1;
        assert!(decrypt(&mut b, &encrypted).is_err());
    }

    #[tokio::test]
    async fn wrong_pairing_ticket_cannot_complete_handshake() {
        let a = IdentityMaterial::generate().unwrap();
        let b = IdentityMaterial::generate().unwrap();
        let sa =
            crypto::build_handshake(&a.static_private, Some(&[1; 32]), b"test-v1", true).unwrap();
        let sb =
            crypto::build_handshake(&b.static_private, Some(&[2; 32]), b"test-v1", false).unwrap();
        let (mut socket_a, mut socket_b) = tokio::io::duplex(2048);
        let (_, responder) = tokio::join!(
            noise_handshake(&mut socket_a, sa),
            noise_handshake(&mut socket_b, sb)
        );
        assert!(responder.is_err());
    }

    #[tokio::test]
    async fn frame_rejects_zero_oversize_and_truncated_input() {
        for bytes in [0u32.to_be_bytes(), 65536u32.to_be_bytes()] {
            assert!(read_frame(&mut bytes.as_slice()).await.is_err());
        }
        assert!(read_frame(&mut &[0u8, 0, 0, 4, 1, 2][..]).await.is_err());
        let mut output = Vec::new();
        assert!(write_frame(&mut output, &[]).await.is_err());
        assert!(write_frame(&mut output, &vec![0; 65536]).await.is_err());
        write_frame(&mut output, &vec![42; 65535]).await.unwrap();
        assert_eq!(
            read_frame(&mut output.as_slice()).await.unwrap().len(),
            65535
        );
    }

    #[tokio::test]
    async fn escaped_json_is_checked_against_ciphertext_limit() {
        let (mut a, _) = session(None).await;
        let message = WireMessage::Hello {
            version: 1,
            mesh_id: "m".into(),
            device_id: "d".into(),
            device_name: "\u{0000}".repeat(32 * 1024),
            static_public: "p".into(),
            item_signing_public: String::new(),
            platform: String::new(),
            capabilities: Vec::new(),
            endpoint: "e".into(),
        };
        assert!(encrypt(&mut a, &message).is_err());
    }
}
