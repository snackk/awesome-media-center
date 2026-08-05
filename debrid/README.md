**Debrid UI**  
- [https://debrid.snackk-media.com/settings](https://debrid.snackk-media.com/settings)

**Download Client**  

On first run only, make the following changes:
- Download path: `/data/downloads`  
- Mapped path: `/downloads`

These settings are stored in `/data/db`, which is persisted via a bind mount (`debrid_config`) in `debrid/docker-compose.yml`. As long as that volume isn't deleted, the config survives `docker stop`/`docker rm` and doesn't need to be re-entered.
