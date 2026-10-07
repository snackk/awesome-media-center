# Migrating to a UGREEN DXP2800

This guide documents how to move the `awesome-media-center` stack from a personal computer to a **UGREEN DXP2800** NAS with a single **WD Blue 4TB** HDD, formatted as **ext4**, pooled with **MergerFS** (so more disks can be added later) and with the **Intellipark (idle3) head-parking timer disabled** using `idle3-tools`.

> All commands run as `root` (or with `sudo`) on the NAS over SSH, unless stated otherwise. Replace `/dev/sdX` with the real device — **double-check it with `lsblk` before every destructive command**.

## Table of contents

1. [Target layout](#1-target-layout)
2. [Prepare the NAS](#2-prepare-the-nas)
3. [Disable Intellipark (idle3-tools)](#3-disable-intellipark-idle3-tools)
4. [Format the disk (ext4)](#4-format-the-disk-ext4)
5. [Set up MergerFS](#5-set-up-mergerfs)
6. [Adding another disk in the future](#6-adding-another-disk-in-the-future)
7. [Install Docker and clone the repository](#7-install-docker-and-clone-the-repository)
8. [Migrate data from the old computer](#8-migrate-data-from-the-old-computer)
9. [Network, DNS and port forwarding](#9-network-dns-and-port-forwarding)
10. [Start the stacks](#10-start-the-stacks)
11. [Post-migration application changes](#11-post-migration-application-changes)
12. [Verification checklist](#12-verification-checklist)
13. [Rollback and decommissioning](#13-rollback-and-decommissioning)

---

## 1. Target layout

Everything media-related lives under one MergerFS pool, mounted at `/mnt/pool`. Docker containers get this pool mounted as **one** filesystem (`/data`), which allows Radarr/Sonarr to **hardlink** instead of copying files after a download completes ([TRaSH Guides](https://trash-guides.info/File-and-Folder-Structure/) layout).

```
/mnt/disks/disk1            <- physical ext4 disk (WD Blue 4TB)
/mnt/disks/disk2            <- future disks
/mnt/pool                   <- MergerFS union of /mnt/disks/disk*
├── media/
│   ├── movies/             (was /media/data/Media/Movies)
│   └── shows/              (was /media/data/Media/Shows)
├── downloads/              (was the root of /media/data/Media, torrent/debrid downloads)
└── config/                 (application configuration, was *_config folders and docker volumes)
    ├── emby/
    ├── radarr/
    ├── sonarr/
    ├── prowlarr/
    ├── seerr/
    ├── transmission/
    ├── debrid/
    ├── jenkins/
    └── portainer/
```

> **Tip:** if you have an NVMe SSD, keep `config/` (databases, metadata, Emby cache) there for better responsiveness and to avoid waking the HDD. If you do, set `CONFIG_ROOT` accordingly (see [step 7](#7-install-docker-and-clone-the-repository)).

## 2. Prepare the NAS

1. Update the system and install the basic tooling:

   ```sh
   apt update && apt full-upgrade -y
   apt install -y rsync curl git smartmontools hdparm parted fuse3 gnupg
   ```

2. UGOS (the UGREEN firmware) is Debian-based. Enable SSH in the UGOS control panel and log in with `ssh <user>@<nas-ip>`.
3. **Do not create a storage pool/volume for the HDD in the UGOS UI.** The disk is managed manually in this guide. If UGOS already initialised it, remove that volume first (this erases the disk).
4. Give the NAS a static IP or a DHCP reservation on your router.

## 3. Disable Intellipark (idle3-tools)

WD drives (Green/Blue/Red lines) park the heads after ~8 seconds of inactivity (**Intellipark**, the *idle3* timer). On a server with constant small accesses this causes a very high `Load_Cycle_Count`, wearing the drive. We disable it with `idle3-tools`.

> Note: this is not a real firmware flash. `idle3ctl` changes a drive setting through vendor commands. It is persistent across reboots, but requires a **full power cycle** to apply.
>
> Some newer WD Blue models (e.g. SMR `WD40EZAZ`/`WD40EZAX`) may ignore or reject the command. If `idle3ctl` fails, use the vendor `wdidle3.exe` from a DOS boot USB with the disk connected directly via SATA.

1. Install the tool:

   ```sh
   apt install -y idle3-tools
   ```

2. Identify the disk and record the current `Load_Cycle_Count` as a baseline:

   ```sh
   lsblk -o NAME,MODEL,SIZE,SERIAL
   smartctl -A /dev/sdX | grep -E "Load_Cycle_Count|Start_Stop_Count"
   ```

3. Read the current idle3 timer:

   ```sh
   idle3ctl -g /dev/sdX
   # Idle3 timer set to 80 (0x50)   -> 8 seconds (default)
   ```

4. Disable the timer:

   ```sh
   idle3ctl -d /dev/sdX
   ```

   Alternatively set a long timeout (e.g. 5 minutes = value `138`; values 129-255 count in 30 s units):

   ```sh
   idle3ctl -s 138 /dev/sdX
   ```

5. **Power off the NAS completely** (do not just reboot), wait ~30 seconds, power it on again:

   ```sh
   poweroff
   ```

6. Verify the change:

   ```sh
   idle3ctl -g /dev/sdX
   # Idle3 timer is disabled
   ```

7. Re-check `Load_Cycle_Count` after a few days. It should barely increase anymore.

Optional — standard spin-down when the disk is truly idle (saves power/noise; it is independent of Intellipark). Spinning down/up frequently also wears the drive, so use a long timeout:

```sh
hdparm -S 242 /dev/sdX    # 242 = 1 hour
```

Make it persistent through `/etc/hdparm.conf` (use the `/dev/disk/by-id/...` path).

## 4. Format the disk (ext4)

> **This erases the disk.**

```sh
# Confirm the correct device (model/size/serial)
lsblk -o NAME,MODEL,SIZE,SERIAL,MOUNTPOINT

# Create a GPT partition table and one partition
parted /dev/sdX --script mklabel gpt mkpart primary ext4 0% 100%

# Format as ext4:
#  -m 0         no reserved blocks (this is a data disk, not the OS disk)
#  -T largefile4 fewer inodes, more usable space for large media files
#  -L disk1     label
mkfs.ext4 -m 0 -T largefile4 -L disk1 /dev/sdX1
```

Create the mount point and mount by **UUID** (device names such as `sda` can change):

```sh
mkdir -p /mnt/disks/disk1
blkid /dev/sdX1        # copy the UUID
```

Add to `/etc/fstab`:

```fstab
UUID=<disk1-uuid>  /mnt/disks/disk1  ext4  defaults,noatime,nofail  0  2
```

```sh
systemctl daemon-reload
mount -a
df -h /mnt/disks/disk1
```

## 5. Set up MergerFS

MergerFS presents several disks as a single directory. Files are stored whole on one disk (no striping), so every disk remains readable on its own. **MergerFS provides no redundancy** — keep backups of important data (especially `config/`).

1. Install a recent version. The Debian package is old; prefer the release from <https://github.com/trapexit/mergerfs/releases>:

   ```sh
   # Check your Debian release with: . /etc/os-release && echo $VERSION_CODENAME
   wget https://github.com/trapexit/mergerfs/releases/download/<version>/mergerfs_<version>.debian-<codename>_amd64.deb
   dpkg -i mergerfs_<version>.debian-<codename>_amd64.deb
   mergerfs --version
   ```

2. Create the pool mount point:

   ```sh
   mkdir -p /mnt/pool
   ```

3. Add to `/etc/fstab` (single line). The glob `/mnt/disks/disk*` means new disks are picked up automatically at the next mount:

   ```fstab
   /mnt/disks/disk*  /mnt/pool  fuse.mergerfs  allow_other,use_ino,cache.files=off,dropcacheonclose=true,category.create=epmfs,moveonenospc=true,minfreespace=50G,fsname=mergerfs,nofail,x-systemd.requires-mounts-for=/mnt/disks/disk1  0  0
   ```

   Option notes:

   | Option | Why |
   | --- | --- |
   | `category.create=epmfs` | New files go to the disk that already holds the parent path (keeps a show/movie folder together and keeps hardlinks working). Falls back to the disk with the most free space when the path doesn't exist |
   | `moveonenospc=true` | If a disk fills up mid-write, move the file to another disk |
   | `minfreespace=50G` | Don't pick a disk with less than 50 GB free for new files |
   | `use_ino` | Consistent inode numbers (needed for hardlinks to be detected correctly) |
   | `cache.files=off` | Safest for media workloads |

4. Mount and check:

   ```sh
   systemctl daemon-reload
   mount /mnt/pool
   df -h /mnt/pool
   ```

5. Create the folder structure and permissions (use the UID/GID of the user that will run the containers, normally `1000:1000`; check with `id`):

   ```sh
   mkdir -p /mnt/pool/{media/{movies,shows},downloads,config}
   chown -R 1000:1000 /mnt/pool
   ```

   > Create the folders through `/mnt/pool` (not directly on the disk) so the same paths exist consistently.

6. Make Docker wait for the pool at boot. Otherwise containers may start with an empty `/mnt/pool` and write into the bare mount point:

   ```sh
   mkdir -p /etc/systemd/system/docker.service.d
   cat > /etc/systemd/system/docker.service.d/wait-for-pool.conf <<'EOF'
   [Unit]
   RequiresMountsFor=/mnt/pool
   EOF
   systemctl daemon-reload
   ```

## 6. Adding another disk in the future

1. Install the disk, then repeat [step 4](#4-format-the-disk-ext4) with label `disk2` and mount point `/mnt/disks/disk2` (also add its `/etc/fstab` line).
2. Because of `category.create=epmfs`, new files only land on a disk that already contains the parent directory. Create the base folders on the new disk so it is used:

   ```sh
   mkdir -p /mnt/disks/disk2/{media/{movies,shows},downloads}
   chown -R 1000:1000 /mnt/disks/disk2
   ```

3. Add the disk to the running pool without downtime (or just remount / reboot, thanks to the glob):

   ```sh
   apt install -y attr
   setfattr -n user.mergerfs.srcmounts -v '+/mnt/disks/disk2' /mnt/pool/.mergerfs
   getfattr -n user.mergerfs.srcmounts /mnt/pool/.mergerfs
   ```

4. Disable Intellipark on the new disk if it is a WD drive ([step 3](#3-disable-intellipark-idle3-tools)).
5. Nothing changes for the containers: they keep using `/mnt/pool`. Existing data is not rebalanced automatically (optionally use [`mergerfs.balance`](https://github.com/trapexit/mergerfs-tools)).
6. If you want *new top-level folders* to go to the emptiest disk instead of path-preserving, change `category.create` to `mfs`. Be aware that downloads and final media may then land on different disks and hardlinks will fall back to copy.

## 7. Install Docker and clone the repository

1. Install Docker Engine and Compose plugin (skip if UGOS already provides Docker Engine 24+ with the Compose v2 plugin; check `docker compose version`):

   ```sh
   curl -fsSL https://get.docker.com | sh
   usermod -aG docker <your-user>
   ```

2. Clone the repository:

   ```sh
   git clone https://github.com/snackk/awesome-media-center.git ~/awesome-media-center
   cd ~/awesome-media-center
   ```

3. Create the shared Docker network used by Traefik and all services:

   ```sh
   docker network create web
   ```

4. (Optional) override defaults. The compose files default to `/mnt/pool`, UID/GID `1000`, timezone `Europe/Lisbon`. To change them:

   ```sh
   cp .env.example .env
   nano .env
   # Make the file available to every stack
   for d in traefik portainer emby arr transmission debrid jenkins; do ln -sf ../.env "$d/.env"; done
   ```

5. Check the host GIDs used for hardware transcoding (Intel iGPU via `/dev/dri`) and set `RENDER_GID`/`VIDEO_GID` in `.env` if they differ from `992`/`44`:

   ```sh
   ls -l /dev/dri
   getent group render video
   ```

## 8. Migrate data from the old computer

Do this while **all containers on the old computer are stopped**, so databases are consistent. Run the commands below from the **old computer** unless stated otherwise. Set the variables once:

```sh
NAS=<user>@<nas-ip>
OLD=/media/data/Media        # media root on the old computer
```

### 8.1. Stop everything on the old computer

```sh
cd ~/awesome-media-center
for d in jenkins debrid transmission arr emby portainer traefik; do (cd $d 2>/dev/null && docker compose down); done
# Old layout: everything was inside the emby/ stack
(cd emby && docker compose down)
```

### 8.2. Export Docker named volumes (Emby and Jenkins)

The old configuration used named volumes. Export them to tarballs:

```sh
mkdir -p ~/migration && cd ~/migration
for v in emby jenkins; do
  docker run --rm -v $v:/source:ro -v "$PWD":/backup alpine \
    tar czf /backup/$v.tar.gz -C /source .
done
```

### 8.3. Copy the media and downloads

`rsync` is resumable; re-run it if it is interrupted. `-H` preserves hardlinks, `-a` preserves permissions and times:

```sh
rsync -aHh --info=progress2 --partial $OLD/Movies/ $NAS:/mnt/pool/media/movies/
rsync -aHh --info=progress2 --partial $OLD/Shows/  $NAS:/mnt/pool/media/shows/

# Anything else that was downloading (exclude what was already copied and config dirs)
rsync -aHh --info=progress2 --partial \
  --exclude='Movies' --exclude='Shows' --exclude='*_config' --exclude='transmission_conf' \
  $OLD/ $NAS:/mnt/pool/downloads/
```

> For a first pass you can run these while the old stack is still running, then run them again (fast) after stopping it for the final sync.

### 8.4. Copy application configuration

```sh
# Old folder                  -> New folder
rsync -aHh $OLD/radarr_config/       $NAS:/mnt/pool/config/radarr/
rsync -aHh $OLD/sonarr_config/       $NAS:/mnt/pool/config/sonarr/
rsync -aHh $OLD/prowlarr_config/     $NAS:/mnt/pool/config/prowlarr/
rsync -aHh $OLD/seerr_config/        $NAS:/mnt/pool/config/seerr/
rsync -aHh $OLD/transmission_conf/   $NAS:/mnt/pool/config/transmission/
rsync -aHh $OLD/debrid_config/       $NAS:/mnt/pool/config/debrid/
rsync -aHh ~/awesome-media-center/portainer/portainer/ $NAS:/mnt/pool/config/portainer/

# Named volumes exported in 8.2
scp ~/migration/emby.tar.gz ~/migration/jenkins.tar.gz $NAS:/tmp/
```

On the **NAS**, extract the volumes into the new bind-mount folders:

```sh
mkdir -p /mnt/pool/config/{emby,jenkins}
tar xzf /tmp/emby.tar.gz    -C /mnt/pool/config/emby
tar xzf /tmp/jenkins.tar.gz -C /mnt/pool/config/jenkins
chown -R 1000:1000 /mnt/pool/config
```

### 8.5. Copy the Traefik data (keeps the existing Let's Encrypt certificates)

```sh
rsync -aHh ~/awesome-media-center/traefik/data/acme.json $NAS:~/awesome-media-center/traefik/data/acme.json
```

On the NAS:

```sh
chmod 600 ~/awesome-media-center/traefik/data/acme.json
```

> The repository version of the compose/config files is already adapted to the new layout; pull the latest changes on the NAS instead of copying the old files.

## 9. Network, DNS and port forwarding

1. Give the NAS a fixed IP (DHCP reservation).
2. On the router, change the port forwards for **80** and **443** from the old computer to the NAS IP. Also forward **51413 TCP/UDP** to the NAS (Transmission peer port).
3. DNS records for `*.snackk-media.com` (emby, seerr, radarr, sonarr, prowlarr, transmission, debrid, jenkins, portainer, dashboard) do not need to change if the public IP stays the same. If you use dynamic DNS, make sure the updater runs on the NAS (or on the router) from now on.
4. Make sure the old computer no longer listens on 80/443 (stopped in step 8.1).

## 10. Start the stacks

On the NAS, in this order:

```sh
cd ~/awesome-media-center

(cd traefik      && docker compose up -d)
(cd portainer    && docker compose up -d)
(cd emby         && docker compose up -d)
(cd transmission && docker compose up -d)
(cd debrid       && docker compose up -d)
(cd arr          && docker compose up -d)
(cd jenkins      && docker compose up -d --build)
```

Check status and logs:

```sh
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker logs -f traefik
```

## 11. Post-migration application changes

Because the paths inside the containers changed (everything is now under `/data`), a few settings need a one-time update.

### Radarr / Sonarr

- **Settings → Media Management → Root Folders**: add `/data/media/movies` (Radarr) / `/data/media/shows` (Sonarr).
- **Movies / Series → Mass Editor**: select all, change the root folder to the new one, and choose **No, I'll move the files myself** (the files are already there).
- **Settings → Download Clients → Remote Path Mappings**:

  | Client | Remote path | Local path |
  | --- | --- | --- |
  | Transmission (host `transmission`) | `/downloads/` | `/data/downloads/` |
  | RDTClient | *(none needed after the change below)* | |

- Download client hostnames are container names on the shared `web` network (`transmission`, `debrid`, `prowlarr`, `flaresolverr`), so they keep working.
- Enable **Settings → Media Management → Use Hardlinks instead of Copy**.

### Prowlarr

- Check that the FlareSolverr proxy is `http://flaresolverr:8191` and that the Radarr/Sonarr applications still sync.

### Emby

- **Settings → Library**: edit each library and replace the folder paths with `/data/media/movies` and `/data/media/shows`, then run **Scan media library**.
- Check hardware transcoding: *Settings → Transcoding* → enable VAAPI / Intel QuickSync. If it fails, review `RENDER_GID` / `VIDEO_GID`.

### Seerr

- Check the Emby, Radarr and Sonarr connections (URLs are container names, e.g. `http://emby:8096`, `http://radarr:7878`) and update the root folders.

### Debrid (RDTClient)

- Download path: `/data/downloads` and mapped path: `/data/downloads` (same value, because Radarr/Sonarr see the same path). See `debrid/README.md`.

### Transmission

- The container sees `/downloads`. Check that `download-dir` is `/downloads/complete` (or what you used before).

## 12. Verification checklist

- [ ] `https://dashboard.snackk-media.com` loads (basic auth) and shows all routers as healthy
- [ ] HTTP → HTTPS redirect works: `curl -I http://emby.snackk-media.com`
- [ ] Valid certificates for every sub-domain (reused from `acme.json`, or reissued)
- [ ] Emby plays direct stream and transcode (hardware acceleration)
- [ ] Radarr/Sonarr see all their movies/series, and no item is "missing"
- [ ] A test download completes and is **hardlinked** (same inode: `ls -li`)
- [ ] `idle3ctl -g /dev/sdX` reports the timer disabled
- [ ] `Load_Cycle_Count` is not increasing: `smartctl -A /dev/sdX`
- [ ] After a reboot, `/mnt/pool` is mounted **before** the containers start

## 13. Rollback and decommissioning

- Do not delete anything from the old computer until you have used the NAS for 1–2 weeks. To roll back: stop the NAS stacks, restore the port forwards, `docker compose up -d` on the old computer.
- Set up regular backups of `/mnt/pool/config` (e.g. `rsync`/`restic` to another disk or cloud). MergerFS is **not** a backup.
- Monitor disk health: `smartctl -a /dev/sdX` (consider scheduled SMART tests via `smartd`).

