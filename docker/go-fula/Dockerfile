FROM golang:latest as BuildStage

WORKDIR /go-fula

COPY ./go-fula/go.mod .
COPY ./go-fula/go.sum .
RUN  go mod download -x

COPY ./go-fula/ .
RUN go build -o /app ./cmd/blox 

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /
COPY --from=BuildStage /app /app
ENTRYPOINT ["/app"]


