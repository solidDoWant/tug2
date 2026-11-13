FROM golang:1.27.4@sha256:5e8afd493a7124a8586e134d9b532731161d4b9becf9dee5a5956b107426f93d AS build

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
