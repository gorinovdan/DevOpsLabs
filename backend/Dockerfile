ARG GO_IMAGE=mirror.gcr.io/library/golang:1.25
ARG RUNTIME_IMAGE=mirror.gcr.io/library/debian:bookworm-slim

FROM ${GO_IMAGE} AS build

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

COPY cmd ./cmd
COPY internal ./internal

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /bin/server ./cmd/server

FROM ${RUNTIME_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home appuser

WORKDIR /app

COPY --from=build /bin/server /usr/local/bin/server

ENV PORT=8080
ENV DB_DSN=host=postgres user=flowboard password=flowboard dbname=flowboard port=5432 sslmode=disable TimeZone=UTC

EXPOSE 8080

USER appuser

ENTRYPOINT ["/usr/local/bin/server"]
