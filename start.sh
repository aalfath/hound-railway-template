#!/bin/sh
# Start script for Hound on Railway: writes Hound's config from variables, then runs
# Hound on 127.0.0.1:6080 behind Caddy (basic auth) on $PORT. Exits non-zero when
# either process stops, so Railway's ON_FAILURE restart policy brings it back.
set -eu
set -f  # no globbing when splitting HOUND_REPOS

log() { echo "[hound-railway] $*"; }
die() { echo "[hound-railway] ERROR: $*" >&2; exit 1; }

DATA_DIR="${HOUND_DATA_DIR:-/data}"
PORT="${PORT:-8080}"
export PORT
mkdir -p "$DATA_DIR/db" || die "cannot create $DATA_DIR/db (is the volume mounted?)"

# --- Resources: size Go and indexers to the container, not the host --------------
cpus=1
if [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r quota period < /sys/fs/cgroup/cpu.max || true
  if [ "${quota:-max}" != "max" ] && [ -n "${period:-}" ] && [ "$period" -gt 0 ]; then
    cpus=$(( (quota + period - 1) / period ))
  else
    cpus=$(nproc 2>/dev/null || echo 1)
  fi
fi
[ "$cpus" -ge 1 ] 2>/dev/null || cpus=1
[ "$cpus" -le 8 ] || cpus=8
mem_mb=0
if [ -r /sys/fs/cgroup/memory.max ]; then
  m=$(cat /sys/fs/cgroup/memory.max)
  [ "$m" != "max" ] && mem_mb=$(( m / 1048576 ))
fi
export GOMAXPROCS="${GOMAXPROCS:-$cpus}"
# Railway hosts run transparent huge pages "always", which inflates the Go heap's RSS.
export GODEBUG="${GODEBUG:-disablethp=1}"
# Soft Go heap limit at ~70% of the container limit, so GC works harder before an OOM kill.
if [ -z "${GOMEMLIMIT:-}" ] && [ "$mem_mb" -gt 0 ]; then
  export GOMEMLIMIT="$(( mem_mb * 70 / 100 ))MiB"
fi
if [ -z "${HOUND_MAX_INDEXERS:-}" ]; then
  if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 1500 ]; then HOUND_MAX_INDEXERS=1; else HOUND_MAX_INDEXERS=2; fi
fi
log "cpus=$cpus mem_limit_mb=${mem_mb:-unlimited} GOMAXPROCS=$GOMAXPROCS GOMEMLIMIT=${GOMEMLIMIT:-none} GODEBUG=$GODEBUG indexers=$HOUND_MAX_INDEXERS"

# --- Git: low-memory settings for clones and fetches -----------------------------
git config --global pack.threads 1
git config --global pack.windowMemory 32m
git config --global core.packedGitLimit 64m
git config --global core.packedGitWindowSize 16m
git config --global core.deltaBaseCacheLimit 16m
git config --global index.threads 1
git config --global gc.auto 0
git config --global --replace-all safe.directory '*'
# Optional token for private GitHub repos (HTTPS URLs). It never appears in Hound's
# config, its UI or its API.
# The helper reads the variable at fetch time, so the token is never written to disk.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  git config --global credential.https://github.com.helper \
    '!f() { echo username=x-access-token; echo "password=${GITHUB_TOKEN}"; }; f'
fi

# --- Hound config -----------------------------------------------------------------
CONF=/etc/hound/config.json
POLL_MS=$(( ${HOUND_POLL_SECONDS:-300} * 1000 ))
if [ -n "${HOUND_CONFIG:-}" ]; then
  # Full Hound config.json supplied by the deployer (advanced). Storage stays on the volume.
  printf '%s' "$HOUND_CONFIG" | jq --arg db "$DATA_DIR/db" \
    '.dbpath = $db | ."health-check-uri" = "/healthz"' > "$CONF" \
    || die "HOUND_CONFIG is not valid JSON"
else
  repos="${HOUND_REPOS:-https://github.com/hound-search/hound.git}"
  repos_json='{}'
  for entry in $(printf '%s' "$repos" | tr ',\n' '  '); do
    url="${entry%%#*}"
    ref=""
    case "$entry" in *'#'*) ref="${entry#*#}" ;; esac
    # Name: owner/repo for URLs like https://host/owner/repo(.git) or git@host:owner/repo.git
    name=$(printf '%s' "$url" | sed -E 's#\.git$##; s#/+$##; s#^.*[:/]([^/:]+/[^/:]+)$#\1#')
    [ -n "$name" ] || die "cannot read a repo name from '$url'"
    repos_json=$(printf '%s' "$repos_json" | jq --arg n "$name" --arg u "$url" --arg r "$ref" --argjson p "$POLL_MS" \
      '.[$n] = ({url: $u, "ms-between-poll": $p} + (if $r == "" then {} else {"vcs-config": {ref: $r}} end))')
  done
  [ "$repos_json" != '{}' ] || die "HOUND_REPOS is empty: list at least one git URL"
  jq -n --arg db "$DATA_DIR/db" --arg title "${HOUND_TITLE:-Hound}" --argjson repos "$repos_json" \
    --argjson idx "$HOUND_MAX_INDEXERS" \
    '{dbpath: $db, title: $title, "health-check-uri": "/healthz", "max-concurrent-indexers": $idx,
      "vcs-config": {git: {"detect-ref": true}}, repos: $repos}' > "$CONF"
fi
log "indexing $(jq '.repos | length' "$CONF") repo(s): $(jq -r '.repos | keys | join(", ")' "$CONF")"

# --- Login in front of Hound (Hound has no accounts of its own) -------------------
if [ "${HOUND_AUTH:-on}" = "off" ]; then
  log "HOUND_AUTH=off: the search UI and API are public"
  cat > /tmp/Caddyfile <<'CADDY'
{
	admin off
	auto_https off
	persist_config off
}
:{$PORT:8080} {
	reverse_proxy 127.0.0.1:6080
}
CADDY
  CADDYFILE=/tmp/Caddyfile
else
  [ -n "${HOUND_PASSWORD:-}" ] || die "HOUND_PASSWORD is empty (set it, or HOUND_AUTH=off for a public instance)"
  export HOUND_USERNAME="${HOUND_USERNAME:-admin}"
  HOUND_PASSWORD_HASH=$(caddy hash-password --plaintext "$HOUND_PASSWORD") || die "could not hash HOUND_PASSWORD"
  export HOUND_PASSWORD_HASH
  CADDYFILE=/etc/caddy/Caddyfile
fi

# --- Run both processes; exit non-zero as soon as one of them stops ---------------
houndd -conf "$CONF" -addr 127.0.0.1:6080 &
hound_pid=$!
caddy run --config "$CADDYFILE" --adapter caddyfile &
caddy_pid=$!

term() { kill -TERM "$hound_pid" "$caddy_pid" 2>/dev/null || true; exit 143; }
trap term TERM INT

while kill -0 "$hound_pid" 2>/dev/null && kill -0 "$caddy_pid" 2>/dev/null; do
  sleep 2
done
if ! kill -0 "$hound_pid" 2>/dev/null; then
  wait "$hound_pid" || true
  log "houndd stopped; exiting so Railway restarts the service"
else
  wait "$caddy_pid" || true
  log "caddy stopped; exiting so Railway restarts the service"
fi
kill -TERM "$hound_pid" "$caddy_pid" 2>/dev/null || true
exit 1
