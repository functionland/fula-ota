# fula-ingest — verified byte ingress (Phase 2).
# Build (repo root): docker build -f docker/fula-ingest/Dockerfile -t functionland/fula-ingest:latest docker/fula-ingest
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true
COPY . .
RUN go mod tidy && CGO_ENABLED=0 go build -o /fula-ingest .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /fula-ingest /usr/local/bin/fula-ingest
EXPOSE 3601
ENTRYPOINT ["fula-ingest"]
