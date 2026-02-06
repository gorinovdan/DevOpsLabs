FROM golang:1.25 AS build

RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=1 GOOS=linux go build -o /bin/server ./cmd/server

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /bin/server /usr/local/bin/server

ENV PORT=8080
ENV DB_PATH=/data/app.db

RUN mkdir -p /data

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/server"]
