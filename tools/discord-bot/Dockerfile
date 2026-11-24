FROM golang:1.27.4@sha256:205c7636d74e0ffbe3d007162df7d74f859f5a8c8322dfb9f907977686c126cf AS build

WORKDIR /src

# Download dependencies first so they are cached across source changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /discord-bot ./

FROM gcr.io/distroless/static:nonroot@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5 AS discord-bot

COPY --from=build /discord-bot /discord-bot

EXPOSE 8080 9090
USER nonroot:nonroot
ENTRYPOINT ["/discord-bot"]
