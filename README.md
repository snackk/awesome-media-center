## awesome-media-center

<p align="center">
  <img src="https://upload.wikimedia.org/wikipedia/commons/7/79/Docker_%28container_engine%29_logo.png" alt="Docker Logo">
</p>

Media center using Docker Compose with Traefik, Portainer, Emby, Radarr, Sonarr, Jackett, FlareSolverr, Debrid, Transmission, and Jenkins.

## Overview

Traefik acts as a reverse proxy to expose the running Docker containers, listening on ports 80 and 443. Port 80 redirects all requests to 443 to enforce HTTPS. Each service is registered via Docker labels and automatically gets an SSL certificate managed by Traefik using Let's Encrypt.

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

Media server for movies and TV shows. The stack also includes:

- **Radarr** — Movie collection manager
- **Sonarr** — TV series collection manager
- **Jackett** — Torrent indexer proxy
- **FlareSolverr** — Cloudflare bypass proxy for Jackett

The `UID` and `GID` environment variables should match your user. See [User ID and Group ID](#user).

The `group_add` entries in `emby/docker-compose.yml` (`992`, `44`) are the host GIDs for the `render` and `video` groups, used for hardware transcoding via `/dev/dri`. These GIDs are **not guaranteed to be the same across installations or hardware** — they depend on your distro and driver setup. Check your host's actual GIDs before deploying:

```sh
getent group render
getent group video
```

Update the `group_add` values in the compose file to match if they differ.

### Debrid

Real-Debrid download client ([RDTClient](https://github.com/rogerfar/rdt-client)).

See `debrid/README.md` for post-installation configuration.

### Transmission

BitTorrent client. The volumes should be changed to match your desired download path. The `PUID` and `PGID` environment variables are described in [User ID and Group ID](#user).

### Jenkins

CI/CD server with Docker-in-Docker support and JDK 21. Uses a custom image built from `jenkins/Dockerfile`.

## Upgrading Services

All services can be upgraded with:

```sh
cd <service>
docker compose pull
docker compose up -d
```

This pulls the latest images and recreates only the containers that have changed.

## Emby Backup & Restore

### Backup

This backs up the entire Emby config volume into a `backup.tar` file:

```sh
cd ~ && mkdir -p emby-backup && cd emby-backup
docker run --rm --volumes-from emby -v $(pwd):/backup ubuntu tar cvf /backup/backup.tar /config
```

### Restore

```sh
cd ~/emby-backup
docker run --rm --volumes-from emby -v $(pwd):/backup ubuntu bash -c "cd /config && tar xvf /backup/backup.tar --strip 1"
```

#### Restore with Colima

If using [Colima](#colima), copy the `emby-backup` folder to `~/colima-data` first:

```sh
docker run --rm --volumes-from emby -v ~/colima-data/emby-backup:/backup ubuntu bash -c \
  "cd /config && tar xvf /backup/backup.tar --strip 1 && chown -R 501:20 /config"
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
