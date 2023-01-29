FROM golang:latest as BuildStage

WORKDIR /go-fula

COPY ./go-fula/go.mod .
COPY ./go-fula/go.sum .
RUN  go mod download -x

COPY ./go-fula/ .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app ./cmd/blox 

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /
COPY --from=BuildStage /app /app
EXPOSE 40001
CMD ["/app"]


