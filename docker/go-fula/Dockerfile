FROM golang:latest as BuildStage

WORKDIR /go-fula

COPY ./go-fula/go.mod .
COPY ./go-fula/go.sum .
RUN  go mod download -x

COPY ./go-fula/ .
RUN go build -o /app ./cmd/blox 

FROM alpine:latest
COPY --from=BuildStage /app app
USER nonroot:nonroot
ENTRYPOINT ["/app"]


