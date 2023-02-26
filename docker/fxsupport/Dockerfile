FROM alpine:3.17

WORKDIR /linux
COPY ./docker-compose.yml .
COPY ./docker.env .
RUN apk add curl
WORKDIR /

