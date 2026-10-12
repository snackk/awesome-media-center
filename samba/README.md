# SMB share (Samba on the NAS host)

Shares `/media/data` as `media` **without** `configs/` (secrets, databases, certificates) and
`lost+found/`. Reachable from the home LAN and from your tailnet (Tailscale), never from the
Internet.

## Install

```sh
sudo apt install -y samba
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.orig          # keep the stock file
sudo cp ~/awesome-media-center/samba/smb.conf /etc/samba/smb.conf
testparm -s                                                    # must end without errors
```

Create the Samba user (a separate password from the Linux login; the Linux user must exist):

```sh
sudo smbpasswd -a snackk
```

Firewall: SMB only from the LAN and from the Tailscale interface.

```sh
sudo ufw allow from 192.168.1.0/24 to any port 445 proto tcp
sudo ufw allow in on tailscale0 to any port 445 proto tcp
```

Start it (NetBIOS is not used, so `nmbd` can stay off):

```sh
sudo systemctl enable --now smbd
sudo systemctl disable --now nmbd
sudo systemctl restart smbd
```

**Never forward port 445 on the router.**

## Connect

| From | Address |
| --- | --- |
| Home LAN | `smb://192.168.1.110/media` |
| Tailscale (home or away) | `smb://snackk-nas.follow-loggerhead.ts.net/media` |

- **Mac:** Finder → Go → Connect to Server (`Cmd+K`).
- **iPhone:** Files → `...` → Connect to Server.
- **Windows:** `\\snackk-nas.follow-loggerhead.ts.net\media` in Explorer.

Over Tailscale the share is **not discovered automatically** (Bonjour does not cross a VPN): type
the address. Log in as `snackk` with the Samba password.

## Check that `configs` is hidden

```sh
smbclient //localhost/media -U snackk -c 'ls'              # no configs/ and no lost+found/
smbclient //localhost/media -U snackk -c 'cd configs'      # must fail (NT_STATUS_OBJECT_NAME_NOT_FOUND)
```

## Notes

- `veto files` matches by **name at any depth**: a folder called `configs` anywhere inside the
  share would be hidden too. If you prefer strict per-folder shares, replace `[media]` with one
  share per folder (`movies`, `shows`, `music`, `photos`, `downloads`), each with its own `path`.
- The share is read-write for `snackk`. Set `read only = yes` in `[media]` for a read-only share.
  Be careful when moving files inside `downloads/` or the libraries while Radarr/Sonarr work on
  them: they rely on hardlinks and on the paths they have recorded.
- Optional, so the NAS shows up in the Finder sidebar on the home LAN (avahi is already installed
  for HomeControl): create `/etc/avahi/services/smb.service`:

  ```xml
  <?xml version="1.0" standalone='no'?>
  <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
  <service-group>
    <name replace-wildcards="yes">%h</name>
    <service><type>_smb._tcp</type><port>445</port></service>
  </service-group>
  ```
