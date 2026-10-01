FROM rust:1.98.1-bookworm AS builder
WORKDIR /source
COPY Cargo.toml Cargo.lock ./
COPY core/rust ./core/rust
COPY services/relay ./services/relay
COPY tests/driver ./tests/driver
RUN cargo build --release --locked -p arcade_relay

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 arcade \
    && useradd --uid 10001 --gid arcade --no-create-home --shell /usr/sbin/nologin arcade
COPY --from=builder /source/target/release/arcade_relay /usr/local/bin/arcade-relay
USER 10001:10001
ENV ARCADE_RELAY_BIND=0.0.0.0:8787
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail --silent http://127.0.0.1:8787/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/arcade-relay"]
