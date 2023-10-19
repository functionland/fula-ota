FROM rustlang/rust:nightly AS builder

RUN rustup target add wasm32-unknown-unknown

RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        libclang-dev \
        cmake \
        protobuf-compiler \
        g++ pkg-config libx11-dev libasound2-dev libudev-dev \
        libssl-dev git build-essential curl \
        openssl

# OpenSSL1.1
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y perl gcc make zlib1g-dev libfindbin-libs-perl libasound2 netcat
# Set PERL_MM_USE_DEFAULT to make module installation non-interactive
ENV PERL_MM_USE_DEFAULT=1
RUN wget https://www.openssl.org/source/openssl-1.1.1s.tar.gz && \
    tar -xvzf openssl-1.1.1s.tar.gz && \
    cd openssl-1.1.1s/ && \
    ./Configure linux-aarch64 --prefix=/usr/local/ssl --openssldir=/usr/local/ssl shared zlib && \
    make -j$(nproc) && \
    make install && \
    echo 'LD_LIBRARY_PATH=/usr/local/ssl/lib:${LD_LIBRARY_PATH}' >> /etc/environment && \
    cd .. && \
    rm -rf openssl-1.1.1s.tar.gz openssl-1.1.1s


WORKDIR /sugarfunge-node
COPY ./sugarfunge-node /sugarfunge-node
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

COPY --from=builder /sugarfunge-node/target/release/sugarfunge-node /sugarfunge-node
COPY --from=builder /sugarfunge-node/customSpecRaw.json /customSpecRaw.json
COPY --from=builder /sugarfunge-api/target/release/sugarfunge-api /sugarfunge-api
COPY --from=builder /proof-engine/target/release/proof-engine /proof-engine
COPY --from=builder /usr/local/ssl/lib/libssl.so.1.1 /lib/aarch64-linux-gnu/libssl.so.1.1
COPY --from=builder /usr/local/ssl/lib/libcrypto.so.1.1 /lib/aarch64-linux-gnu/libcrypto.so.1.1

COPY ./run_node.sh /run_node.sh

RUN chmod +x /run_node.sh
CMD /run_node.sh


