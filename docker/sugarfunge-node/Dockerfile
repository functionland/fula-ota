FROM rustlang/rust:nightly-alpine AS builder

RUN rustup target add wasm32-unknown-unknown

RUN apk add --update --no-cache \
        clang \
        llvm \
        cmake \
        protobuf-c-dev \
        protobuf-dev \
        musl-dev \
        build-base \
        gcc \
        libc-dev \
        python3-dev

# Find the installed version of the library and create a symlink if needed
RUN LIBCLANG_PATH=$(find /usr/lib -name 'libclang.so*') && \
    ln -s $LIBCLANG_PATH /usr/lib/libclang.so.12

# Set the LD_LIBRARY_PATH environment variable
ENV LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/lib

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
