FROM golang:1.22 AS BuildStage

WORKDIR /

COPY ./ipfs-cluster/go.mod .
COPY ./ipfs-cluster/go.sum .

RUN  go mod download -x

COPY ./ipfs-cluster/ .
RUN CGO_ENABLED=0 GOOS=linux go build -o /ipfs-cluster-service ./cmd/ipfs-cluster-service
RUN CGO_ENABLED=0 GOOS=linux go build -o /ipfs-cluster-follow ./cmd/ipfs-cluster-follow
RUN CGO_ENABLED=0 GOOS=linux go build -o /ipfs-cluster-ctl ./cmd/ipfs-cluster-ctl

FROM alpine:3.17

RUN apk update && apk add hostapd iw wireless-tools networkmanager-wifi networkmanager-cli jq dhcp iptables curl --no-cache

WORKDIR /
COPY --from=BuildStage /ipfs-cluster-service /usr/local/bin/ipfs-cluster-service
COPY --from=BuildStage /ipfs-cluster-follow /usr/local/bin/ipfs-cluster-follow
COPY --from=BuildStage /ipfs-cluster-ctl /usr/local/bin/ipfs-cluster-ctl
COPY --from=BuildStage /ipfs-cluster-ctl /usr/local/bin/ipfs-cluster-ctl

ENV IPFS_CLUSTER_CONSENSUS crdt

EXPOSE 9094
EXPOSE 9095
EXPOSE 9096
