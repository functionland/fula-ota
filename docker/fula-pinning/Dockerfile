FROM golang:1.25-alpine AS builder

WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download -x 2>/dev/null || true
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /fula-pinning .

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
COPY --from=builder /fula-pinning /fula-pinning
EXPOSE 3501
CMD ["/fula-pinning"]
