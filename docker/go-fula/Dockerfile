FROM golang:1.21 AS BuildStage

WORKDIR /go-fula

COPY ./go-fula/go.mod .
COPY ./go-fula/go.sum .

RUN  go mod download -x

COPY ./go-fula/ .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app ./cmd/blox 
RUN CGO_ENABLED=0 GOOS=linux go build -o /wap ./wap/cmd
RUN CGO_ENABLED=0 GOOS=linux go build -o /initipfs ./modules/initipfs

FROM alpine:3.17

RUN apk update && apk add hostapd iw wireless-tools networkmanager-wifi networkmanager-cli dhcp iptables curl --no-cache
RUN apk add mergerfs --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing --no-cache

WORKDIR /
COPY --from=BuildStage /app /app
COPY --from=BuildStage /wap /wap
COPY --from=BuildStage /initipfs /initipfs


COPY ./go-fula.sh /go-fula.sh
RUN chmod +x /go-fula.sh
EXPOSE 40001
EXPOSE 5001
CMD /go-fula.sh
