FROM golang:latest as BuildStage

WORKDIR /go-fula
COPY ./go-fula ./go-fula
RUN cd go-fula && go build -o /app ./cmd/blox 

FROM alpine:latest
COPY --from=BuildStage /app app
USER nonroot:nonroot
ENTRYPOINT ["/app"]


