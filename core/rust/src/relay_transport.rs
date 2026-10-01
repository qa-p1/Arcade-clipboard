//! A bounded stream adapter for the opaque relay. Noise runs over the resulting
//! byte stream exactly as it does over a direct TCP socket.
use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio_tungstenite::tungstenite::Message;

pub fn validate_relay_url(value: &str) -> Result<(), String> {
    if value.is_empty() {
        return Ok(());
    }
    if value.len() > 2048 {
        return Err("Relay address is too long".into());
    }
    let url = url::Url::parse(value).map_err(|_| "Relay address is invalid".to_string())?;
    let local = url.host_str().is_some_and(|host| {
        host == "localhost"
            || host
                .parse::<std::net::IpAddr>()
                .is_ok_and(|ip| ip.is_loopback())
    });
    if url.scheme() != "wss" && !(url.scheme() == "ws" && local) {
        return Err(
            "Relay address must use wss://; local development can use ws://localhost".into(),
        );
    }
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
    {
        return Err("Relay address must contain only the server address and optional port".into());
    }
    Ok(())
}

pub async fn connect(
    base: &str,
    route: &str,
    token: &str,
    slot: Option<&str>,
) -> Result<DuplexStream, String> {
    validate_relay_url(base)?;
    let path = if let Some(slot) = slot {
        format!("/v1/relay/paired/{route}/{slot}")
    } else {
        format!("/v1/relay/{route}")
    };
    let endpoint = format!("{}{path}?token={token}&ready=1", base.trim_end_matches('/'));
    let (mut socket, _) = tokio_tungstenite::connect_async(&endpoint)
        .await
        .map_err(|_| "Could not connect to the encrypted relay".to_string())?;
    // No Noise bytes are sent until both relay slots exist. The relay's ready
    // marker is transport coordination only and is never authentication.
    loop {
        match socket.next().await {
            Some(Ok(Message::Text(value))) if value == "arcade-ready-v1" => break,
            Some(Ok(Message::Ping(bytes))) => {
                socket
                    .send(Message::Pong(bytes))
                    .await
                    .map_err(|_| "Relay connection closed".to_string())?;
            }
            Some(Ok(Message::Pong(_))) => {}
            _ => return Err("Relay rendezvous closed before the other device connected".into()),
        }
    }
    let (client, tunnel) = tokio::io::duplex(128 * 1024);
    let (mut input, mut output) = tokio::io::split(tunnel);
    let (mut sink, mut source) = socket.split();
    tokio::spawn(async move {
        let receive = async {
            while let Some(Ok(message)) = source.next().await {
                match message {
                    Message::Binary(bytes) if bytes.len() <= 64 * 1024 => {
                        if output.write_all(&bytes).await.is_err() {
                            break;
                        }
                    }
                    Message::Pong(_) | Message::Ping(_) => {}
                    _ => break,
                }
            }
        };
        let send = async {
            let mut buffer = vec![0; 32 * 1024];
            while let Ok(length) = input.read(&mut buffer).await {
                if length == 0 {
                    break;
                }
                if !matches!(
                    tokio::time::timeout(
                        Duration::from_secs(15),
                        sink.send(Message::Binary(buffer[..length].to_vec().into()))
                    )
                    .await,
                    Ok(Ok(()))
                ) {
                    break;
                }
            }
            let _ = sink.close().await;
        };
        tokio::pin!(receive, send);
        tokio::select! { _ = &mut receive => {}, _ = &mut send => {} }
    });
    Ok(client)
}
