# Hound v0.7.1 for Railway (https://github.com/aalfath/hound-railway-template)
# Upstream publishes no 0.7.1 image (GHCR only has 0.5.0-0.6.0 and latest), so we build the
# v0.7.1 release from the Go module proxy, which is checked against sum.golang.org.

FROM golang:1.27.4-alpine3.24@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS build
ARG HOUND_VERSION=v0.7.1
ENV CGO_ENABLED=0 GOFLAGS=-mod=mod
WORKDIR /src
RUN set -eux; \
    dir="$(go mod download -json "github.com/hound-search/hound@${HOUND_VERSION}" | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",$/\1/p')"; \
    cp -r "$dir/." /src; chmod -R u+w /src; \
    # houndd forces GOMAXPROCS to the host CPU count (32 on Railway); drop that line so Go's
    # cgroup-aware default and the GOMAXPROCS variable apply.
    sed -i 's/^\truntime.GOMAXPROCS(runtime.NumCPU())$/\t\/\/ GOMAXPROCS left to the Go runtime (cgroup aware)/' cmds/houndd/main.go; \
    grep -q 'cgroup aware' cmds/houndd/main.go; \
    go build -trimpath -ldflags '-s -w' -o /out/houndd ./cmds/houndd; \
    /out/houndd -version

FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0 AS caddy

FROM debian:trixie-20261104-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
RUN apt-get update \
 && apt-get install -y --no-install-recommends git openssh-client ca-certificates tini jq \
 && rm -r /var/lib/apt/lists/*
COPY --from=build /out/houndd /usr/local/bin/houndd
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
COPY start.sh /usr/local/bin/start.sh
RUN chmod 755 /usr/local/bin/start.sh && mkdir -p /data /etc/hound
ENV PORT=8080 HOME=/root
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/start.sh"]
