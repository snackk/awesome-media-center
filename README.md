## awesome-media-center

<p align="center">
  <img src="https://upload.wikimedia.org/wikipedia/commons/7/79/Docker_%28container_engine%29_logo.png" alt="Docker Logo">
</p>

Media center using Docker Compose with Traefik, Portainer, Emby, Radarr, Sonarr, Prowlarr, FlareSolverr, Seerr, Debrid, Transmission, Immich, Navidrome, and HomeControl.

## Overview

Traefik acts as a reverse proxy to expose the running Docker containers, listening on ports 80 and 443. Port 80 redirects all requests to 443 globally (configured on the entrypoint in `traefik/data/traefik.yml`). Each service is registered via Docker labels with a single HTTPS router and automatically gets an SSL certificate managed by Traefik using Let's Encrypt. A shared `secure-headers` middleware (`traefik/data/config.yml`) is applied to every router.

See [docs/MIGRATION-UGREEN-DXP2800.md](docs/MIGRATION-UGREEN-DXP2800.md) for the NAS setup (ext4 + MergerFS, Intellipark) and the migration guide.

### Storage layout and configuration

Paths default to a pool mounted at `/mnt/pool` (`media/`, `downloads/`, `config/`). Media and downloads share one filesystem, mounted as `/data` in Radarr/Sonarr to allow hardlinks. Override defaults with a `.env` (see `.env.example`):

```sh
cp .env.example .env
for d in traefik portainer emby arr transmission debrid immich navidrome homecontrol; do ln -sf ../.env "$d/.env"; done
```

Create the shared network once: `docker network create web`.

## Prerequisites

- Domain with the required subdomains configured
- Server (Linux recommended)
- Docker and Docker Compose

## Installation

Each service has its own directory containing a `docker-compose.yml`. Start by deploying Traefik (the reverse proxy) and Portainer (container management UI). The remaining services can be deployed individually via CLI or managed through Portainer.

**1. Start Traefik:**

```sh
cd traefik && docker compose up -d
```

**2. Start Portainer:**

```sh
cd portainer && docker compose up -d
```

**3. Deploy remaining services:**

```sh
cd <service> && docker compose up -d
```

Alternatively, add the stacks via the Portainer dashboard.

Any issues with the installation should refer to the [Problems](#problems) section.

## Services

### <a name="traefik"></a> Traefik

Reverse proxy that handles SSL termination and routing for all services.

In `traefik/docker-compose.yml`, update the `basicauth.users` label with your credentials. The password should be generated with `htpasswd`, and every `$` character must be escaped by doubling it (`$$`).

### <a name="portainer"></a> Portainer

Web-based Docker management UI.

### Emby

Media server for movies and TV shows (`emby/`). Only Emby lives in this stack, so it can be upgraded or restarted without touching the automation tools.

`PUID`/`PGID` should match your user. See [User ID and Group ID](#user).

Hardware transcoding uses `/dev/dri` with the host `render` and `video` GIDs (`RENDER_GID`/`VIDEO_GID`, defaults `992`/`44`). These are **not guaranteed to be the same across installations** — check them before deploying:

```sh
getent group render
getent group video
```

### Arr (Radarr, Sonarr, Prowlarr, FlareSolverr, Seerr)

Media automation stack (`arr/`):

- **Radarr** — Movie collection manager
- **Sonarr** — TV series collection manager
- **Prowlarr** — Indexer manager
- **FlareSolverr** — Cloudflare bypass proxy for Prowlarr (internal only, not exposed)
- **Seerr** — Media request UI

These services are only reachable through Traefik (no published ports).

### Debrid

Real-Debrid download client ([RDTClient](https://github.com/rogerfar/rdt-client)).

See `debrid/README.md` for post-installation configuration.

### Transmission

BitTorrent client. Downloads go to `${DATA_ROOT}/downloads`. The `PUID` and `PGID` environment variables are described in [User ID and Group ID](#user).

### Navidrome

Music streaming server (`navidrome/`), compatible with Subsonic clients. Library: `${DATA_ROOT}/media/music` (mounted read-only); database/cache: `${CONFIG_ROOT}/navidrome`.

### HomeControl

Home automation dashboard (`homecontrol/`). It runs with `network_mode: host` so it can resolve `.local` (mDNS) ESPHome/Shelly devices through the host's `avahi-daemon`, which must be installed and running on the NAS. Because it is not on the `web` network, Traefik reaches it through a file-provider route in `traefik/data/config.yml` (`host.docker.internal:8080`); the hostname there is hardcoded (`homecontrol.snackk-media.com`), so edit it if you change `DOMAIN`. Host networking binds port 8080 on every interface, so block it from the LAN with UFW and allow only Docker networks (see step 2.5 of the migration guide). Set `HC_USERNAME`, `HC_PASSWORD` and `HC_API_KEY` in `.env` and place the SSH key at `${SSH_KEY_PATH}` (default `/mnt/pool/config/homecontrol/ssh/id_rsa`, readable by the container user).

### Immich

Self-hosted photo and video manager (`immich/`): server, machine learning, PostgreSQL (with vector extension) and Valkey (Redis). Photos are stored in `${DATA_ROOT}/media/Photos`; the database lives in `${CONFIG_ROOT}/immich/postgres` (keep it on a local disk, never on a network share).

Before the first start set `IMMICH_DB_PASSWORD` in `.env` (letters and digits only). Then create the admin account at `https://immich.snackk-media.com`.

## Upgrading Services

All services can be upgraded with:

```sh
cd <service>
docker compose pull
docker compose up -d
```

This pulls the latest images and recreates only the containers that have changed.

## Emby Backup & Restore

The Emby config is a bind mount at `${CONFIG_ROOT}/emby` (default `/mnt/pool/config/emby`).

### Backup

```sh
(cd emby && docker compose stop)
tar czf emby-backup.tar.gz -C /mnt/pool/config/emby .
(cd emby && docker compose start)
```

### Restore

```sh
mkdir -p /mnt/pool/config/emby
tar xzf emby-backup.tar.gz -C /mnt/pool/config/emby
chown -R 1000:1000 /mnt/pool/config/emby
```

## <a name="colima"></a> Additional Config — Colima

Colima doesn't automatically mount host volumes. Add mount points to the Colima VM config:

```sh
nano ~/.colima/default/colima.yaml
```

Example:

```yaml
mounts:
  - location: /Volumes/Media
    writable: true
  - location: ~/colima-data
    writable: true
```

A matching folder should exist on the host (e.g., `mkdir ~/colima-data`).

## <a name="user"></a> User ID and Group ID

To find your UID and GID:

```sh
id -u  # UID
id -g  # GID
```

## <a name="problems"></a> Problems

**Permissions on `acme.json` are too open:**

```sh
chmod 600 traefik/data/acme.json
```

---

Written by [@snackk](https://github.com/snackk)
