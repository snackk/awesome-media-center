## awesome-media-center

<p align="center">
  <img src="https://upload.wikimedia.org/wikipedia/commons/7/79/Docker_%28container_engine%29_logo.png" alt="Docker Logo">
</p>

Media center using Docker Compose with Traefik, CrowdSec, Portainer, Emby, Radarr, Sonarr, Prowlarr, Profilarr, FlareSolverr, Seerr, Debrid, Transmission, Immich, Navidrome, HomeControl, and Tailscale.

## Overview

Traefik acts as a reverse proxy for the **user-facing** services only, listening on ports 80 and 443. Port 80 redirects all requests to 443 globally (configured on the entrypoint in `traefik/data/traefik.yml`). Each exposed service is registered via Docker labels with a single HTTPS router and automatically gets an SSL certificate managed by Traefik using Let's Encrypt. Every public router runs two middlewares, in order: `crowdsec@file` (blocks requests CrowdSec has flagged — see [CrowdSec](#crowdsec)), then the shared `secure-headers@file` middleware (both defined in `traefik/data/config.yml`). Both carry the `@file` suffix because they're defined in the file provider, not as Docker labels — a router defined via labels (`@docker`) must still name the provider a cross-provider middleware actually lives in.

### What is exposed

| Exposure | Services |
| --- | --- |
| **Internet, via Traefik (HTTPS)** | Emby, Seerr, Immich, Navidrome, HomeControl (`home.<domain>`) |
| **Internet, router port forward** | `80`, `443` (Traefik), `51413` TCP/UDP (Transmission peers) |
| **LAN only, published port** | None. Emby is only reachable through Traefik (HTTPS) |
| **Tailnet only, via Tailscale Services (HTTPS)** | `portainer`, `radarr`, `sonarr`, `prowlarr`, `profilarr`, `transmission`, `debrid`, `picard` and `traefik` (dashboard) at `https://<name>.<tailnet>.ts.net`. Only devices in your tailnet reach them (see [Tailscale Services](#tailscale-services-internal-admin-uis)) |
| **Localhost only (SSH tunnel fallback)** | The same UIs bound to `127.0.0.1`: Radarr `7878`, Sonarr `8989`, Prowlarr `9696`, Profilarr `6868`, Transmission `9091`, Debrid `6500`, Picard `5800`, Portainer `9000`, Traefik dashboard `8082` |
| **Not reachable from outside Docker** | FlareSolverr, Immich database/Redis/machine learning, CrowdSec LAPI (reached by Traefik via Docker DNS on the `web` network only, never published) |

Admin tools never go through Traefik. They are published to your tailnet by Tailscale (one name per service, see [Tailscale Services](#tailscale-services-internal-admin-uis)); as a fallback use an SSH tunnel, e.g. `ssh -L 9000:127.0.0.1:9000 user@nas` and open `http://localhost:9000`.

See [docs/MIGRATION-UGREEN-DXP2800.md](docs/MIGRATION-UGREEN-DXP2800.md) for the NAS setup (ext4 + MergerFS, Intellipark) and the migration guide.

### Storage layout and configuration

Everything lives in a pool mounted at `/mnt/pool` (`media/`, `downloads/`, `config/`). Media and downloads share one filesystem, mounted as `/data` in Radarr/Sonarr to allow hardlinks. All settings come from a single `.env` (see `.env.example`). **There are no defaults in the compose files**: a missing variable makes `docker compose` fail with an explicit message.

```sh
cp .env.example .env
for d in traefik crowdsec portainer emby arr transmission debrid immich navidrome picard homecontrol tailscale; do ln -sf ../.env "$d/.env"; done
```

Create the shared networks once: `docker network create web` (Traefik and public services) and `docker network create arr` (internal: *arr stack and download clients).

## Prerequisites

- Domain with the required subdomains configured
- Server (Linux recommended)
- Docker and Docker Compose

## Installation

Each service has its own directory containing a `docker-compose.yml`. Start with CrowdSec, then Traefik (the reverse proxy — its bouncer middleware needs CrowdSec's key first, see [CrowdSec](#crowdsec)), then Portainer (container management UI). The remaining services can be deployed individually via CLI or managed through Portainer.

**1. Start CrowdSec, then generate and set the Traefik bouncer key:**

```sh
cd crowdsec && docker compose up -d
docker exec crowdsec cscli bouncers add traefik-bouncer -o raw
```

Write the printed value (no trailing newline) to `${CONFIG_ROOT}/traefik/crowdsec-bouncer-key` before the next step — see [CrowdSec](#crowdsec) for why this is a file and not a `.env` variable.

**2. Start Traefik:**

```sh
cd traefik && docker compose up -d
```

**3. Start Portainer:**

```sh
cd portainer && docker compose up -d
```

**4. Deploy remaining services:**

```sh
cd <service> && docker compose up -d
```

Alternatively, add the stacks via the Portainer dashboard.

Any issues with the installation should refer to the [Problems](#problems) section.

## Services

### <a name="traefik"></a> Traefik

Reverse proxy that handles SSL termination and routing for all services.

The dashboard is not published through Traefik: it listens on `127.0.0.1:8082` of the host (`entryPoints.traefik` in `traefik/data/traefik.yml`), so there is no dashboard hostname, no basic auth and no credentials to keep in the repository. Open it with `ssh -L 8082:127.0.0.1:8082 user@nas` and browse `http://localhost:8082`.

TLS uses `sniStrict: true` (`tls.options.default` in `traefik/data/config.yml`): connections without SNI or with an unknown hostname (e.g. scanners hitting the bare IP) get a failed TLS handshake instead of Traefik's default certificate and `404`, so the proxy is not fingerprinted. Side effect: `https://<nas-ip>` no longer works, always use the hostname. Restart Traefik after changing it (`docker compose restart traefik`).

Access logging is on (`accessLog` in `traefik/data/traefik.yml`): JSON lines to stdout, rotated by Docker like every other container (no `filePath`, no extra volume). Headers are dropped by default (`fields.headers.defaultMode: drop`) so `Authorization`, cookies and any API keys sent as headers never reach the log — only `User-Agent` and `Content-Type` are kept. This log is CrowdSec's only data source (see [CrowdSec](#crowdsec)).

### <a name="portainer"></a> Portainer

Web-based Docker management UI. It has full access to the Docker socket, so it is **not** exposed: it listens on `127.0.0.1:9000` only (SSH tunnel or Tailscale).

Its data volume is bind-mounted at the *same absolute path* on both sides (`${CONFIG_ROOT}/portainer` on the host and inside the container, via `--data`), not the image's default `/data` — see [Problems](#problems) for why that matters for any stack deployed through the Portainer UI (Web editor, Upload or Repository).

### Emby

Media server for movies and TV shows (`emby/`). Only Emby lives in this stack, so it can be upgraded or restarted without touching the automation tools.

`PUID`/`PGID` should match your user. See [User ID and Group ID](#user).

Hardware transcoding uses `/dev/dri` with the host `render` and `video` GIDs (`RENDER_GID`/`VIDEO_GID` in `.env`, typically `993`/`44` on Ubuntu 24.04). These are **not guaranteed to be the same across installations** — check them before deploying:

```sh
getent group render
getent group video
```

### Arr (Radarr, Sonarr, Prowlarr, Profilarr, FlareSolverr, Seerr)

Media automation stack (`arr/`):

- **Radarr** — Movie collection manager
- **Sonarr** — TV series collection manager
- **Prowlarr** — Indexer manager
- **Profilarr** — Syncs quality profiles and custom formats to Radarr/Sonarr
- **FlareSolverr** — Cloudflare bypass proxy for Prowlarr (internal only, not exposed)
- **Seerr** — Media request UI

Radarr, Sonarr, Prowlarr, Profilarr and FlareSolverr are **internal only**: they sit on the `arr` network (shared with Transmission and Debrid) and have no Traefik routes. Their UIs listen on `127.0.0.1` of the host only (Radarr 7878, Sonarr 8989, Prowlarr 9696, Profilarr 6868); use an SSH tunnel, e.g. `ssh -L 7878:127.0.0.1:7878 user@nas`. Only **Seerr** is exposed through Traefik, since it is the user-facing request UI.

### Debrid

Real-Debrid download client ([RDTClient](https://github.com/rogerfar/rdt-client)).

See `debrid/README.md` for post-installation configuration. The UI is internal: `127.0.0.1:6500` (SSH tunnel or Tailscale).

### Transmission

BitTorrent client. Downloads go to `${DATA_ROOT}/downloads`. The web UI listens on `127.0.0.1:9091` only (SSH tunnel or Tailscale); only the peer port `51413` TCP/UDP is published. The `PUID` and `PGID` environment variables are described in [User ID and Group ID](#user).

### Navidrome

Music streaming server (`navidrome/`), compatible with Subsonic clients. Library: `${DATA_ROOT}/music` (mounted read-only); database/cache: `${CONFIG_ROOT}/navidrome`.

### HomeControl

Home automation dashboard (`homecontrol/`). It runs with `network_mode: host` so it can resolve `.local` (mDNS) ESPHome/Shelly devices through the host's `avahi-daemon`, which must be installed and running on the NAS. Because it is not on the `web` network, Traefik reaches it through the host gateway (`host.docker.internal:8080`, enabled by `extra_hosts` in `traefik/docker-compose.yml`). The routing is declared with Docker labels on the container, published at `https://home.${DOMAIN}` (the Netatmo OAuth redirect URI is `https://home.snackk-media.com/netatmo/callback`). The source project (`home-control-server`) carries the same labels in its own `docker-compose.yml`. Host networking binds port 8080 on every interface, so block it from the LAN with UFW and allow only Docker networks (see step 2.5 of the migration guide). Set `HC_USERNAME`, `HC_PASSWORD` and `HC_API_KEY` in `.env` and place the SSH key at `${SSH_KEY_PATH}` (e.g. `/mnt/pool/config/homecontrol/ssh/id_rsa`, readable by the container user).

### MusicBrainz Picard

Music tagger (`picard/`, [`jlesage/musicbrainz-picard`](https://github.com/jlesage/docker-musicbrainz-picard)) with its desktop UI served in the browser. It mounts the music library `${DATA_ROOT}/music` **read-write** (Picard rewrites tags; Navidrome mounts the same folder read-only and picks the changes up on its next scan); settings and plugins live in `${CONFIG_ROOT}/picard`. The UI has no login of its own, so it is only published to your tailnet as `https://picard.<tailnet>` (see [Tailscale Services](#tailscale-services-internal-admin-uis)) and bound to `127.0.0.1:5800`.

### SMB share (Samba)

File share of the media folders for Mac, iPhone and Windows. Samba runs on the NAS host (not in Docker); the config and the setup steps are in [`samba/`](samba/README.md). It exposes `/media/data` as `media` **without** `configs/`, reachable only from the home LAN and over Tailscale (`smb://snackk-nas.<tailnet>/media`), never from the Internet.

### Immich

Self-hosted photo and video manager (`immich/`): server, machine learning, PostgreSQL (with vector extension) and Valkey (Redis). Photos are stored in `${DATA_ROOT}/photos`; the database lives in `${CONFIG_ROOT}/immich/postgres` (keep it on a local disk, never on a network share).

Before the first start set `IMMICH_DB_PASSWORD` in `.env` (letters and digits only). Then create the admin account at `https://immich.snackk-media.com`. The server publishes no host port: it is reachable only through Traefik.

### <a name="crowdsec"></a> CrowdSec

Detects and blocks suspicious requests (scanning, brute-force, known CVE probes) against every public router (`crowdsec/`). It reads Traefik's access log directly through the Docker API (`acquis.yaml`'s `source: docker`) — no shared log file or volume — using the `crowdsecurity/traefik`, `crowdsecurity/http-cve` and `crowdsecurity/base-http-scenarios` collections. Traefik enforces its decisions via the `crowdsec-bouncer-traefik-plugin` middleware (`crowdsec@file`, defined in `traefik/data/config.yml` — the file provider, not Docker labels on the `traefik` service itself; see that file for why).

The LAPI (port 8080) publishes **no host port**: it is reached only by Traefik via Docker DNS on the `web` network (`http://crowdsec:8080`), the same "never published, internal network only" treatment as Immich's database. The container does need read access to `/var/run/docker.sock` to tail container logs — the same trade-off Portainer already makes with full socket access; `acquis.yaml` limits what it actually *reads* to the `traefik` container, but the socket permission itself is broader than that.

**First-start order matters** (there is a bootstrap dependency the two stacks can't express to each other, since they are separate Compose projects):

1. `cd crowdsec && docker compose up -d` and wait for it to report healthy (`docker compose ps`).
2. Generate the bouncer key: `docker exec crowdsec cscli bouncers add traefik-bouncer -o raw`.
3. Write that value (no trailing newline) to `${CONFIG_ROOT}/traefik/crowdsec-bouncer-key` — a file, not a `.env` variable, because `traefik/data/config.yml` is read by Traefik's file provider, which doesn't substitute `${VAR}` the way compose labels do.
4. Only then `cd traefik && docker compose up -d` (or restart it if already running) — it reads the key from that file at request time, so it must exist first.

A tailnet-only web dashboard (`cscli dashboard`, published the same way as Portainer/Radarr/etc.) is a planned follow-up, not yet implemented — its exact setup command/image has changed across CrowdSec releases and needs checking against the installed version (`docker exec crowdsec cscli version`) before wiring it in.

### Tailscale

VPN (`tailscale/`) that gives you secure remote access to the NAS, the LAN and the internal-only services (such as the *arr UIs, via SSH tunnel) without opening more router ports. It runs with `network_mode: host`, `NET_ADMIN` and `/dev/net/tun`, and advertises your LAN (`TS_ROUTES`) as a subnet router, so it is not routed through Traefik. Set `TS_AUTHKEY` in `.env` for the first start (state is kept in `${CONFIG_ROOT}/tailscale`), enable IP forwarding on the host, approve the route in the Tailscale admin console, and allow UDP `41641` in UFW (optionally forward it on the router). See step 10.1 of the migration guide.


#### <a name="tailscale-services-internal-admin-uis"></a> Tailscale Services (internal admin UIs)

The internal admin UIs are not routed through Traefik or the Internet. Each one is published as its own [Tailscale Service](https://tailscale.com/docs/features/tailscale-services), with a name and a certificate issued by Tailscale, reachable only from devices in your tailnet (at home or away, with Tailscale on):

| Service | URL | Local port |
| --- | --- | --- |
| Portainer | `https://portainer.<tailnet>` | `9000` |
| Radarr | `https://radarr.<tailnet>` | `7878` |
| Sonarr | `https://sonarr.<tailnet>` | `8989` |
| Prowlarr | `https://prowlarr.<tailnet>` | `9696` |
| Profilarr | `https://profilarr.<tailnet>` | `6868` |
| Transmission | `https://transmission.<tailnet>` | `9091` |
| Debrid | `https://debrid.<tailnet>` | `6500` |
| MusicBrainz Picard | `https://picard.<tailnet>` | `5800` |
| Traefik dashboard | `https://traefik.<tailnet>` | `8082` |

(`<tailnet>` is your tailnet DNS suffix, e.g. `tail1a2b3.ts.net`; set it as `TAILNET_DOMAIN` in `.env`.)

Setup (Services are a recent Tailscale feature: check their current status and plan limits first):

1. Install Tailscale on your devices and bring the `tailscale` stack up (`TS_AUTHKEY`, `TS_HOSTNAME` in `.env`).
2. **Tag the NAS node**: create the tag in the ACL policy (`tagOwners`), create the auth key with that tag, and set `TS_EXTRA_ARGS=--advertise-tags=tag:nas`.
3. In the admin console enable **MagicDNS** and **HTTPS Certificates** (DNS page). The machine name becomes visible in public certificate-transparency logs.
4. **Create one Service per name** in the admin console (Services page) with HTTPS/443, and let the tagged node host them, either by approving the host or with `autoApprovers` in the ACL policy.
5. On the NAS run `./tailscale/services.sh` to map every Service to its local port, then check with `docker exec tailscale tailscale serve status`.
6. Remove the old public DNS records for these names (the CNAMEs are no longer used).

Notes: Profilarr's `ORIGIN` is set to `https://profilarr.${TAILNET_DOMAIN}`, so its forms only work through that URL (through the `localhost:6868` SSH tunnel its form submits may be rejected as cross-site). Do **not** use `tailscale funnel`: it would expose the services to the Internet.

## Upgrading Services

All services can be upgraded with:

```sh
cd <service>
docker compose pull
docker compose up -d
```

This pulls the latest images and recreates only the containers that have changed.

## Emby Backup & Restore

The Emby config is a bind mount at `${CONFIG_ROOT}/emby` (e.g. `/mnt/pool/config/emby`).

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
chmod 600 ${CONFIG_ROOT}/traefik/acme.json
```

---

**A stack deployed from the Portainer UI fails with `read <path>: is a directory` for a file that is tracked in Git and clearly exists in the repo** (e.g. `crowdsec/acquis.yaml`):

This happens when Portainer's own data volume is bind-mounted to a different path inside its container than on the host (e.g. `${CONFIG_ROOT}/portainer:/data`). Portainer computes bind-mount *sources* for the stacks it manages (relative compose volumes like `./acquis.yaml`) using its own internal view of that path (`/data/compose/<id>/...`). But the actual mount is created by the **host's** `dockerd` through `docker.sock`, which only understands host paths — `/data/compose/<id>/...` means nothing there, so it silently auto-creates an empty directory and mounts that instead of the real file.

Fix: Portainer's volume must use the *same absolute path* on both sides (`portainer/docker-compose.yml` does this via `${CONFIG_ROOT}/portainer:${CONFIG_ROOT}/portainer` plus `command: ["--data", "${CONFIG_ROOT}/portainer"]`). If Portainer was already deployed with the old `/data` mapping, any stack it deployed in the meantime may have left behind empty phantom directories on the host at the wrong path (check `docker inspect <container> --format '{{json .Mounts}}'` for a bind `Source` that doesn't match a real file). Recreate the Portainer container with the corrected compose file first, then **delete and recreate** (not just redeploy/update) any stack that hit this — redeploying in place reuses the existing clone and won't fix a mount that's already wrong.

---

**Traefik keeps failing an ACME order for a nonsense domain like `traefik-traefik`** (`Domain name needs at least one dot`), with a matching router visible at `GET http://127.0.0.1:8082/api/http/routers/https-traefik-traefik@docker`:

Caused by `traefik.enable=true` on the `traefik` service itself with no explicit router label for it. Traefik's Docker provider auto-creates one router per entrypoint from `defaultRule` (`Host(\`{{ normalize .Name }}\`)`) for any enabled container that doesn't define its own router — here that's the Compose project+service name doubled up, routed back to Traefik's own `:80` entrypoint. It doesn't expose anything sensitive (it loops into Traefik itself, not the dashboard), but it's a dead, publicly-reachable router that burns an ACME order for nothing.

Fix: don't put `traefik.enable=true` (or any `traefik.http.*` label) on the `traefik` service at all — define middlewares that need to apply to *other* services' routers (like `crowdsec`) in `traefik/data/config.yml` (file provider) instead, the same way `secure-headers` already is.

---

**A service's router fails with `middleware "crowdsec@docker" does not exist`** even though the middleware is clearly defined and healthy elsewhere:

Traefik middleware references are qualified by *provider*, not just name: `crowdsec@docker` and `crowdsec@file` are different identifiers even if both existed. Every middleware referenced in `traefik.http.routers.<name>.middlewares=...` must name the provider it's actually defined in, regardless of which provider the *router* itself comes from. `crowdsec` lives in `traefik/data/config.yml` (the file provider), so every service's label must say `crowdsec@file` — `crowdsec@docker` (a leftover from when it used to be defined via Docker labels) will never resolve.

Fix: `grep -rn "crowdsec@docker"` across the repo and replace every match with `crowdsec@file`, then recreate the affected services.

---

Written by [@snackk](https://github.com/snackk)
