**Debrid UI**  
- [http://localhost:6500/settings](http://localhost:6500/settings) (internal only: open an SSH tunnel first, `ssh -L 6500:127.0.0.1:6500 user@nas`)

**Download Client**  

On first run only, make the following changes:
- Download path: `/data/downloads`  
- Mapped path: `/data/downloads`

Radarr/Sonarr (stack `arr/`) mount the whole pool at `/data`, so the downloads folder is seen at `/data/downloads` by both sides and no remote path mapping is needed.

These settings are stored in `/data/db`, which is persisted via a bind mount (`${CONFIG_ROOT}/debrid`, e.g. `/mnt/pool/config/debrid`) in `debrid/docker-compose.yml`. As long as that folder isn't deleted, the config survives `docker stop`/`docker rm` and doesn't need to be re-entered.

