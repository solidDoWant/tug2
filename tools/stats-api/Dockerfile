FROM golang:1.26 AS build

WORKDIR /src

# Download dependencies first so they are cached across source changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /stats-api ./

FROM gcr.io/distroless/static:nonroot AS stats-api

COPY --from=build /stats-api /stats-api

EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/stats-api"]
