# Changelog

## v0.7.1-1 (2026-11-23)

First release of the Railway template.

- Hound v0.7.1, built from the release's Go module; `GOMAXPROCS` follows the container's CPU limit instead of the host's CPU count.
- Caddy 2.11.9 in front with HTTP basic auth (generated password); `/healthz` is public for Railway's health check.
- Repos from `HOUND_REPOS` (comma-separated, optional `#branch`), or a full `HOUND_CONFIG`; index and clones on the `/data` volume.
- Optional `GITHUB_TOKEN` for private GitHub repos, passed through a git credential helper.
- Exits non-zero when Hound or Caddy stops, so Railway restarts it.
