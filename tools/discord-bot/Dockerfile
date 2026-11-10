FROM golang:1.27.4 AS build

WORKDIR /src

# Download dependencies first so they are cached across source changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /discord-bot ./

FROM gcr.io/distroless/static:nonroot AS discord-bot

COPY --from=build /discord-bot /discord-bot

EXPOSE 8080 9090
USER nonroot:nonroot
ENTRYPOINT ["/discord-bot"]
