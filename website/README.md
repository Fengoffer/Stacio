# Stacio Website

Static official homepage for Stacio, based on the Design AI prototype from `/Users/mac/Documents/Stacio/官网`.

## Preview

From the repository root:

```bash
npx --yes http-server website -p 4173 -c-1
```

Then open `http://127.0.0.1:4173`.

The site also works by opening `website/index.html` directly in a browser.

## Docker Deployment

Build the image from the repository root:

```bash
docker build -t stacio-website:latest website
```

Run it locally:

```bash
docker run --rm -p 8080:80 --name stacio-website stacio-website:latest
```

Then open `http://127.0.0.1:8080`.

Health check:

```bash
curl http://127.0.0.1:8080/healthz
```

Expected response:

```text
ok
```

Docker Compose:

```bash
cd website
docker compose up -d --build
```

By default Compose binds the site to `127.0.0.1:8080`, which is intended for a local reverse proxy such as Nginx, Caddy, or 1Panel OpenResty. Override the host or port with:

```bash
STACIO_WEBSITE_HOST=127.0.0.1 STACIO_WEBSITE_PORT=3000 docker compose up -d --build
```

Only bind to all public interfaces when the container should be directly reachable without a reverse proxy:

```bash
STACIO_WEBSITE_HOST=0.0.0.0 STACIO_WEBSITE_PORT=8080 docker compose up -d --build
```

Stop the Compose deployment:

```bash
docker compose down
```

## Production Notes

- `nginx.conf` serves `index.html` with `Cache-Control: no-store`.
- Static assets such as CSS, JS, and images use long-lived immutable cache headers.
- `/healthz` is provided for container health checks and reverse-proxy probes.
- `/downloads/latest-macos.dmg` and the architecture-specific compatibility routes redirect to Stacio 0.13.3 Release assets on Gitee.
- Put TLS, domain routing, and compression beyond gzip at the outer reverse proxy if needed.
- When deploying behind Nginx, Caddy, 1Panel, or another gateway, forward traffic to the loopback host port, for example `http://127.0.0.1:8080`.

## Files

- `index.html` contains the homepage markup and SEO metadata.
- `styles.css` contains the Liquid Glass visual system and responsive layout.
- `main.js` contains language, theme, download selector, GitHub release-note sync, modal, reveal, and event tracking interactions.
- The macOS selector exposes separate Apple Silicon and Intel packages, with Gitee as the primary download and GitHub as the fallback.
- DMG binaries are never stored in the website source; the page references Release assets and publishes their file sizes and SHA-256 checksums.
- `robots.txt` allows the static homepage to be indexed.
- `assets/stacio-logo.png` is copied from `logo/Stacio-logo.png`.
- `assets/github.svg` provides the GitHub mark used in repository links.
- `Dockerfile` packages the static site with Nginx.
- `nginx.conf` contains cache, gzip, health, and security-header settings.
- `docker-compose.yml` provides a single-service deployment for local or small-server hosting.

## Link Targets

- Repository: `https://github.com/Fengoffer/Stacio`
- Releases: `https://github.com/Fengoffer/Stacio/releases`
- Apple Silicon primary: `https://gitee.com/fengoffer/Stacio/releases/download/v0.13.3/Stacio-0.13.3-arm64.dmg`
- Intel primary: `https://gitee.com/fengoffer/Stacio/releases/download/v0.13.3/Stacio-0.13.3-x86_64.dmg`
- GitHub fallback release: `https://github.com/Fengoffer/Stacio/releases/tag/v0.13.3`
