FROM golang:1.19 as BuildStage

WORKDIR /go-fula

COPY ./go-fula/go.mod .
COPY ./go-fula/go.sum .
RUN  go mod download -x

COPY ./go-fula/ .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app ./cmd/blox 
RUN CGO_ENABLED=0 GOOS=linux go build -o /wap ./wap/cmd

FROM alpine:3.17

RUN apk update && apk add hostapd iw wireless-tools networkmanager-wifi networkmanager-cli dhcp iptables  unionfs-fuse  inotify-tools --no-cache
WORKDIR /
COPY --from=BuildStage /app /app
COPY --from=BuildStage /wap /wap

COPY ./union-drive.sh /union-drive.sh
RUN chmod +x /union-drive.sh

COPY ./go-fula.sh /go-fula.sh
RUN chmod +x /go-fula.sh
EXPOSE 40001
RUN /go-fula.sh