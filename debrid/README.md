**Debrid UI**  
- [https://debrid.snackk-media.com/settings](https://debrid.snackk-media.com/settings)

**Download Client**  

On first run only, make the following changes:
- Download path: `/data/downloads`  
- Mapped path: `/data/downloads`

Radarr/Sonarr (stack `arr/`) mount the whole pool at `/data`, so the downloads folder is seen at `/data/downloads` by both sides and no remote path mapping is needed.

These settings are stored in `/data/db`, which is persisted via a bind mount (`${CONFIG_ROOT}/debrid`, default `/mnt/pool/config/debrid`) in `debrid/docker-compose.yml`. As long as that folder isn't deleted, the config survives `docker stop`/`docker rm` and doesn't need to be re-entered.

