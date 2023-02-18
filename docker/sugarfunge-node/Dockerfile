FROM rustlang/rust:nightly AS builder

RUN rustup target add wasm32-unknown-unknown

RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        libclang-dev \
        cmake \
        protobuf-compiler

WORKDIR /sugarfunge

COPY ./sugarfunge-node /sugarfunge

RUN cargo build --locked --release


FROM alpine:latest

COPY --from=builder /sugarfunge/target/release/sugarfunge-node /

ENTRYPOINT ["/sugarfunge-node"]

CMD ["--dev", "--pruning", "archive", "--tmp"]
