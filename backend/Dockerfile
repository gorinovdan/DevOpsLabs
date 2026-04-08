FROM golang:1.25 AS build

WORKDIR /app

COPY go.mod go.sum ./
ARG GOPROXY=https://proxy.golang.org,direct
RUN set -eux; \
    ok=0; \
    for proxy in "${GOPROXY}" "https://goproxy.io,direct" "direct"; do \
      echo "Trying GOPROXY=${proxy}"; \
      if command -v timeout >/dev/null 2>&1; then \
        if timeout 300s env GOPROXY="${proxy}" GOSUMDB=sum.golang.org go mod download; then \
          ok=1; \
          break; \
        fi; \
      else \
        if env GOPROXY="${proxy}" GOSUMDB=sum.golang.org go mod download; then \
          ok=1; \
          break; \
        fi; \
      fi; \
      sleep 5; \
    done; \
    test "$ok" -eq 1

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
