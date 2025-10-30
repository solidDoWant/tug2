FROM golang:1.25 AS server-runner

RUN --mount=type=bind,source=.,target=/go/src \
    go build -C /go/src/ -o /server-runner
