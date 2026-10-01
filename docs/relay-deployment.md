# Host the internet relay

The included Rust service forwards encrypted WebSocket traffic between two connected devices. You need a Linux server or container host that stays online, Docker with Compose, and a domain/subdomain. A domain connected to Cloudflare supplies DNS/proxying; it does not run this Rust service by itself.

## Server and DNS

1. On your server, clone this repository into a durable directory.
2. In Cloudflare DNS, add an A record for relay pointing to the server's IPv4 address. Add AAAA only if IPv6 actually reaches that server.
3. Start with DNS only while Caddy obtains its certificate. Allow TCP 80 and 443 through the server/provider firewall. The Rust port 8787 is internal and must not be exposed publicly.
4. From the repository root, copy deploy/relay/.env.example to deploy/relay/.env and replace RELAY_DOMAIN and ACME_EMAIL with your values.

~~~bash
cp deploy/relay/.env.example deploy/relay/.env
# Edit deploy/relay/.env before running the next command.
docker compose --env-file deploy/relay/.env -f deploy/relay/compose.yml up -d --build
docker compose --env-file deploy/relay/.env -f deploy/relay/compose.yml ps
curl --fail https://relay.example.com/healthz
~~~

Use your actual subdomain in the curl command. A healthy response contains status ok and the relay protocol version. Caddy obtains/renews TLS certificates and handles WebSocket upgrades automatically. Its certificate data is kept in a named Docker volume. These defaults publish only the reverse proxy and run the relay without root, write access or Linux capabilities. See [Caddy reverse proxy documentation](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).

Once HTTPS works, you can enable Cloudflare proxying and choose SSL/TLS Full (strict). Cloudflare supports [proxied WebSockets](https://developers.cloudflare.com/network/websockets/). Do not put an interactive Cloudflare Access login or browser challenge in front of /v1/relay/*; native clients cannot complete it. Exclude those routes from caching. WebSocket reconnection is handled by the clients, including after proxy/server restarts.

## Connect the apps

Set the relay URL in Settings on **each device** to wss://relay.example.com, with no /v1 suffix. Configure it before making an internet pairing invite. The app appends its own pairing and paired-device routes. Existing trusted devices derive their private rendezvous credentials from their keys.

On separate networks, keep both apps running and add a clip on one device. The other should receive it in history. iPhone synchronization still needs the main app awake; its Share extension queues local content for import on resume.

The relay never decrypts items, keeps an offline message queue or acknowledges delivery. Both endpoints must connect. Client encrypted history supplies catch-up after reconnect. LAN connections remain preferred when available.

## Operations

~~~bash
docker compose --env-file deploy/relay/.env -f deploy/relay/compose.yml logs --tail=100
docker compose --env-file deploy/relay/.env -f deploy/relay/compose.yml restart
# After pulling updated source:
docker compose --env-file deploy/relay/.env -f deploy/relay/compose.yml up -d --build
~~~

Relay restarts discard only in-memory rendezvous state. Client identities and history stay on the devices. Preserve the caddy_data volume to retain certificates; do not add -v to a routine compose down.

The service allows 512 simultaneous sockets and 120 upgrades per observed TCP peer per minute. Direct deployments default to 16 sockets per IP. Compose raises that limit to 512 because all traffic reaches the relay through Caddy's single address. Upgrade throttling is still aggregate behind this proxy. For a large/public service, apply per-client limits at your trusted edge and protect direct access to the origin. Forwarded headers do not bypass the Rust limits.

Pairing/route bearer tickets use query strings. The supplied Caddy config disables HTTP access/error request logging to avoid storing tickets. Keep query strings out of any Cloudflare log export or other proxy/monitoring system you add. No Cloudflare API token or Apple signing material belongs in this repository.

The Docker configuration is supplied for deployment; no public server has been provisioned from this workspace.
