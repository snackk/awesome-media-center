# Migrating to a UGREEN DXP2800

This guide documents how to move the `awesome-media-center` stack from a personal computer to a **UGREEN DXP2800** NAS with a single **WD Blue 4TB** HDD, formatted as **ext4**, pooled with **MergerFS** (so more disks can be added later) and with the **Intellipark (idle3) head-parking timer disabled** using `idle3-tools`. The NAS runs **Ubuntu Server 24.04 LTS** (replacing the stock UGOS firmware).

> Commands run on the NAS over SSH as your normal user (UID 1000). Commands that need privileges are shown with `sudo`; for long sessions you can use `sudo -i`. Replace `/dev/sdX` with the real device — **double-check it with `lsblk` before every destructive command**.

## Table of contents

1. [Target layout](#1-target-layout)
2. [Install and prepare Ubuntu Server 24.04](#2-install-and-prepare-ubuntu-server-2404)
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
│   ├── shows/              (was /media/data/Media/Shows)
│   ├── music/              (Navidrome library, was ~/Music on the Raspberry Pi)
│   └── Photos/             (Immich library)
├── downloads/              (was the root of /media/data/Media, torrent/debrid downloads)
└── config/                 (application configuration, was *_config folders and docker volumes)
    ├── emby/
    ├── radarr/
    ├── sonarr/
    ├── prowlarr/
    ├── profilarr/
    ├── seerr/
    ├── transmission/
    ├── debrid/
    ├── immich/
    ├── navidrome/
    ├── homecontrol/
    │   ├── state/
    │   └── ssh/
    ├── tailscale/          (node identity/state)
    └── portainer/
```

> **Tip:** if you have an NVMe SSD, keep `config/` (databases, metadata, Emby cache) there for better responsiveness and to avoid waking the HDD. If you do, set `CONFIG_ROOT` accordingly (see [step 7](#7-install-docker-and-clone-the-repository)).

## 2. Install and prepare Ubuntu Server 24.04

### 2.1. Where to install the OS

The DXP2800 has a 32 GB internal eMMC (holding UGOS), two SATA bays and two M.2 NVMe slots. Recommended:

| Option | Notes |
| --- | --- |
| **NVMe SSD (recommended)** | Install Ubuntu on a small NVMe (128–256 GB). Fast, and it can also hold `config/` (databases, Emby metadata, Immich Postgres) |
| USB drive | Works, but slower and less durable |
| Internal eMMC | Overwrites UGOS. Avoid it if you want an easy way back to the stock firmware |

The WD Blue is a **data disk only**: the Ubuntu installer must not touch it. **Physically unplug it (or leave the bay empty) during the installation**, so you cannot pick it by mistake.

### 2.2. Install Ubuntu Server

1. Download the **Ubuntu Server 24.04 LTS** ISO from <https://ubuntu.com/download/server> and write it to a USB stick (balenaEtcher, `dd`, Rufus).
2. Connect HDMI + keyboard to the NAS, plug in the USB stick and power on. Press `DEL`/`F2` at boot to open the BIOS/boot menu and boot from the USB stick (disable Secure Boot only if it prevents booting).
3. In the installer:
   - Choose **Ubuntu Server** (not minimized).
   - Network: DHCP is fine; a fixed address is configured on the router (step 2.4).
   - Storage: select **only** the NVMe/USB target, use the whole disk. LVM is optional.
   - Create your user (this will be UID/GID `1000`, matching `PUID`/`PGID` in `.env.example`) and hostname.
   - Enable **Install OpenSSH server** (import your GitHub SSH keys if you want).
   - Do **not** select any snaps (no Docker snap — Docker is installed from the official apt repository in [step 7](#7-install-docker-and-clone-the-repository)).
4. Reboot, remove the USB stick and log in over SSH: `ssh <user>@<nas-ip>`.
5. After the first successful boot, power off and plug the WD Blue back in.

### 2.3. Base configuration

```sh
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y rsync curl git smartmontools hdparm parted fuse3 attr avahi-daemon unattended-upgrades
sudo timedatectl set-timezone Europe/Lisbon
sudo dpkg-reconfigure -plow unattended-upgrades    # automatic security updates
```

Make sure the system is running a recent kernel with Intel N100 graphics support (Ubuntu 24.04 ships 6.8+, which is fine). Optionally test the iGPU on the host:

```sh
sudo apt install -y vainfo intel-media-va-driver-non-free
ls -l /dev/dri        # card0 and renderD128 must exist
vainfo
```

### 2.4. Network

- Give the NAS a **DHCP reservation** on your router (preferred), or set a static IP with Netplan (`/etc/netplan/*.yaml`, then `sudo netplan apply`).
- Optionally set the hostname/mDNS name: `sudo hostnamectl set-hostname <name>`.

### 2.5. Firewall (UFW)

Published Docker ports bypass UFW (Docker writes its own iptables rules), so UFW is mainly useful for **host services**: SSH and HomeControl, which runs with `network_mode: host` on port 8080. Allow only what you need:

```sh
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 51413        # Transmission peers (tcp + udp)
sudo ufw allow 41641/udp    # Tailscale direct (WireGuard) connections
sudo ufw allow in on tailscale0   # traffic coming from your tailnet
# HomeControl (host network, port 8080): reachable ONLY from Docker networks (Traefik),
# not from the LAN
sudo ufw allow from 172.16.0.0/12 to any port 8080 proto tcp
sudo ufw enable
sudo ufw status verbose
```

Notes:

- Docker-published ports (`80`, `443`, `51413`) are reachable regardless of UFW. The rules above document the intent; to *actually* restrict a published port, bind it to an address in the compose file (for example `127.0.0.1:9000:9000`) or use the `DOCKER-USER` chain.
- From another LAN machine verify that `curl -m 3 http://<nas-ip>:8080` times out while `https://home.snackk-media.com` works.
- Do not forward ports other than `80`, `443` and `51413` on the router.

## 3. Disable Intellipark (idle3-tools)

WD drives (Green/Blue/Red lines) park the heads after ~8 seconds of inactivity (**Intellipark**, the *idle3* timer). On a server with constant small accesses this causes a very high `Load_Cycle_Count`, wearing the drive. We disable it with `idle3-tools`.

> Note: this is not a real firmware flash. `idle3ctl` changes a drive setting through vendor commands. It is persistent across reboots, but requires a **full power cycle** to apply.
>
> Some newer WD Blue models (e.g. SMR `WD40EZAZ`/`WD40EZAX`) may ignore or reject the command. If `idle3ctl` fails, use the vendor `wdidle3.exe` from a DOS boot USB with the disk connected directly via SATA.

1. Install the tool (available in Ubuntu's `universe` repository):

   ```sh
   sudo apt install -y idle3-tools
   ```

2. Identify the disk and record the current `Load_Cycle_Count` as a baseline:

   ```sh
   lsblk -o NAME,MODEL,SIZE,SERIAL
   sudo smartctl -A /dev/sdX | grep -E "Load_Cycle_Count|Start_Stop_Count"
   ```

3. Read the current idle3 timer:

   ```sh
   sudo idle3ctl -g /dev/sdX
   # Idle3 timer set to 80 (0x50)   -> 8 seconds (default)
   ```

4. Disable the timer:

   ```sh
   sudo idle3ctl -d /dev/sdX
   ```

   Alternatively set a long timeout (e.g. 5 minutes = value `138`; values 129-255 count in 30 s units):

   ```sh
   sudo idle3ctl -s 138 /dev/sdX
   ```

5. **Power off the NAS completely** (do not just reboot), wait ~30 seconds, power it on again:

   ```sh
   sudo poweroff
   ```

6. Verify the change:

   ```sh
   sudo idle3ctl -g /dev/sdX
   # Idle3 timer is disabled
   ```

7. Re-check `Load_Cycle_Count` after a few days. It should barely increase anymore.

Optional — standard spin-down when the disk is truly idle (saves power/noise; it is independent of Intellipark). Spinning down/up frequently also wears the drive, so use a long timeout:

```sh
sudo hdparm -S 242 /dev/sdX    # 242 = 1 hour
```

Make it persistent through `/etc/hdparm.conf` (present on Ubuntu; use the `/dev/disk/by-id/...` path).

## 4. Format the disk (ext4)

> **This erases the disk.**

```sh
# Confirm the correct device (model/size/serial)
lsblk -o NAME,MODEL,SIZE,SERIAL,MOUNTPOINT

# Create a GPT partition table and one partition
sudo parted /dev/sdX --script mklabel gpt mkpart primary ext4 0% 100%

# Format as ext4:
#  -m 0         no reserved blocks (this is a data disk, not the OS disk)
#  -T largefile4 fewer inodes, more usable space for large media files
#  -L disk1     label
sudo mkfs.ext4 -m 0 -T largefile4 -L disk1 /dev/sdX1
```

Create the mount point and mount by **UUID** (device names such as `sda` can change):

```sh
sudo mkdir -p /mnt/disks/disk1
sudo blkid /dev/sdX1        # copy the UUID
```

Add to `/etc/fstab` (`sudo nano /etc/fstab`):

```fstab
UUID=<disk1-uuid>  /mnt/disks/disk1  ext4  defaults,noatime,nofail  0  2
```

```sh
sudo systemctl daemon-reload
sudo mount -a
df -h /mnt/disks/disk1
```

## 5. Set up MergerFS

MergerFS presents several disks as a single directory. Files are stored whole on one disk (no striping), so every disk remains readable on its own. **MergerFS provides no redundancy** — keep backups of important data (especially `config/`).

1. Install MergerFS. Ubuntu 24.04 (`noble`) ships a recent version (2.40.x) in `universe`, which is enough:

   ```sh
   sudo apt install -y mergerfs
   mergerfs --version
   ```

   If you want the latest release instead, install the `.deb` from <https://github.com/trapexit/mergerfs/releases> (pick the `ubuntu-noble_amd64` asset):

   ```sh
   wget https://github.com/trapexit/mergerfs/releases/download/<version>/mergerfs_<version>.ubuntu-noble_amd64.deb
   sudo dpkg -i mergerfs_<version>.ubuntu-noble_amd64.deb
   ```

2. Create the pool mount point:

   ```sh
   sudo mkdir -p /mnt/pool
   ```

3. Add to `/etc/fstab` (single line; `sudo nano /etc/fstab`). The glob `/mnt/disks/disk*` means new disks are picked up automatically at the next mount:

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
   sudo systemctl daemon-reload
   sudo mount /mnt/pool
   df -h /mnt/pool
   ```

5. Create the folder structure and permissions (use the UID/GID of the user that will run the containers, normally `1000:1000`; check with `id`):

   ```sh
   sudo mkdir -p /media/data/{movies,shows,music,photos,downloads,configs}
   sudo chown -R 1000:1000 /mnt/pool
   ```

   > Create the folders through `/mnt/pool` (not directly on the disk) so the same paths exist consistently.

6. Make Docker wait for the pool at boot. Otherwise containers may start with an empty `/mnt/pool` and write into the bare mount point:

   ```sh
   sudo mkdir -p /etc/systemd/system/docker.service.d
   sudo tee /etc/systemd/system/docker.service.d/wait-for-pool.conf > /dev/null <<'EOF'
   [Unit]
   RequiresMountsFor=/mnt/pool
   EOF
   sudo systemctl daemon-reload
   ```

## 6. Adding another disk in the future

1. Install the disk, then repeat [step 4](#4-format-the-disk-ext4) with label `disk2` and mount point `/mnt/disks/disk2` (also add its `/etc/fstab` line).
2. Because of `category.create=epmfs`, new files only land on a disk that already contains the parent directory. Create the base folders on the new disk so it is used:

   ```sh
   sudo mkdir -p /mnt/disks/disk2/{movies,shows,music,photos,downloads}
   sudo chown -R 1000:1000 /mnt/disks/disk2
   ```

3. Add the disk to the running pool without downtime (or just remount / reboot, thanks to the glob):

   ```sh
   sudo setfattr -n user.mergerfs.srcmounts -v '+/mnt/disks/disk2' /mnt/pool/.mergerfs
   getfattr -n user.mergerfs.srcmounts /mnt/pool/.mergerfs
   ```

4. Disable Intellipark on the new disk if it is a WD drive ([step 3](#3-disable-intellipark-idle3-tools)).
5. Nothing changes for the containers: they keep using `/mnt/pool`. Existing data is not rebalanced automatically (optionally use [`mergerfs.balance`](https://github.com/trapexit/mergerfs-tools)).
6. If you want *new top-level folders* to go to the emptiest disk instead of path-preserving, change `category.create` to `mfs`. Be aware that downloads and final media may then land on different disks and hardlinks will fall back to copy.

## 7. Install Docker and clone the repository

1. Install Docker Engine and the Compose plugin from Docker's official apt repository (do **not** use the `docker.io` package or the snap):

   ```sh
   sudo apt install -y ca-certificates curl
   sudo install -m 0755 -d /etc/apt/keyrings
   sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
   sudo chmod a+r /etc/apt/keyrings/docker.asc

   echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

   sudo apt update
   sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   sudo usermod -aG docker $USER     # log out and back in afterwards
   docker compose version
   ```

   Docker is enabled at boot by default. The `wait-for-pool.conf` drop-in from step 5 makes it wait for `/mnt/pool`.

2. Clone the repository:

   ```sh
   git clone https://github.com/snackk/awesome-media-center.git ~/awesome-media-center
   cd ~/awesome-media-center
   ```

3. Create the shared Docker networks. `web` is used by Traefik and the public services. `arr` is internal: it connects Radarr, Sonarr, Prowlarr, Profilarr, Seerr, Transmission and Debrid, and is never exposed through Traefik:

   ```sh
   docker network create web
   docker network create arr
   ```

   The admin UIs (Radarr 7878, Sonarr 8989, Prowlarr 9696, Profilarr 6868, Transmission 9091, Debrid 6500, Portainer 9000, Traefik dashboard 8082) only listen on `127.0.0.1` of the NAS and are never routed through Traefik. Reach them with an SSH tunnel, e.g. `ssh -L 7878:127.0.0.1:7878 <user>@<nas-ip>` and open `http://localhost:7878` (this also works over Tailscale). Inside Docker, apps reach each other by container name (e.g. `http://radarr:7878`, `http://transmission:9091`).

4. Create the `.env` file. It is **required**: the compose files have no defaults, so any missing variable makes `docker compose` fail with a clear message. Fill in every value (`PUID`/`PGID`, `TZ`, `DOMAIN`, paths, GIDs, Immich, HomeControl, Tailscale); variables marked "may be empty" must still be present:

   ```sh
   cp .env.example .env
   nano .env
   # Make the file available to every stack
   for d in traefik portainer emby arr transmission debrid immich navidrome homecontrol tailscale; do ln -sf ../.env "$d/.env"; done
   ```

5. Check the host GIDs used for hardware transcoding (Intel iGPU via `/dev/dri`) and set `RENDER_GID`/`VIDEO_GID` in `.env`. On Ubuntu 24.04 `video` is normally `44`, but `render` is often **not** `992` (commonly `993`), so do not skip this:

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
for d in debrid transmission arr emby portainer traefik; do (cd $d 2>/dev/null && docker compose down); done
# Old layout: everything was inside the emby/ stack
(cd emby && docker compose down)
```

### 8.2. Export the Emby Docker named volume

The old configuration used a named volume. Export it to a tarball:

```sh
mkdir -p ~/migration && cd ~/migration
docker run --rm -v emby:/source:ro -v "$PWD":/backup alpine \
  tar czf /backup/emby.tar.gz -C /source .
```

### 8.3. Copy the media and downloads

`rsync` is resumable; re-run it if it is interrupted. `-H` preserves hardlinks, `-a` preserves permissions and times:

```sh
rsync -aHh --info=progress2 --partial $OLD/Movies/ $NAS:/media/data/movies/
rsync -aHh --info=progress2 --partial $OLD/Shows/  $NAS:/media/data/shows/

# Anything else that was downloading (exclude what was already copied and config dirs)
rsync -aHh --info=progress2 --partial \
  --exclude='Movies' --exclude='Shows' --exclude='*_config' --exclude='transmission_conf' \
  $OLD/ $NAS:/media/data/downloads/
```

> `rsync -a` preserves the numeric UID/GID of the old computer. If your old user was not UID/GID `1000`, fix ownership on the NAS afterwards: `sudo chown -R 1000:1000 /media/data/movies /media/data/shows /media/data/downloads`.

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

# Named volume exported in 8.2
scp ~/migration/emby.tar.gz $NAS:/tmp/
```

On the **NAS**, extract the volume into the new bind-mount folder:

```sh
sudo mkdir -p /mnt/pool/config/emby
sudo tar xzf /tmp/emby.tar.gz -C /mnt/pool/config/emby
sudo chown -R 1000:1000 /mnt/pool/config
```

### 8.5. Copy the Traefik data (keeps the existing Let's Encrypt certificates)

```sh
ssh $NAS 'mkdir -p /media/data/configs/traefik'
rsync -aHh ~/awesome-media-center/traefik/data/acme.json $NAS:/media/data/configs/traefik/acme.json
```

On the NAS:

```sh
touch /media/data/configs/traefik/acme.json   # must exist as a file, or Docker creates a directory
chmod 600 /media/data/configs/traefik/acme.json
```

> The repository version of the compose/config files is already adapted to the new layout; pull the latest changes on the NAS instead of copying the old files.

### 8.6. Migrate the Raspberry Pi 3 services (Navidrome and HomeControl)

Run from the **Raspberry Pi**, in the folder where the old `docker-compose.yml` lives (e.g. `~/Downloads`). Set `NAS=<user>@<nas-ip>` first.

1. Stop the services so the databases are consistent:

   ```sh
   docker compose down
   ```

2. Music library and Navidrome data (its database references tracks as `/music/...`, which stays the same inside the container, so no re-scan of paths is needed):

   ```sh
   rsync -aHh --info=progress2 --partial /home/snackk/Music/ $NAS:/media/data/music/
   rsync -aHh ./navidrome/ $NAS:/mnt/pool/config/navidrome/
   ```

3. HomeControl state (named volume `homecontrol-state`) and SSH key:

   ```sh
   docker run --rm -v homecontrol-state:/source:ro -v "$PWD":/backup alpine \
     tar czf /backup/homecontrol-state.tar.gz -C /source .
   scp homecontrol-state.tar.gz $NAS:/tmp/
   ssh $NAS 'mkdir -p /mnt/pool/config/homecontrol/{state,ssh}'
   scp ~/.ssh/id_rsa $NAS:/mnt/pool/config/homecontrol/ssh/id_rsa
   ```

4. On the **NAS**:

   ```sh
   sudo tar xzf /tmp/homecontrol-state.tar.gz -C /mnt/pool/config/homecontrol/state
   chmod 600 /mnt/pool/config/homecontrol/ssh/id_rsa
   sudo chown -R 1000:1000 /mnt/pool/config/navidrome /mnt/pool/config/homecontrol /media/data/music
   # HomeControl runs as an unknown UID inside the container: if the state or the key is
   # not readable, check `docker logs homecontrol` and adjust ownership accordingly.
   ```

5. Create `.env` with `HC_USERNAME`, `HC_PASSWORD`, `HC_API_KEY` (and the optional Netatmo variables) copied from the Pi.
6. **Architecture check:** the Raspberry Pi 3 is `arm`/`arm64`, the NAS is `amd64`. `deluan/navidrome` is multi-arch, but `snackk/homecontrol:latest` must be published for `linux/amd64`, otherwise rebuild/push it with `docker buildx build --platform linux/amd64,linux/arm64 ...`.
7. HomeControl needs `avahi-daemon` on the NAS (installed in step 2.3; check with `systemctl status avahi-daemon`) and the UFW rule from step 2.5, which lets only Docker networks (Traefik) reach port 8080. Port 8080 must **not** be reachable from the LAN.

## 9. Network, DNS and port forwarding

1. Give the NAS a fixed IP (DHCP reservation).
2. On the router, change the port forwards for **80** and **443** from the old computer to the NAS IP. Also forward **51413 TCP/UDP** to the NAS (Transmission peer port).
3. DNS records for `*.snackk-media.com`: only the user-facing hostnames need to resolve to your public IP (emby, seerr, immich, navidrome, home). The admin tools (radarr, sonarr, prowlarr, transmission, debrid, portainer, dashboard) are no longer published, so their records can be deleted. They do not need to change if the public IP stays the same. If you use dynamic DNS, make sure the updater runs on the NAS (or on the router) from now on.
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
(cd immich       && docker compose up -d)   # requires IMMICH_DB_PASSWORD in .env
(cd navidrome    && docker compose up -d)
(cd homecontrol  && docker compose up -d)   # requires HC_* variables in .env
(cd tailscale    && docker compose up -d)   # see step 10.1
```

### 10.1. Tailscale (VPN)

Tailscale runs with host networking (`tailscale/`), so it is not routed through Traefik. It lets you reach the NAS, the LAN and the internal-only services from anywhere without opening more ports on the router.

1. Enable IP forwarding on the host (needed for the subnet router):

   ```sh
   echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
   echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
   sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
   ```

2. Generate an auth key at <https://login.tailscale.com/admin/settings/keys> and set `TS_AUTHKEY` in `.env` (only needed on the first start), plus `TS_ROUTES` with your LAN subnet (default `192.168.1.0/24`). Without a key, open the login URL shown by `docker logs tailscale`.
3. Start it and check the node:

   ```sh
   cd ~/awesome-media-center/tailscale && docker compose up -d
   docker exec tailscale tailscale status
   ```

4. In the Tailscale admin console, **approve the advertised subnet route** for the NAS and, optionally, disable key expiry for it.
5. Optional: forward **UDP 41641** on the router to the NAS for direct connections. It works without it, via relays, but slower.
6. After the first start you can remove `TS_AUTHKEY` from `.env`; the identity is stored in `${CONFIG_ROOT}/tailscale`.

From a device on your tailnet you can now SSH to the NAS and open tunnels to the *arr UIs.

Check status and logs:

```sh
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker logs -f traefik
```

## 11. Post-migration application changes

Because the paths inside the containers changed (everything is now under `/data`), a few settings need a one-time update.

### Radarr / Sonarr

- **Settings → Media Management → Root Folders**: add `/data/movies` (Radarr) / `/data/shows` (Sonarr).
- **Movies / Series → Mass Editor**: select all, change the root folder to the new one, and choose **No, I'll move the files myself** (the files are already there).
- **Settings → Download Clients → Remote Path Mappings**:

  | Client | Remote path | Local path |
  | --- | --- | --- |
  | Transmission (host `transmission`) | `/downloads/` | `/data/downloads/` |
  | RDTClient | *(none needed after the change below)* | |

- Download client hostnames are container names on the shared `arr` network (`transmission`, `debrid`, `prowlarr`, `flaresolverr`), so they keep working.
- Enable **Settings → Media Management → Use Hardlinks instead of Copy**.

### Prowlarr

- Check that the FlareSolverr proxy is `http://flaresolverr:8191` and that the Radarr/Sonarr applications still sync.

### Emby

- **Settings → Library**: edit each library and replace the folder paths with `/data/movies` and `/data/shows`, then run **Scan media library**.
- Check hardware transcoding: *Settings → Transcoding* → enable VAAPI / Intel QuickSync. If it fails, review `RENDER_GID` / `VIDEO_GID`.

### Seerr

- Check the Emby, Radarr and Sonarr connections (URLs are container names, e.g. `http://emby:8096`, `http://radarr:7878`) and update the root folders.

### Debrid (RDTClient)

- Download path: `/data/downloads` and mapped path: `/data/downloads` (same value, because Radarr/Sonarr see the same path). See `debrid/README.md`.

### Transmission

- The container sees `/downloads`. Check that `download-dir` is `/downloads/complete` (or what you used before).

## 12. Verification checklist

- [ ] The Traefik dashboard loads through a tunnel (`ssh -L 8082:127.0.0.1:8082 <user>@<nas-ip>`, then `http://localhost:8082`) and shows all routers as healthy
- [ ] Admin ports are not reachable from another LAN machine: `curl -m 3 http://<nas-ip>:9000` (Portainer), `:7878`, `:9091` must all time out
- [ ] HTTP → HTTPS redirect works: `curl -I http://emby.snackk-media.com`
- [ ] Valid certificates for every sub-domain (reused from `acme.json`, or reissued)
- [ ] Emby plays direct stream and transcode (hardware acceleration)
- [ ] Radarr/Sonarr see all their movies/series, and no item is "missing"
- [ ] A test download completes and is **hardlinked** (same inode: `ls -li`)
- [ ] `sudo idle3ctl -g /dev/sdX` reports the timer disabled
- [ ] `Load_Cycle_Count` is not increasing: `sudo smartctl -A /dev/sdX`
- [ ] `sudo ufw status` is active and `curl -m 3 http://<nas-ip>:8080` from the LAN times out (HomeControl only via Traefik)
- [ ] `docker exec tailscale tailscale status` shows the NAS online, and the subnet route is approved
- [ ] From a device on the tailnet (mobile data), you can reach `ssh <user>@<nas-tailscale-ip>`
- [ ] `docker compose version` works for your user without `sudo` (you are in the `docker` group)
- [ ] After a reboot, `/mnt/pool` is mounted **before** the containers start

## 13. Rollback and decommissioning

- Do not delete anything from the old computer until you have used the NAS for 1–2 weeks. To roll back: stop the NAS stacks, restore the port forwards, `docker compose up -d` on the old computer.
- Set up regular backups of `/mnt/pool/config` (e.g. `rsync`/`restic` to another disk or cloud). MergerFS is **not** a backup.
- If the OS was installed on an NVMe/USB drive and the internal eMMC was left untouched, UGOS is still there: remove the Ubuntu drive and boot to go back to the stock firmware.
- Monitor disk health: `sudo smartctl -a /dev/sdX` (consider scheduled SMART tests via `smartd`).

