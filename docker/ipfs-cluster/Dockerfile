# Build stage
FROM golang:1.25 AS buildstage

WORKDIR /go-fula

# Copy go module files and download dependencies
COPY ./ipfs-cluster/go.mod ./ipfs-cluster/go.sum ./
RUN go mod download -x

# Copy the rest of the application source code and build binaries
COPY ./ipfs-cluster/ .
# GOMEMLIMIT caps Go heap to prevent OOM on memory-constrained ARM devices
RUN CGO_ENABLED=0 GOOS=linux GOMEMLIMIT=1536MiB go build -p 1 -o /ipfs-cluster-service ./cmd/ipfs-cluster-service
RUN CGO_ENABLED=0 GOOS=linux GOMEMLIMIT=1536MiB go build -p 1 -o /ipfs-cluster-follow ./cmd/ipfs-cluster-follow
RUN CGO_ENABLED=0 GOOS=linux GOMEMLIMIT=1536MiB go build -p 1 -o /ipfs-cluster-ctl ./cmd/ipfs-cluster-ctl

# Final stage
FROM alpine:3.17

# Install necessary packages in a single RUN command to reduce layers
RUN apk update && apk add --no-cache jq curl

WORKDIR /

# Copy binaries from the build stage to the appropriate location
COPY --from=buildstage /ipfs-cluster-service /usr/local/bin/ipfs-cluster-service
COPY --from=buildstage /ipfs-cluster-follow /usr/local/bin/ipfs-cluster-follow
COPY --from=buildstage /ipfs-cluster-ctl /usr/local/bin/ipfs-cluster-ctl

# Set environment variables
ENV IPFS_CLUSTER_CONSENSUS=crdt

# Expose necessary ports
EXPOSE 9094 9095 9096