#!/usr/bin/env bash
# Publishes each internal admin UI as its own Tailscale Service, so it is reachable at
# https://<name>.<tailnet>.ts.net (HTTPS on 443, certificate issued by Tailscale), and only by
# devices in your tailnet. Each Service proxies to the port that service already binds on
# 127.0.0.1 of the NAS (the tailscale container runs with network_mode: host).
#
# Run on the NAS once the tailscale stack is up AND the prerequisites in the README
# ("Tailscale Services") are done: tagged node, ACL auto-approvers, and one Service created
# per name below in the admin console.
#
# Usage: ./tailscale/services.sh            # publish every service
#        TS_CONTAINER=other ./tailscale/services.sh
set -euo pipefail

CONTAINER="${TS_CONTAINER:-tailscale}"

# <service name>:<local port>  (keep in sync with the ports published on 127.0.0.1)
SERVICES=(
  "portainer:9000"
  "radarr:7878"
  "sonarr:8989"
  "prowlarr:9696"
  "profilarr:6868"
  "transmission:9091"
  "debrid:6500"
  "traefik:8082"
)

for entry in "${SERVICES[@]}"; do
  name="${entry%%:*}"
  port="${entry##*:}"
  echo "svc:${name}  ->  http://127.0.0.1:${port}"
  docker exec "${CONTAINER}" tailscale serve --service="svc:${name}" --https=443 "http://127.0.0.1:${port}"
done

echo
docker exec "${CONTAINER}" tailscale serve status
