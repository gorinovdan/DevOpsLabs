FROM golang:1.25 AS build

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o /bin/server ./cmd/server

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /bin/server /usr/local/bin/server

ENV PORT=8080
ENV DB_DSN=host=postgres user=flowboard password=flowboard dbname=flowboard port=5432 sslmode=disable TimeZone=UTC

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/server"]
