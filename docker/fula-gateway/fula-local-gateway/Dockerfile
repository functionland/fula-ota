FROM rust:1.85-bookworm AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
COPY . .
# Remove local dev overrides so Docker build uses git dependencies
RUN rm -rf .cargo/
ENV CARGO_BUILD_JOBS=2
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates libssl3 curl && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/fula-gateway /usr/local/bin/fula-gateway
RUN useradd -r -s /bin/false fula
USER fula
EXPOSE 9000
HEALTHCHECK --interval=30s --timeout=5s CMD curl -f http://localhost:9000/healthz || exit 1
ENV FULA_HOST=0.0.0.0 FULA_PORT=9000 IPFS_API_URL=http://127.0.0.1:5001 RUST_LOG=info
ENTRYPOINT ["fula-gateway"]
