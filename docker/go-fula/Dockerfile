FROM golang:1.19 as BuildStage

WORKDIR /go-fula

COPY ./go-fula/go.mod .
COPY ./go-fula/go.sum .
RUN  go mod download -x

COPY ./go-fula/ .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app ./cmd/blox 

FROM alpine:3.17

RUN apk update && apk add hostapd iw wireless-tools networkmanager-wifi networkmanager-cli dhcp iptables --no-cache
WORKDIR /
COPY --from=BuildStage /app /app
EXPOSE 40001
CMD ["/app"]


