use std::{net::SocketAddr, time::Duration};

use arcade_relay::{MAX_FRAME_BYTES, RelayState, serve};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::{SinkExt, StreamExt};
use tokio::{net::TcpListener, task::JoinHandle, time::timeout};
use tokio_tungstenite::{connect_async, tungstenite::Message};

async fn start_server() -> (SocketAddr, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move {
        serve(listener, RelayState::new()).await.unwrap();
    });
    (address, task)
}

fn endpoint(address: SocketAddr, route: &str, token: &[u8; 32]) -> String {
    format!(
        "ws://{address}/v1/relay/{route}?token={}",
        URL_SAFE_NO_PAD.encode(token)
    )
}

fn paired_endpoint(address: SocketAddr, route: &str, slot: &str, token: &[u8; 32]) -> String {
    format!(
        "ws://{address}/v1/relay/paired/{route}/{slot}?token={}",
        URL_SAFE_NO_PAD.encode(token)
    )
}

#[tokio::test]
async fn invite_tunnel_preserves_binary_messages_and_rejects_replay() {
    let (address, server) = start_server().await;
    let token = [31_u8; 32];
    let url = endpoint(address, "0123456789abcdef", &token);
    let (mut first, _) = connect_async(&url).await.unwrap();
    let (mut second, _) = connect_async(&url).await.unwrap();

    let payload = vec![0x5a; MAX_FRAME_BYTES];
    first
        .send(Message::Binary(payload.clone().into()))
        .await
        .unwrap();
    let received = timeout(Duration::from_secs(2), second.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(matches!(received, Message::Binary(bytes) if bytes.as_ref() == payload));

    let replay = connect_async(&url).await.unwrap_err();
    assert!(matches!(
        replay,
        tokio_tungstenite::tungstenite::Error::Http(response)
            if response.status() == tokio_tungstenite::tungstenite::http::StatusCode::TOO_MANY_REQUESTS
    ));

    first.close(None).await.unwrap();
    server.abort();
}

#[tokio::test]
async fn invalid_ticket_cannot_join_or_consume_the_legitimate_route() {
    let (address, server) = start_server().await;
    let route = "fedcba9876543210";
    let valid = [41_u8; 32];
    let invalid = [42_u8; 32];
    let url = endpoint(address, route, &valid);
    let bad_url = endpoint(address, route, &invalid);

    let (_first, _) = connect_async(&url).await.unwrap();
    let rejected = connect_async(&bad_url).await.unwrap_err();
    assert!(matches!(
        rejected,
        tokio_tungstenite::tungstenite::Error::Http(response)
            if response.status() == tokio_tungstenite::tungstenite::http::StatusCode::UNAUTHORIZED
    ));
    let (_second, _) = connect_async(&url).await.unwrap();
    server.abort();
}

#[tokio::test]
async fn paired_routes_reconnect_only_with_matching_token_and_distinct_slots() {
    let (address, server) = start_server().await;
    let route = "00112233445566778899aabbccddeeff";
    let token = [51_u8; 32];
    let wrong_token = [52_u8; 32];

    let (mut a, _) = connect_async(&paired_endpoint(address, route, "a", &token))
        .await
        .unwrap();
    let (mut b, _) = connect_async(&paired_endpoint(address, route, "b", &token))
        .await
        .unwrap();
    a.send(Message::Ping(vec![7].into())).await.unwrap();
    let pong = timeout(Duration::from_secs(2), a.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(matches!(pong, Message::Pong(bytes) if bytes.as_ref() == [7]));

    let duplicate = connect_async(&paired_endpoint(address, route, "a", &token))
        .await
        .unwrap_err();
    assert!(matches!(
        duplicate,
        tokio_tungstenite::tungstenite::Error::Http(response)
            if response.status() == tokio_tungstenite::tungstenite::http::StatusCode::CONFLICT
    ));
    let wrong = connect_async(&paired_endpoint(address, route, "b", &wrong_token))
        .await
        .unwrap_err();
    assert!(matches!(
        wrong,
        tokio_tungstenite::tungstenite::Error::Http(response)
            if response.status() == tokio_tungstenite::tungstenite::http::StatusCode::UNAUTHORIZED
    ));

    // Closing either socket tears down the live tunnel. The paired capability
    // can then rendezvous again, with the same a/b slot assignment.
    a.send(Message::Close(None)).await.unwrap();
    timeout(Duration::from_secs(2), b.next()).await.unwrap();
    tokio::time::sleep(Duration::from_millis(30)).await;
    let (mut a2, _) = connect_async(&paired_endpoint(address, route, "a", &token))
        .await
        .unwrap();
    let (mut b2, _) = connect_async(&paired_endpoint(address, route, "b", &token))
        .await
        .unwrap();
    let payload = b"reconnected".to_vec();
    a2.send(Message::Binary(payload.clone().into())).await.unwrap();
    let received = timeout(Duration::from_secs(2), b2.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(matches!(received, Message::Binary(bytes) if bytes.as_ref() == payload));
    server.abort();
}

#[tokio::test]
async fn oversized_message_closes_tunnel_without_forwarding() {
    let (address, server) = start_server().await;
    let token = [61_u8; 32];
    let url = endpoint(address, "aabbccddeeff0011", &token);
    let (mut first, _) = connect_async(&url).await.unwrap();
    let (mut second, _) = connect_async(&url).await.unwrap();
    first
        .send(Message::Binary(vec![0; MAX_FRAME_BYTES + 1].into()))
        .await
        .unwrap();
    let received = timeout(Duration::from_secs(2), second.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(matches!(received, Message::Close(_)));
    server.abort();
}
