FROM golang:1.27@sha256:ec47ea3725fea0cc88f6de94919aef19f40f12fc1ec0e2d1b3426dbf15ecca04 AS server-runner

RUN --mount=type=bind,source=.,target=/go/src \
    go build -C /go/src/ -o /server-runner
