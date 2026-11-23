[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/hound?utm_medium=integration&utm_source=button&utm_campaign=hound)

# Hound on Railway

One-click [Railway](https://railway.com) template for [Hound](https://github.com/hound-search/hound), a fast regular-expression code search engine for many Git repositories, with a web UI and a JSON API.

- **Hound v0.7.1** (latest release), built from the release's Go module (`github.com/hound-search/hound@v0.7.1`, checked against `sum.golang.org`). Upstream publishes no 0.7.1 image (GHCR stops at 0.6.0 plus `latest`), so this repo builds it.
- Base images pinned by version and digest: `golang:1.27.4-alpine3.24` (build), `caddy:2.11.9-alpine` (the `caddy` binary only), `debian:trixie-20261104-slim` (runtime).
- **One service**, `Hound`, with a volume at `/data` for the repo clones and the search index.
- **Login:** Hound has no accounts of its own, so [Caddy](https://caddyserver.com) sits in front with HTTP basic auth. The password is generated at deploy time. Only `/healthz` is public.

## Variables

| Variable | Default | What it does |
|---|---|---|
| `HOUND_REPOS` | `https://github.com/hound-search/hound.git` | Comma-separated Git URLs to index. Replace the example with your own. Add `#branch` to pin a branch (`https://github.com/org/repo.git#develop`); otherwise the repo's default branch is used. |
| `HOUND_USERNAME` | `admin` | Login user name. |
| `HOUND_PASSWORD` | `${{secret(24)}}` | Login password, generated at deploy time. Read it in the service's **Variables** tab. |
| `PORT` | `8080` | Port Caddy listens on (Railway routes the public domain here). |

Optional, not in the template (add them to the service if you need them):

| Variable | What it does |
|---|---|
| `GITHUB_TOKEN` | A GitHub token with read access, for private `https://github.com/...` repos. Git reads it at fetch time; it never appears in Hound's UI, API or config. |
| `HOUND_POLL_SECONDS` | How often each repo is checked for new commits (default `300`). |
| `HOUND_TITLE` | Page title (default `Hound`). |
| `HOUND_CONFIG` | A complete Hound [`config.json`](https://github.com/hound-search/hound/blob/v0.7.1/docs/config-options.md) as JSON, for per-repo options (Mercurial/SVN, URL patterns, excludes). It replaces `HOUND_REPOS`; `dbpath` and the health path are set for you. |
| `HOUND_AUTH` | `off` removes the login and makes search public. Only for public code. |
| `HOUND_MAX_INDEXERS` | Repos indexed at once (default 1 below 1.5 GB RAM, else 2). |

## Resources

The start script sizes Hound to the container: `GOMAXPROCS` from the CPU limit, a Go soft memory limit (`GOMEMLIMIT`) at 70% of the memory limit, one indexer below 1.5 GB, and low-memory Git settings for clones. Tested at **0.5 GB RAM / 1 vCPU** (Railway's Free plan): indexing the whole Linux kernel (1.7 GB of source, 2.9 GB on disk) peaked at about 320 MB of process memory with no OOM kill. The volume needs roughly 1.5–2× the size of the code you index.

If Hound or Caddy stops, the container exits non-zero so Railway's restart policy brings it back.

## After deploying

1. Open the public URL and sign in as `admin` with the `HOUND_PASSWORD` from the service's Variables tab.
2. Set `HOUND_REPOS` to your repositories and redeploy. The first index of each repo runs at startup (search answers with "Hound is not ready" until it's done); later restarts reuse the index on the volume.
3. API: `curl -u admin:PASSWORD "https://YOUR-DOMAIN/api/v1/search?q=TODO&repos=*"`.

## Updates

This template builds from this repo. When a new Hound release comes out, we bump the version here and note it in [CHANGELOG.md](CHANGELOG.md); Railway then shows deployers an "update available" notice and you choose when to apply it. Your index stays on the volume.

## Licence

Hound is MIT-licensed (© Etsy and contributors). This wrapper is MIT too.
