FROM rustlang/rust:nightly AS builder

RUN rustup target add wasm32-unknown-unknown

RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        libclang-dev \
        cmake \
        protobuf-compiler \
        g++ pkg-config libx11-dev libasound2-dev libudev-dev \
        libssl-dev git build-essential curl

WORKDIR /
COPY ./union-drive.sh /union-drive.sh
RUN chmod +x /union-drive.sh

WORKDIR /sugarfunge
COPY ./sugarfunge-node /sugarfunge
RUN cargo fetch
RUN cargo build --locked --release

WORKDIR /sugarfunge-api
COPY ./sugarfunge-api /sugarfunge-api
RUN cargo fetch
RUN cargo build --locked --release

WORKDIR /proof-engine
COPY ./proof-engine /proof-engine
RUN cargo fetch
RUN cargo build --locked --features headless --release

FROM ubuntu:latest

COPY --from=builder /sugarfunge/target/release/sugarfunge-node /sugarfunge-node
COPY --from=builder /sugarfunge-api/target/release/sugarfunge-api /sugarfunge-api
COPY --from=builder /proof-engine/target/release/proof-engine /proof-engine

COPY ./run_node.sh /run_node.sh

RUN chmod +x /run_node.sh
CMD /run_node.sh


