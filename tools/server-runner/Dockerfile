FROM golang:1.26 AS server-runner

RUN --mount=type=bind,source=.,target=/go/src \
    go build -C /go/src/ -o /server-runner
