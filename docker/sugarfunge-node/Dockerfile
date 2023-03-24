FROM rustlang/rust:nightly AS builder

RUN rustup target add wasm32-unknown-unknown

RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        libclang-dev \
        cmake \
        protobuf-compiler

WORKDIR /sugarfunge

COPY ./sugarfunge-node /sugarfunge
RUN cargo fetch
RUN cargo build --locked --release

WORKDIR /sugarfunge-api
COPY ./sugarfunge-api /sugarfunge-api
RUN cargo fetch
RUN cargo build --locked --release

RUN ls /sugarfunge-api/

FROM alpine:3.17

COPY --from=builder /sugarfunge/target/release/sugarfunge-node /sugarfunge-node
COPY --from=builder /sugarfunge-api/target/release/sugarfunge-api /sugarfunge-api

COPY ./run_node.sh /run_node.sh

CMD /run_node.sh

#ENTRYPOINT ["/sugarfunge-node"]ta
#CMD ["--dev", "--pruning", "archive", "--tmp"]
