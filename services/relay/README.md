# Arcade Clipboard relay

This service carries an already encrypted client stream between two live
devices. It does not store clipboard data, understand protocol messages, or
hold client decryption keys. The relay is a transport path; Noise authentication
and the pairing confirmation remain client responsibilities.

## Run locally

The service defaults to loopback so a new checkout is not accidentally exposed:

```sh
cargo run -p arcade_relay
curl http://127.0.0.1:8787/healthz
```

To listen on another interface, set `ARCADE_RELAY_BIND`, for example:

```sh
ARCADE_RELAY_BIND=0.0.0.0:8787 cargo run -p arcade_relay
```

For public use, terminate TLS at a trusted reverse proxy and configure clients
with that explicit `wss://` URL. The service itself accepts HTTP/WebSocket and
does not terminate TLS. There is no shared public relay endpoint configured by
this repository.

## Wire contract

All route IDs are 16–80 ASCII alphanumeric, `-`, or `_` characters. Tickets are
exactly 32 random bytes encoded as unpadded base64url. The server hashes tickets
with SHA-256 in memory and does not log request URLs or ticket values.

| Use | Route |
| --- | --- |
| One-time pairing rendezvous | `GET /v1/relay/{session_id}?token={ticket}` |
| Paired-device rendezvous | `GET /v1/relay/paired/{route_id}/{slot}?token={route_token}` |

The invite route permits two connections with the same ticket. Its 120-second
window starts when the first device connects; after both connect, the tunnel
stays open until one disconnects. The relay has no server-issued invite
registry, so it cannot verify the QR's creation timestamp or independently
invalidate an unused, client-generated ticket. The client must locally expire
and consume an invite, and the devices must complete Noise verification and
explicit pairing consent before trusting one another.

After successful pairing, any two trusted members may establish a separate
paired route. Slots `a` and `b` are assigned by device-ID ordering, including
member-to-member synchronization while the creator is offline. Route IDs and
tickets are independently derived from the two devices' contributory X25519
secret, so a public route ID does not reveal its ticket. The service
allows one live socket per slot, drops both sides when either disconnects, and
allows the two holders to reconnect using the same route ID and token. An
unpaired reconnect attempt expires after 120 seconds. Paired-route hashes live
in memory and expire after 10 minutes of inactivity; idle records can also be
evicted when the bounded route table fills. After a service restart both
clients can establish a fresh rendezvous using their retained route credentials.

Each binary WebSocket message is forwarded as one opaque message without
changing its bytes or message boundaries. Text data messages are rejected;
Ping/Pong are handled only as WebSocket keepalive controls. Messages are capped
at 64 KiB. Two bounded frames are queued per direction to propagate
backpressure. There are no offline acknowledgements or relay-side queues. A
device that is offline receives pending ciphertext through the client's local
sync/history storage after reconnect; the relay does not claim delivery.

## Limits and deployment notes

The initial in-memory limits are 512 active connections, 16 active connections
per observed IP by default, 120 upgrade attempts per observed IP per minute, 512 pending
invite rendezvous entries, and 4,096 paired-route records. The service reads
the peer address with Axum `ConnectInfo`; it deliberately ignores
`X-Forwarded-For` so untrusted clients cannot spoof it. Behind a reverse proxy,
the application sees the proxy address. Enforce per-client rate limits at that
trusted proxy, and do not trust arbitrary forwarded headers. Set
ARCADE_RELAY_MAX_CONNECTIONS_PER_IP to a number from 1 to 512 to configure the
connection cap for the actual topology. The supplied Compose deployment uses
512 because Caddy is its only observed peer; the upgrade limit stays aggregate.

The bearer token is in the query string to match the v1 client contract. Reverse
proxies, load balancers, and observability tools must redact query strings from
access logs. The relay does not emit request/access logs by default. Protect the
WebSocket connection with TLS (`wss://`) outside loopback development. The
`/healthz` route reports service readiness and is intentionally unauthenticated.

The service is a single process with in-memory rendezvous state. It provides no
durable queue, horizontal coordination or registered invite issuer. A non-root
Docker image, internal-only Rust service and Caddy HTTPS Compose deployment are
included. Follow [domain and Cloudflare setup](../../docs/relay-deployment.md).
